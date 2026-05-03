%%%-------------------------------------------------------------------
%%% @doc MCP client for connecting to external MCP servers.
%%%
%%% A `gen_statem' that owns one connection to one MCP server. Two
%%% transports are supported: stdio (subprocess) and Streamable HTTP
%%% (POST + SSE GET).
%%%
%%% States:
%%% <ul>
%%%   <li>`connecting'   — transport is opening.</li>
%%%   <li>`initializing' — `initialize' request in flight.</li>
%%%   <li>`ready'        — handshake complete; calls accepted.</li>
%%%   <li>`closing'      — owner asked to close.</li>
%%% </ul>
%%%
%%% Inbound JSON-RPC envelopes from the transport are routed by
%%% `decode_envelope/1':
%%% <ul>
%%%   <li>response/error with `id' — match against the pending-request
%%%       table, post the result to the waiting caller.</li>
%%%   <li>request with `id'        — dispatch to the configured
%%%       `barrel_mcp_client_handler' module; reply (sync or async)
%%%       goes back over the same transport.</li>
%%%   <li>notification (no `id')   — dispatch to handler; resource
%%%       update notifications are also routed to subscribers.</li>
%%% </ul>
%%%
%%% Server-side host application code never sees the transport
%%% layer; it talks to this module via the API below. Whether to bind
%%% an LLM provider (Anthropic, OpenAI, Hermes-style local model) into
%%% this loop is the host's job — `barrel_mcp' itself stays a pure
%%% MCP library.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client).

-behaviour(gen_statem).

-include("barrel_mcp.hrl").

%% Public API
-export([
    start_link/1,
    start/1,
    close/1,
    %% Tools
    list_tools/1, list_tools/2,
    list_tools_all/1,
    call_tool/3, call_tool/4,
    %% Resources
    list_resources/1, list_resources/2,
    list_resources_all/1,
    list_resource_templates/1, list_resource_templates/2,
    list_resource_templates_all/1,
    read_resource/2,
    subscribe/2, unsubscribe/2,
    %% Prompts
    list_prompts/1, list_prompts/2,
    list_prompts_all/1,
    get_prompt/3,
    %% Tasks (long-running operations, MCP 2025-11-25)
    tasks_list/1, tasks_list/2,
    tasks_list_all/1,
    tasks_get/2,
    tasks_cancel/2,
    tasks_result/2,
    %% Misc
    complete/3,
    set_log_level/2,
    ping/1,
    cancel/2,
    reply_async/3,
    %% Introspection
    server_info/1,
    server_capabilities/1,
    protocol_version/1
]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([connecting/3, initializing/3, ready/3, closing/3]).

-type connect_spec() ::
    #{transport := {http, binary() | string()} |
                   {stdio, #{command := string(), args => [string()]}},
      client_info => #{name => binary(), version => binary()},
      capabilities => map(),
      handler => {module(), term()},
      auth => none
            | {bearer, binary()}
            | {oauth, map()}
            | {oauth_client_credentials, map()},
      protocol_version => binary(),
      request_timeout => pos_integer(),
      init_timeout => pos_integer(),
      ping_interval => pos_integer() | infinity,
      ping_failure_threshold => pos_integer()}.

-export_type([connect_spec/0]).

-define(DEFAULT_REQUEST_TIMEOUT, 30000).
-define(DEFAULT_INIT_TIMEOUT, 30000).
-define(DEFAULT_PING_TIMEOUT, 5000).
-define(DEFAULT_PING_FAILURE_THRESHOLD, 3).

-record(pending, {
    caller :: init | ping | {pid(), term()},
    method :: binary(),
    deadline :: integer() | infinity,
    progress_token :: binary() | undefined
}).

-record(data, {
    spec :: connect_spec(),
    transport :: {module(), pid()} | undefined,
    request_id = 1 :: integer(),
    pending = #{} :: #{integer() => #pending{}},
    handler_mod :: module(),
    handler_state :: term(),
    async_replies = #{} :: #{barrel_mcp_client_handler:async_tag() => integer()},
    subscriptions = #{} :: #{binary() => [pid()]},
    progress = #{} :: #{binary() => pid()},
    ping_failures = 0 :: non_neg_integer(),
    server_capabilities :: map() | undefined,
    server_info :: map() | undefined,
    protocol_version :: binary() | undefined
}).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Start a supervised client. Linked to the calling process.
-spec start_link(connect_spec()) -> {ok, pid()} | {error, term()}.
start_link(Spec) ->
    gen_statem:start_link(?MODULE, Spec, []).

%% @doc Start an unsupervised client.
-spec start(connect_spec()) -> {ok, pid()} | {error, term()}.
start(Spec) ->
    gen_statem:start(?MODULE, Spec, []).

%% @doc Close the connection.
-spec close(pid()) -> ok.
close(Pid) ->
    gen_statem:cast(Pid, close).

%% @doc List tools advertised by the server. Returns a single page.
%% Use {@link list_tools/2} with `#{want_cursor => true}' or
%% {@link list_tools_all/1} to walk pagination.
-spec list_tools(pid()) -> {ok, [map()]} | {error, term()}.
list_tools(Pid) ->
    list_tools(Pid, #{}).

%% @doc List tools with pagination control.
%%
%% `Opts' may contain:
%% <ul>
%%   <li>`{cursor, Cursor}' — start from a previously-returned
%%       `nextCursor'.</li>
%%   <li>`{want_cursor, true}' — return `{ok, Items, NextCursor}' even
%%       on the last page (with `undefined' for `NextCursor').</li>
%%   <li>`{timeout, Ms}' — override the per-request timeout.</li>
%% </ul>
-spec list_tools(pid(), map()) -> {ok, [map()], NextCursor :: binary() | undefined} |
                                  {ok, [map()]} | {error, term()}.
list_tools(Pid, Opts) ->
    paged(Pid, <<"tools/list">>, <<"tools">>, Opts).

%% @doc Walk all `tools/list' pages and return the full list.
-spec list_tools_all(pid()) -> {ok, [map()]} | {error, term()}.
list_tools_all(Pid) ->
    walk_all(fun(Cursor) -> list_tools(Pid, page_opts(Cursor)) end).

%% @doc Invoke a tool by name. `Args' is forwarded verbatim as the
%% JSON-RPC `arguments' field. Returns the server's `result' map,
%% which has a `<<"content">>' list of content blocks.
-spec call_tool(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
call_tool(Pid, Name, Args) ->
    call_tool(Pid, Name, Args, #{}).

%% @doc Invoke a tool with options.
%%
%% `Opts' may contain:
%% <ul>
%%   <li>`{progress_token, Token}' — register the calling process to
%%       receive `{mcp_progress, Token, Params}' messages until the
%%       request settles.</li>
%%   <li>`{timeout, Ms}' — override the per-request timeout
%%       (`request_timeout' from the connect spec, default 30000).</li>
%% </ul>
-spec call_tool(pid(), binary(), map(), map()) -> {ok, map()} | {error, term()}.
call_tool(Pid, Name, Args, Opts) ->
    Params0 = #{<<"name">> => Name, <<"arguments">> => Args},
    Params = maybe_attach_progress_token(Params0, Opts),
    request(Pid, <<"tools/call">>, Params, request_timeout(Opts)).

%% @doc List resources advertised by the server. Single page.
-spec list_resources(pid()) -> {ok, [map()]} | {error, term()}.
list_resources(Pid) -> list_resources(Pid, #{}).

%% @doc List resources with pagination control. Same `Opts' shape as
%% {@link list_tools/2}.
-spec list_resources(pid(), map()) -> {ok, [map()], binary() | undefined} |
                                       {ok, [map()]} | {error, term()}.
list_resources(Pid, Opts) ->
    paged(Pid, <<"resources/list">>, <<"resources">>, Opts).

%% @doc Walk every `resources/list' page and return the union.
-spec list_resources_all(pid()) -> {ok, [map()]} | {error, term()}.
list_resources_all(Pid) ->
    walk_all(fun(Cursor) -> list_resources(Pid, page_opts(Cursor)) end).

%% @doc List resource templates advertised by the server. Single
%% page.
-spec list_resource_templates(pid()) -> {ok, [map()]} | {error, term()}.
list_resource_templates(Pid) -> list_resource_templates(Pid, #{}).

%% @doc List resource templates with pagination control. Same `Opts'
%% shape as {@link list_tools/2}.
-spec list_resource_templates(pid(), map()) ->
    {ok, [map()], binary() | undefined} | {ok, [map()]} | {error, term()}.
list_resource_templates(Pid, Opts) ->
    paged(Pid, <<"resources/templates/list">>, <<"resourceTemplates">>, Opts).

%% @doc Walk every `resources/templates/list' page.
-spec list_resource_templates_all(pid()) -> {ok, [map()]} | {error, term()}.
list_resource_templates_all(Pid) ->
    walk_all(fun(Cursor) -> list_resource_templates(Pid, page_opts(Cursor)) end).

%% @doc Read a resource by URI.
-spec read_resource(pid(), binary()) -> {ok, map()} | {error, term()}.
read_resource(Pid, Uri) ->
    request(Pid, <<"resources/read">>, #{<<"uri">> => Uri}).

%% @doc Subscribe the calling process to updates for `Uri'. The
%% calling process receives `{mcp_resource_updated, Uri, Params}' on
%% every inbound `notifications/resources/updated' for that URI until
%% it calls {@link unsubscribe/2} or the client closes.
-spec subscribe(pid(), binary()) -> {ok, map()} | {error, term()}.
subscribe(Pid, Uri) ->
    case request(Pid, <<"resources/subscribe">>, #{<<"uri">> => Uri}) of
        {ok, _} = Ok ->
            ok = gen_statem:cast(Pid, {add_subscriber, Uri, self()}),
            Ok;
        Err -> Err
    end.

%% @doc Stop receiving updates for `Uri' on the calling process.
-spec unsubscribe(pid(), binary()) -> {ok, map()} | {error, term()}.
unsubscribe(Pid, Uri) ->
    case request(Pid, <<"resources/unsubscribe">>, #{<<"uri">> => Uri}) of
        {ok, _} = Ok ->
            ok = gen_statem:cast(Pid, {remove_subscriber, Uri, self()}),
            Ok;
        Err -> Err
    end.

%% @doc List prompts advertised by the server. Single page.
-spec list_prompts(pid()) -> {ok, [map()]} | {error, term()}.
list_prompts(Pid) -> list_prompts(Pid, #{}).

%% @doc List prompts with pagination control. Same `Opts' shape as
%% {@link list_tools/2}.
-spec list_prompts(pid(), map()) -> {ok, [map()], binary() | undefined} |
                                     {ok, [map()]} | {error, term()}.
list_prompts(Pid, Opts) ->
    paged(Pid, <<"prompts/list">>, <<"prompts">>, Opts).

%% @doc Walk every `prompts/list' page.
-spec list_prompts_all(pid()) -> {ok, [map()]} | {error, term()}.
list_prompts_all(Pid) ->
    walk_all(fun(Cursor) -> list_prompts(Pid, page_opts(Cursor)) end).

%% @doc Render a prompt with the given arguments.
-spec get_prompt(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
get_prompt(Pid, Name, Args) ->
    request(Pid, <<"prompts/get">>, #{
        <<"name">> => Name,
        <<"arguments">> => Args
    }).

%% @doc Send `completion/complete' to ask the server to suggest values
%% for a prompt or resource template argument. `Ref' is the JSON-RPC
%% `ref' map (e.g. `#{<<"type">> => <<"ref/prompt">>, <<"name">> => N}')
%% and `Argument' is `#{<<"name">> => Key, <<"value">> => Partial}'.
-spec complete(pid(), map(), map()) -> {ok, map()} | {error, term()}.
complete(Pid, Ref, Argument) ->
    request(Pid, <<"completion/complete">>, #{
        <<"ref">> => Ref,
        <<"argument">> => Argument
    }).

%% @doc Send `logging/setLevel'. `Level' is one of `debug', `info',
%% `notice', `warning', `error', `critical', `alert', `emergency' as
%% a binary.
-spec set_log_level(pid(), binary()) -> {ok, map()} | {error, term()}.
set_log_level(Pid, Level) when is_binary(Level) ->
    request(Pid, <<"logging/setLevel">>, #{<<"level">> => Level}).

%% @doc List long-running tasks owned by the connected session.
%% Single page; use {@link tasks_list/2} with `#{want_cursor =>
%% true}' or {@link tasks_list_all/1} to walk pagination.
-spec tasks_list(pid()) -> {ok, [map()]} | {error, term()}.
tasks_list(Pid) ->
    tasks_list(Pid, #{}).

-spec tasks_list(pid(), map()) -> {ok, [map()], binary() | undefined} |
                                   {ok, [map()]} | {error, term()}.
tasks_list(Pid, Opts) ->
    paged(Pid, <<"tasks/list">>, <<"tasks">>, Opts).

%% @doc Walk every `tasks/list' page.
-spec tasks_list_all(pid()) -> {ok, [map()]} | {error, term()}.
tasks_list_all(Pid) ->
    walk_all(fun(Cursor) -> tasks_list(Pid, page_opts(Cursor)) end).

%% @doc Fetch a single task by id.
-spec tasks_get(pid(), binary()) -> {ok, map()} | {error, term()}.
tasks_get(Pid, TaskId) ->
    request(Pid, <<"tasks/get">>, #{<<"taskId">> => TaskId}).

%% @doc Cancel a long-running task by id. Returns `{ok, _}' on
%% acceptance; the task transitions to `cancelled' status, which the
%% server then broadcasts via `notifications/tasks/status'.
-spec tasks_cancel(pid(), binary()) -> {ok, map()} | {error, term()}.
tasks_cancel(Pid, TaskId) ->
    request(Pid, <<"tasks/cancel">>, #{<<"taskId">> => TaskId}).

%% @doc Fetch the final result of a completed task. Returns the
%% task's stored `result' map; for `failed' tasks returns
%% `{error, {Code, Message}}'; for tasks still `working' returns
%% `{error, {_, <<"Task not yet complete">>}}'.
-spec tasks_result(pid(), binary()) -> {ok, map()} | {error, term()}.
tasks_result(Pid, TaskId) ->
    request(Pid, <<"tasks/result">>, #{<<"taskId">> => TaskId}).

%% @doc Send a `ping' request and wait for the response.
-spec ping(pid()) -> {ok, map()} | {error, term()}.
ping(Pid) ->
    request(Pid, <<"ping">>, #{}).

%% @doc Cancel a previously-issued request by id. Sends
%% `notifications/cancelled' to the server and unblocks the caller
%% with `{error, cancelled}'.
-spec cancel(pid(), integer()) -> ok.
cancel(Pid, RequestId) ->
    gen_statem:cast(Pid, {cancel, RequestId}).

%% @doc Deliver a deferred reply for a server-initiated request that
%% the handler answered with `{async, Tag, _}'. `Result' is either a
%% plain term (sent as the JSON-RPC `result') or
%% `{error, Code, Message}'.
-spec reply_async(pid(), term(),
                  term() | {error, integer(), binary()}) -> ok.
reply_async(Pid, Tag, Result) ->
    gen_statem:cast(Pid, {async_reply, Tag, Result}).

%% @doc Return the `serverInfo' map the server reported during
%% `initialize' (with keys like `<<"name">>' and `<<"version">>').
-spec server_info(pid()) -> {ok, map() | undefined}.
server_info(Pid) ->
    gen_statem:call(Pid, server_info).

%% @doc Return the server capabilities map negotiated during
%% `initialize'. Useful to gate work on optional features.
-spec server_capabilities(pid()) -> {ok, map() | undefined}.
server_capabilities(Pid) ->
    gen_statem:call(Pid, server_capabilities).

%% @doc Return the negotiated protocol version (e.g.
%% `<<"2025-11-25">>' or `<<"2025-03-26">>' if the server downgraded).
-spec protocol_version(pid()) -> {ok, binary() | undefined}.
protocol_version(Pid) ->
    gen_statem:call(Pid, protocol_version).

%%====================================================================
%% gen_statem
%%====================================================================

callback_mode() -> state_functions.

init(Spec) ->
    process_flag(trap_exit, true),
    {HandlerMod, HandlerArgs} =
        maps:get(handler, Spec, {barrel_mcp_client_handler_default, []}),
    case HandlerMod:init(HandlerArgs) of
        {ok, HState} ->
            Data = #data{spec = Spec,
                         handler_mod = HandlerMod,
                         handler_state = HState},
            {ok, connecting, Data,
             [{next_event, internal, open_transport}]};
        {error, _} = Err ->
            Err
    end.

%%-- connecting -------------------------------------------------------

connecting(internal, open_transport, Data) ->
    case open_transport(Data) of
        {ok, Data1} ->
            InitTimeout = maps:get(init_timeout,
                                   Data#data.spec, ?DEFAULT_INIT_TIMEOUT),
            {Id, Data2} = next_id(Data1),
            Params = build_initialize_params(Data2),
            send_envelope(Data2,
                barrel_mcp_protocol:encode_request(Id, <<"initialize">>, Params)),
            P = #pending{caller = init,
                         method = <<"initialize">>,
                         deadline = deadline(InitTimeout)},
            Pending1 = (Data2#data.pending)#{Id => P},
            {next_state, initializing, Data2#data{pending = Pending1},
             [{state_timeout, InitTimeout, init_timeout}]};
        {error, Reason} ->
            {stop, {transport_failed, Reason}}
    end;
connecting({call, From}, _Req, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
connecting(EventType, EventContent, Data) ->
    common_handler(EventType, EventContent, Data).

%%-- initializing -----------------------------------------------------

initializing(state_timeout, init_timeout, _Data) ->
    {stop, init_timeout};
initializing({call, From}, _Req, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
initializing(info, {mcp_in, Pid, Json},
             #data{transport = {_, Pid}} = Data) ->
    handle_inbound(Json, initializing, Data);
initializing(EventType, EventContent, Data) ->
    common_handler(EventType, EventContent, Data).

%%-- ready ------------------------------------------------------------

ready({call, From}, server_info, Data) ->
    {keep_state_and_data, [{reply, From, {ok, Data#data.server_info}}]};
ready({call, From}, server_capabilities, Data) ->
    {keep_state_and_data, [{reply, From, {ok, Data#data.server_capabilities}}]};
ready({call, From}, protocol_version, Data) ->
    {keep_state_and_data, [{reply, From, {ok, Data#data.protocol_version}}]};
ready({call, From}, {request, Method, Params, Timeout}, Data) ->
    case is_supported(Method, Data) of
        false ->
            {keep_state_and_data, [{reply, From, {error, {unsupported, Method}}}]};
        true ->
            {Id, Data1} = next_id(Data),
            send_envelope(Data1,
                barrel_mcp_protocol:encode_request(Id, Method, Params)),
            ProgressToken = progress_token_from_params(Params),
            {CallerPid, _Tag} = From,
            Data2 = case ProgressToken of
                undefined -> Data1;
                Tok -> Data1#data{progress = (Data1#data.progress)#{Tok => CallerPid}}
            end,
            P = #pending{caller = From, method = Method,
                         deadline = deadline(Timeout),
                         progress_token = ProgressToken},
            Pending = (Data2#data.pending)#{Id => P},
            Actions = case Timeout of
                          infinity -> [];
                          T -> [{{timeout, {req, Id}}, T, request_timeout}]
                      end,
            {keep_state, Data2#data{pending = Pending}, Actions}
    end;
ready(cast, {cancel, Id}, Data) ->
    do_cancel(Id, Data);
ready(cast, {add_subscriber, Uri, Pid}, Data) ->
    {keep_state, add_sub(Uri, Pid, Data)};
ready(cast, {remove_subscriber, Uri, Pid}, Data) ->
    {keep_state, del_sub(Uri, Pid, Data)};
ready(cast, {async_reply, Tag, Result}, Data) ->
    {keep_state, deliver_async_reply(Tag, Result, Data)};
ready({timeout, {req, Id}}, request_timeout, Data) ->
    timeout_pending(Id, Data);
ready(state_timeout, ping_tick, Data) ->
    {Data1, Actions} = issue_ping(Data),
    {keep_state, Data1, Actions};
ready(info, {mcp_in, Pid, Json},
      #data{transport = {_, Pid}} = Data) ->
    handle_inbound(Json, ready, Data);
ready(EventType, EventContent, Data) ->
    common_handler(EventType, EventContent, Data).

%%-- closing ----------------------------------------------------------

closing({call, From}, _Req, _Data) ->
    {keep_state_and_data, [{reply, From, {error, closing}}]};
closing(_E, _C, _Data) ->
    keep_state_and_data.

%%====================================================================
%% Common event handling (transport messages, casts, etc.)
%%====================================================================

common_handler(info, {mcp_closed, Pid, _Reason},
               #data{transport = {_, Pid}}) ->
    {stop, normal};
common_handler(info, {'EXIT', _, _}, _Data) ->
    keep_state_and_data;
common_handler(cast, close, Data) ->
    case Data#data.transport of
        {Mod, Pid} -> catch Mod:close(Pid);
        _ -> ok
    end,
    {stop, normal, Data};
common_handler(_E, _C, _D) ->
    keep_state_and_data.

%%====================================================================
%% Inbound message routing
%%====================================================================

handle_inbound(Json, State, Data) ->
    case decode(Json) of
        {request, Id, Method, Params} ->
            handle_server_request(Id, Method, Params, State, Data);
        {notification, Method, Params} ->
            handle_server_notification(Method, Params, State, Data);
        {response, Id, Result} ->
            handle_response(Id, Result, State, Data);
        {error, Id, Code, Message, _Data1} ->
            handle_error_response(Id, Code, Message, State, Data);
        _ ->
            keep_state_and_data
    end.

decode(Json) ->
    case barrel_mcp_protocol:decode(Json) of
        {ok, Map} -> barrel_mcp_protocol:decode_envelope(Map);
        Err -> Err
    end.

handle_response(Id, Result, initializing, Data) ->
    case maps:take(Id, Data#data.pending) of
        {#pending{method = <<"initialize">>}, Rest} ->
            handle_initialize_result(Result, Data#data{pending = Rest});
        _ ->
            keep_state_and_data
    end;
handle_response(Id, Result, _State, Data) ->
    case maps:take(Id, Data#data.pending) of
        {#pending{caller = ping} = P, Rest} ->
            Data1 = settle_data(P, Data#data{pending = Rest, ping_failures = 0}),
            {keep_state, Data1, [drop_req_timeout(Id)]};
        {#pending{caller = From} = P, Rest} when From =/= init ->
            gen_statem:reply(From, {ok, Result}),
            Data1 = settle_data(P, Data#data{pending = Rest}),
            {keep_state, Data1, [drop_req_timeout(Id)]};
        _ ->
            keep_state_and_data
    end.

handle_error_response(_Id, Code, Message, initializing, _Data) ->
    {stop, {init_failed, Code, Message}};
handle_error_response(Id, Code, Message, _State, Data) ->
    case maps:take(Id, Data#data.pending) of
        {#pending{caller = ping} = P, Rest} ->
            Data1 = settle_data(P, bump_ping_failures(Data#data{pending = Rest})),
            maybe_close_on_ping_failures(Data1, Id);
        {#pending{caller = From} = P, Rest} when From =/= init ->
            gen_statem:reply(From, {error, {Code, Message}}),
            Data1 = settle_data(P, Data#data{pending = Rest}),
            {keep_state, Data1, [drop_req_timeout(Id)]};
        _ ->
            keep_state_and_data
    end.

settle_data(#pending{progress_token = Tok}, Data) ->
    drop_progress(Tok, Data).

drop_progress(undefined, Data) -> Data;
drop_progress(Tok, Data) ->
    Data#data{progress = maps:remove(Tok, Data#data.progress)}.

drop_req_timeout(Id) ->
    {{timeout, {req, Id}}, infinity, request_timeout}.

handle_server_request(Id, Method, Params, _State,
                      #data{handler_mod = Mod, handler_state = HS} = Data) ->
    case Mod:handle_request(Method, Params, HS) of
        {reply, Result, HS1} ->
            send_envelope(Data, barrel_mcp_protocol:encode_response(Id, Result)),
            {keep_state, Data#data{handler_state = HS1}};
        {error, Code, Msg, HS1} ->
            send_envelope(Data, barrel_mcp_protocol:encode_error(Id, Code, Msg)),
            {keep_state, Data#data{handler_state = HS1}};
        {async, Tag, HS1} ->
            Async = (Data#data.async_replies)#{Tag => Id},
            {keep_state, Data#data{handler_state = HS1,
                                   async_replies = Async}}
    end.

deliver_async_reply(Tag, Result, Data) ->
    case maps:take(Tag, Data#data.async_replies) of
        {Id, Rest} ->
            Envelope = case Result of
                {error, Code, Msg} ->
                    barrel_mcp_protocol:encode_error(Id, Code, Msg);
                _ ->
                    barrel_mcp_protocol:encode_response(Id, Result)
            end,
            send_envelope(Data, Envelope),
            Data#data{async_replies = Rest};
        error ->
            Data
    end.

handle_server_notification(<<"notifications/resources/updated">> = Method, Params,
                           _State, Data) ->
    Uri = maps:get(<<"uri">>, Params, <<>>),
    notify_subscribers(Uri, Params, Data),
    dispatch_notification(Method, Params, Data);
handle_server_notification(<<"notifications/progress">> = Method, Params,
                           _State, Data) ->
    notify_progress(Params, Data),
    dispatch_notification(Method, Params, Data);
handle_server_notification(Method, Params, _State, Data) ->
    dispatch_notification(Method, Params, Data).

dispatch_notification(Method, Params,
                      #data{handler_mod = Mod, handler_state = HS} = Data) ->
    case Mod:handle_notification(Method, Params, HS) of
        {ok, HS1} ->
            {keep_state, Data#data{handler_state = HS1}}
    end.

notify_subscribers(Uri, Params, Data) ->
    case maps:get(Uri, Data#data.subscriptions, []) of
        [] -> ok;
        Pids ->
            lists:foreach(fun(P) -> P ! {mcp_resource_updated, Uri, Params} end,
                          Pids),
            ok
    end.

notify_progress(Params, Data) ->
    case maps:get(<<"progressToken">>, Params, undefined) of
        undefined -> ok;
        Tok ->
            case maps:get(Tok, Data#data.progress, undefined) of
                undefined -> ok;
                Pid -> Pid ! {mcp_progress, Tok, Params}, ok
            end
    end.

%%====================================================================
%% Initialize handling
%%====================================================================

build_initialize_params(#data{spec = Spec}) ->
    ClientInfo0 = maps:get(client_info, Spec,
                           #{<<"name">> => <<"barrel_mcp_client">>,
                             <<"version">> => <<"2.0.0">>}),
    ClientInfo = normalize_keys(ClientInfo0),
    Caps = capabilities_to_wire(maps:get(capabilities, Spec, #{})),
    Version = maps:get(protocol_version, Spec, ?MCP_CLIENT_PROTOCOL_VERSION),
    #{
        <<"protocolVersion">> => Version,
        <<"capabilities">> => Caps,
        <<"clientInfo">> => ClientInfo
    }.

%% Sugar -> spec-shaped wire form. `true' becomes an empty object;
%% maps are passed through with binary keys.
capabilities_to_wire(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        Acc#{cap_key(K) => cap_value(V)}
    end, #{}, Map).

cap_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
cap_key(K) when is_binary(K) -> K.

cap_value(true) -> #{};
cap_value(false) -> undefined;
cap_value(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        case V of
            false -> Acc;
            _ -> Acc#{cap_subkey(K) => cap_subvalue(V)}
        end
    end, #{}, Map);
cap_value(_) -> #{}.

cap_subkey(list_changed) -> <<"listChanged">>;
cap_subkey(K) when is_atom(K) -> atom_to_binary(K, utf8);
cap_subkey(K) when is_binary(K) -> K.

cap_subvalue(true) -> true;
cap_subvalue(V) -> V.

normalize_keys(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        Key = case K of
                  A when is_atom(A) -> atom_to_binary(A, utf8);
                  B when is_binary(B) -> B
              end,
        Acc#{Key => V}
    end, #{}, Map).

handle_initialize_result(Result, Data) ->
    case maps:get(<<"protocolVersion">>, Result, undefined) of
        undefined ->
            {stop, {init_failed, missing_protocol_version}};
        Version ->
            case lists:member(Version, ?MCP_CLIENT_SUPPORTED_VERSIONS) of
                false ->
                    {stop, {protocol_version, Version, ?MCP_CLIENT_SUPPORTED_VERSIONS}};
                true ->
                    finish_initialize(Version, Result, Data)
            end
    end.

finish_initialize(Version, Result, Data) ->
    case Data#data.transport of
        {barrel_mcp_client_http, Pid} ->
            barrel_mcp_client_http:set_protocol_version(Pid, Version),
            barrel_mcp_client_http:open_event_stream(Pid);
        _ ->
            ok
    end,
    send_envelope(Data,
        barrel_mcp_protocol:encode_notification(
            <<"notifications/initialized">>, #{})),
    Data1 = Data#data{
        server_capabilities = maps:get(<<"capabilities">>, Result, #{}),
        server_info = maps:get(<<"serverInfo">>, Result, #{}),
        protocol_version = Version
    },
    {next_state, ready, Data1, [arm_ping_timer(Data1)]}.

%%====================================================================
%% Transport plumbing
%%====================================================================

open_transport(#data{spec = Spec} = Data) ->
    case maps:get(transport, Spec) of
        {http, Url} ->
            Auth = barrel_mcp_client_auth:new(maps:get(auth, Spec, none)),
            case Auth of
                {error, _} = Err -> Err;
                _ ->
                    Opts = #{url => Url, auth => Auth,
                             open_event_stream => true,
                             headers => maps:get(http_headers, Spec, [])},
                    case barrel_mcp_client_http:connect(self(), Opts) of
                        {ok, Pid} ->
                            link(Pid),
                            {ok, Data#data{transport = {barrel_mcp_client_http, Pid}}};
                        Err -> Err
                    end
            end;
        {stdio, StdioOpts} ->
            case barrel_mcp_client_stdio:connect(self(), StdioOpts) of
                {ok, Pid} ->
                    link(Pid),
                    {ok, Data#data{transport = {barrel_mcp_client_stdio, Pid}}};
                Err -> Err
            end
    end.

send_envelope(#data{transport = {Mod, Pid}}, Envelope) ->
    Json = iolist_to_binary(json:encode(Envelope)),
    Mod:send(Pid, Json);
send_envelope(_, _) -> ok.

%%====================================================================
%% Helpers
%%====================================================================

next_id(#data{request_id = N} = Data) ->
    {N, Data#data{request_id = N + 1}}.

deadline(infinity) -> infinity;
deadline(T) when is_integer(T) ->
    erlang:monotonic_time(millisecond) + T.

request(Pid, Method, Params) ->
    request(Pid, Method, Params, ?DEFAULT_REQUEST_TIMEOUT).

request(Pid, Method, Params, Timeout) ->
    CallTimeout = case Timeout of
                      infinity -> infinity;
                      T when is_integer(T) -> T + 5000
                  end,
    gen_statem:call(Pid, {request, Method, Params, Timeout}, CallTimeout).

walk_all(Fetch) ->
    barrel_mcp_pagination:walk(Fetch).

page_opts(undefined) -> #{want_cursor => true};
page_opts(Cursor) -> #{cursor => Cursor, want_cursor => true}.

paged(Pid, Method, ResultKey, Opts) ->
    Params = case maps:get(cursor, Opts, undefined) of
                 undefined -> #{};
                 C -> #{<<"cursor">> => C}
             end,
    case request(Pid, Method, Params, request_timeout(Opts)) of
        {ok, Result} ->
            Items = maps:get(ResultKey, Result, []),
            Next = maps:get(<<"nextCursor">>, Result, undefined),
            WantCursor = map_get_default(want_cursor, Opts, false),
            case {Next, WantCursor} of
                {undefined, false} -> {ok, Items};
                _ -> {ok, Items, Next}
            end;
        Err -> Err
    end.

map_get_default(K, M, D) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error -> D
    end.

request_timeout(Opts) ->
    map_get_default(timeout, Opts, ?DEFAULT_REQUEST_TIMEOUT).

maybe_attach_progress_token(Params, Opts) ->
    case maps:get(progress_token, Opts, undefined) of
        undefined -> Params;
        Tok -> Params#{<<"_meta">> => #{<<"progressToken">> => Tok}}
    end.

progress_token_from_params(#{<<"_meta">> := #{<<"progressToken">> := Tok}}) ->
    Tok;
progress_token_from_params(_) ->
    undefined.

%%====================================================================
%% Ping cadence
%%====================================================================

ping_interval(#data{spec = Spec}) ->
    case maps:get(ping_interval, Spec, infinity) of
        infinity -> infinity;
        N when is_integer(N), N > 0 -> N
    end.

ping_failure_threshold(#data{spec = Spec}) ->
    maps:get(ping_failure_threshold, Spec, ?DEFAULT_PING_FAILURE_THRESHOLD).

bump_ping_failures(#data{ping_failures = N} = Data) ->
    Data#data{ping_failures = N + 1}.

maybe_close_on_ping_failures(Data, _Id) ->
    case Data#data.ping_failures >= ping_failure_threshold(Data) of
        true ->
            case Data#data.transport of
                {Mod, TPid} -> catch Mod:close(TPid);
                _ -> ok
            end,
            {stop, ping_failed};
        false ->
            {keep_state, Data, [arm_ping_timer(Data)]}
    end.

arm_ping_timer(Data) ->
    case ping_interval(Data) of
        infinity -> {state_timeout, infinity, ping_tick};
        N -> {state_timeout, N, ping_tick}
    end.

issue_ping(Data) ->
    {Id, Data1} = next_id(Data),
    send_envelope(Data1,
        barrel_mcp_protocol:encode_request(Id, <<"ping">>, #{})),
    P = #pending{caller = ping, method = <<"ping">>,
                 deadline = deadline(?DEFAULT_PING_TIMEOUT)},
    Pending = (Data1#data.pending)#{Id => P},
    {Data1#data{pending = Pending},
     [{{timeout, {req, Id}}, ?DEFAULT_PING_TIMEOUT, request_timeout},
      arm_ping_timer(Data1)]}.

is_supported(<<"initialize">>, _) -> true;
is_supported(<<"ping">>, _) -> true;
is_supported(<<"notifications/", _/binary>>, _) -> true;
is_supported(_, #data{server_capabilities = undefined}) -> false;
is_supported(<<"tools/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"tools">>, Caps);
is_supported(<<"resources/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"resources">>, Caps);
is_supported(<<"prompts/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"prompts">>, Caps);
is_supported(<<"completion/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"completions">>, Caps) orelse maps:is_key(<<"completion">>, Caps);
is_supported(<<"logging/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"logging">>, Caps);
is_supported(<<"tasks/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"tasks">>, Caps);
is_supported(_, _) -> true.

do_cancel(Id, #data{pending = Pending} = Data) ->
    case maps:take(Id, Pending) of
        {#pending{caller = From} = P, Rest} when From =/= init, From =/= ping ->
            gen_statem:reply(From, {error, cancelled}),
            send_envelope(Data, barrel_mcp_protocol:encode_notification(
                <<"notifications/cancelled">>,
                #{<<"requestId">> => Id, <<"reason">> => <<"cancelled by client">>})),
            Data1 = settle_data(P, Data#data{pending = Rest}),
            {keep_state, Data1, [drop_req_timeout(Id)]};
        _ ->
            keep_state_and_data
    end.

timeout_pending(Id, #data{pending = Pending} = Data) ->
    case maps:take(Id, Pending) of
        {#pending{caller = ping} = P, Rest} ->
            Data1 = settle_data(P, bump_ping_failures(Data#data{pending = Rest})),
            send_envelope(Data1, barrel_mcp_protocol:encode_notification(
                <<"notifications/cancelled">>,
                #{<<"requestId">> => Id, <<"reason">> => <<"timeout">>})),
            maybe_close_on_ping_failures(Data1, Id);
        {#pending{caller = From} = P, Rest} when From =/= init ->
            gen_statem:reply(From, {error, timeout}),
            send_envelope(Data, barrel_mcp_protocol:encode_notification(
                <<"notifications/cancelled">>,
                #{<<"requestId">> => Id, <<"reason">> => <<"timeout">>})),
            Data1 = settle_data(P, Data#data{pending = Rest}),
            {keep_state, Data1};
        _ ->
            keep_state_and_data
    end.

add_sub(Uri, Pid, Data) ->
    Subs = Data#data.subscriptions,
    Existing = maps:get(Uri, Subs, []),
    Data#data{subscriptions = Subs#{Uri => lists:usort([Pid | Existing])}}.

del_sub(Uri, Pid, Data) ->
    Subs = Data#data.subscriptions,
    case maps:get(Uri, Subs, []) of
        [] -> Data;
        L ->
            case lists:delete(Pid, L) of
                [] -> Data#data{subscriptions = maps:remove(Uri, Subs)};
                L1 -> Data#data{subscriptions = Subs#{Uri => L1}}
            end
    end.

%%====================================================================
%% Termination
%%====================================================================

terminate(Reason, _State,
          #data{handler_mod = Mod, handler_state = HS, transport = T}) ->
    case T of
        {Tmod, Pid} -> catch Tmod:close(Pid);
        _ -> ok
    end,
    case erlang:function_exported(Mod, terminate, 2) of
        true -> catch Mod:terminate(Reason, HS);
        false -> ok
    end,
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.
