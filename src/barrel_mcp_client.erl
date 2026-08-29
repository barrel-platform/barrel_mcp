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
    subscribe/2,
    unsubscribe/2,
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
    tasks_update/3,
    %% Misc
    complete/3,
    set_log_level/2,
    ping/1,
    cancel/2,
    notify_roots_list_changed/1,
    reply_async/3,
    %% Introspection
    server_info/1,
    server_capabilities/1,
    protocol_version/1
]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([connecting/3, probing/3, initializing/3, ready/3, closing/3]).

-type connect_spec() ::
    #{
        transport :=
            {http, binary() | string()}
            | {stdio, #{command := string(), args => [string()]}},
        client_info => #{name => binary(), version => binary()},
        capabilities => map(),
        handler => {module(), term()},
        auth =>
            none
            | {bearer, binary()}
            | {oauth, map()}
            | {oauth_client_credentials, map()}
            | {oauth_enterprise, map()}
            | {oauth_jwt_bearer, map()},
        %% The client's own restart budget under `barrel_mcp_clients':
        %% at most `intensity' restarts in `period' seconds (5 in 60 by
        %% default) before its id is given up on.
        restart => #{intensity => non_neg_integer(), period => pos_integer()},
        %% Which revision to speak. `auto' (the default) probes with
        %% `server/discover' and falls back to the `initialize'
        %% handshake when the server does not answer it. Pinning a
        %% modern revision (2026-07-28) skips the probe; pinning an
        %% older one goes straight to the handshake.
        protocol_version => auto | binary(),
        %% How long the `auto' probe waits before deciding the server
        %% is a handshake-era one. Only used when probing.
        probe_timeout => pos_integer(),
        request_timeout => pos_integer(),
        init_timeout => pos_integer(),
        ping_interval => pos_integer() | infinity,
        ping_failure_threshold => pos_integer(),
        %% Extra headers on every HTTP request. Servers configured with
        %% `allow_missing_origin => false' reject requests that carry no
        %% `Origin', so pass one here:
        %%   `http_headers => [{<<"origin">>, <<"https://app.example">>}]'
        %% Ignored by the stdio transport.
        http_headers => [{binary() | string(), binary() | string()}],
        %% Where the deprecated 2024-11-05 SSE stream lives, if the
        %% server hosts it somewhere other than the URL we probe. Used
        %% only after a Streamable POST is refused in a way that says
        %% the endpoint is not there; a path is never guessed.
        legacy_sse_url => binary()
    }.

-export_type([connect_spec/0]).

-define(DEFAULT_REQUEST_TIMEOUT, 30000).
-define(DEFAULT_PROBE_TIMEOUT, 5000).
%% How many times a request may be re-issued to satisfy a server's
%% input requests before the client gives up. A server is allowed to
%% ask repeatedly, so something has to bound it.
-define(DEFAULT_MAX_INPUT_ROUNDS, 5).
-define(DEFAULT_INIT_TIMEOUT, 30000).
-define(DEFAULT_PING_TIMEOUT, 5000).
-define(DEFAULT_PING_FAILURE_THRESHOLD, 3).

-record(pending, {
    caller :: init | ping | {pid(), term()},
    method :: binary(),
    %% Kept so a multi round-trip retry can re-issue the same call.
    params = #{} :: map(),
    timeout = infinity :: timeout(),
    deadline :: integer() | infinity,
    progress_token :: binary() | undefined,
    %% Which multi round-trip attempt this is, so a server that keeps
    %% asking is bounded across the whole exchange rather than per
    %% attempt.
    rounds = 1 :: pos_integer()
}).

%% A request the server answered with `input_required', paused while
%% the handler produces what it asked for. The retry is a new request
%% with a new id, so nothing here can live in `pending'.
-record(mrtr, {
    caller :: {pid(), term()},
    method :: binary(),
    params :: map(),
    timeout = infinity :: timeout(),
    request_state :: binary() | undefined,
    %% Absolute, and shared by every attempt: the caller asked for one
    %% call within one timeout, however many round trips it takes.
    deadline = infinity :: integer() | infinity,
    %% Handler replies that have not arrived yet: async tag => the key
    %% the server assigned to that input request.
    awaiting = #{} :: map(),
    responses = #{} :: map(),
    rounds = 1 :: pos_integer()
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
    %% Which revision this connection speaks. `legacy' negotiates with
    %% an `initialize' handshake; `modern' carries its version and
    %% capabilities on every request instead.
    era = legacy :: legacy | modern | auto,
    server_capabilities :: map() | undefined,
    server_info :: map() | undefined,
    protocol_version :: binary() | undefined,
    %% Multi round-trip rounds in flight, keyed by an opaque reference.
    %% Appended rather than inserted: a test reads `progress' out of
    %% this record by position.
    mrtr = #{} :: #{reference() => #mrtr{}},
    %% The id of the `subscriptions/listen' request holding the current
    %% stdio subscription. It has no request timeout: the response is
    %% what ends the subscription, and that may be hours away.
    sub_id :: integer() | undefined
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
-spec list_tools(pid(), map()) ->
    {ok, [map()], NextCursor :: binary() | undefined}
    | {ok, [map()]}
    | {error, term()}.
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
-spec list_resources(pid(), map()) ->
    {ok, [map()], binary() | undefined}
    | {ok, [map()]}
    | {error, term()}.
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
%%
%% `{error, {unsupported, <<"subscriptions/listen">>}}' on a modern
%% stdio connection, which has no second channel to hold a stream open.
-spec subscribe(pid(), binary()) -> {ok, map()} | {error, term()}.
subscribe(Pid, Uri) ->
    case gen_statem:call(Pid, {subscribe, Uri, self()}) of
        no_stream ->
            {error, {unsupported, <<"subscriptions/listen">>}};
        modern ->
            %% Nothing to request: the subscription is the stream, and
            %% opening it is what registers interest.
            {ok, #{}};
        legacy ->
            case request(Pid, <<"resources/subscribe">>, #{<<"uri">> => Uri}) of
                {ok, _} = Ok ->
                    ok = gen_statem:cast(Pid, {add_subscriber, Uri, self()}),
                    Ok;
                Err ->
                    Err
            end
    end.

%% @doc Stop receiving updates for `Uri' on the calling process.
%% Mirrors {@link subscribe/2} in both eras.
-spec unsubscribe(pid(), binary()) -> {ok, map()} | {error, term()}.
unsubscribe(Pid, Uri) ->
    case gen_statem:call(Pid, {unsubscribe, Uri, self()}) of
        no_stream ->
            {error, {unsupported, <<"subscriptions/listen">>}};
        modern ->
            {ok, #{}};
        legacy ->
            case request(Pid, <<"resources/unsubscribe">>, #{<<"uri">> => Uri}) of
                {ok, _} = Ok ->
                    ok = gen_statem:cast(Pid, {remove_subscriber, Uri, self()}),
                    Ok;
                Err ->
                    Err
            end
    end.

%% @doc List prompts advertised by the server. Single page.
-spec list_prompts(pid()) -> {ok, [map()]} | {error, term()}.
list_prompts(Pid) -> list_prompts(Pid, #{}).

%% @doc List prompts with pagination control. Same `Opts' shape as
%% {@link list_tools/2}.
-spec list_prompts(pid(), map()) ->
    {ok, [map()], binary() | undefined}
    | {ok, [map()]}
    | {error, term()}.
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

-spec tasks_list(pid(), map()) ->
    {ok, [map()], binary() | undefined}
    | {ok, [map()]}
    | {error, term()}.
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

%% @doc Supply answers a task was waiting on. Part of the tasks
%% extension, so it exists only on a modern connection.
-spec tasks_update(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
tasks_update(Pid, TaskId, Responses) when is_map(Responses) ->
    request(Pid, <<"tasks/update">>, #{
        <<"taskId">> => TaskId,
        <<"inputResponses">> => Responses
    }).

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

%% @doc Inform the connected server that the host's roots list has
%% changed. The server may follow up with `roots/list' to fetch
%% the new set. Hosts that mutate their roots after `initialize'
%% (e.g. user opened a new workspace) call this so the server
%% picks up the change without polling.
-spec notify_roots_list_changed(pid()) -> ok.
notify_roots_list_changed(Pid) ->
    gen_statem:cast(Pid, notify_roots_list_changed).

%% @doc Deliver a deferred reply for a server-initiated request that
%% the handler answered with `{async, Tag, _}'. `Result' is either a
%% plain term (sent as the JSON-RPC `result') or
%% `{error, Code, Message}'.
-spec reply_async(
    pid(),
    term(),
    term() | {error, integer(), binary()}
) -> ok.
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
            case era_of(Spec) of
                {error, _} = Err ->
                    Err;
                Era ->
                    Data = #data{
                        spec = Spec,
                        era = Era,
                        handler_mod = HandlerMod,
                        handler_state = HState
                    },
                    {ok, connecting, Data, [{next_event, internal, open_transport}]}
            end;
        {error, _} = Err ->
            Err
    end.

%%-- connecting -------------------------------------------------------

connecting(internal, open_transport, Data) ->
    case open_transport(Data) of
        {ok, Data1} ->
            InitTimeout = maps:get(
                init_timeout,
                Data#data.spec,
                ?DEFAULT_INIT_TIMEOUT
            ),
            open_with(Data1, InitTimeout);
        {error, Reason} ->
            {stop, {transport_failed, Reason}}
    end;
connecting({call, From}, _Req, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
connecting(EventType, EventContent, Data) ->
    common_handler(EventType, EventContent, Data).

%% Which state the connection opens in. A pinned legacy revision goes
%% straight to the handshake; everything else asks the server what it
%% serves first.
open_with(#data{era = legacy} = Data, InitTimeout) ->
    Params = build_initialize_params(Data),
    enter(Data, initializing, <<"initialize">>, Params, InitTimeout, init_timeout);
open_with(Data, _InitTimeout) ->
    Probe = probe_timeout(Data),
    Params = #{<<"_meta">> => request_meta(Data)},
    enter(Data, probing, <<"server/discover">>, Params, Probe, probe_timeout).

enter(Data, State, Method, Params, Timeout, TimeoutTag) ->
    {Id, Data1} = next_id(Data),
    send_envelope(Data1, barrel_mcp_protocol:encode_request(Id, Method, Params)),
    P = #pending{caller = init, method = Method, deadline = deadline(Timeout)},
    Pending = (Data1#data.pending)#{Id => P},
    {next_state, State, Data1#data{pending = Pending}, [
        {state_timeout, Timeout, TimeoutTag}
    ]}.

probe_timeout(#data{spec = Spec}) ->
    maps:get(probe_timeout, Spec, ?DEFAULT_PROBE_TIMEOUT).

init_timeout(#data{spec = Spec}) ->
    maps:get(init_timeout, Spec, ?DEFAULT_INIT_TIMEOUT).

%%-- probing ----------------------------------------------------------

%% The server has not answered the probe. On stdio a handshake-era
%% server may simply ignore an unknown method, so silence is itself the
%% answer.
probing(state_timeout, probe_timeout, Data) ->
    fall_back_or_stop(Data, probe_timeout);
probing({call, From}, _Req, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
probing(info, {mcp_in, Pid, Json}, #data{transport = {_, Pid}} = Data) ->
    handle_inbound(Json, probing, Data);
probing(EventType, EventContent, Data) ->
    common_handler(EventType, EventContent, Data).

%% Only a recognised modern error proves the server is modern. Anything
%% else, including an unknown method, means it never understood the
%% probe, so the handshake is worth trying.
fall_back_or_stop(#data{era = auto} = Data, _Why) ->
    InitTimeout = maps:get(init_timeout, Data#data.spec, ?DEFAULT_INIT_TIMEOUT),
    Data1 = Data#data{era = legacy, pending = #{}},
    open_with(Data1, InitTimeout);
fall_back_or_stop(_Data, Why) ->
    {stop, {probe_failed, Why}}.

%%-- initializing -----------------------------------------------------

initializing(state_timeout, init_timeout, _Data) ->
    {stop, init_timeout};
initializing({call, From}, _Req, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
initializing(
    info,
    {mcp_in, Pid, Json},
    #data{transport = {_, Pid}} = Data
) ->
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
            send_envelope(
                Data1,
                barrel_mcp_protocol:encode_request(
                    Id, Method, with_request_meta(Params, Data1)
                )
            ),
            ProgressToken = progress_token_from_params(Params),
            {CallerPid, _Tag} = From,
            Data2 =
                case ProgressToken of
                    undefined -> Data1;
                    Tok -> Data1#data{progress = (Data1#data.progress)#{Tok => CallerPid}}
                end,
            P = #pending{
                caller = From,
                method = Method,
                params = Params,
                timeout = Timeout,
                deadline = deadline(Timeout),
                progress_token = ProgressToken
            },
            Pending = (Data2#data.pending)#{Id => P},
            Actions =
                case Timeout of
                    infinity -> [];
                    T -> [{{timeout, {req, Id}}, T, request_timeout}]
                end,
            {keep_state, Data2#data{pending = Pending}, Actions}
    end;
ready(cast, {cancel, Id}, Data) ->
    do_cancel(Id, Data);
%% 2026-07-28 removed this notification along with Roots itself, so
%% there is nothing to send and nothing listening for it.
ready(cast, notify_roots_list_changed, #data{era = modern} = Data) ->
    {keep_state, Data};
ready(cast, notify_roots_list_changed, Data) ->
    send_envelope(
        Data,
        barrel_mcp_protocol:encode_notification(
            <<"notifications/roots/list_changed">>, #{}
        )
    ),
    {keep_state, Data};
%% Subscribing is era-specific, so the caller asks which one it is in
%% and takes the matching path. Doing it here rather than exposing the
%% era keeps `subscribe/2' looking the same to callers.
%%
ready({call, From}, {subscribe, Uri, Pid}, #data{era = modern} = Data) ->
    Data1 = add_sub(Uri, Pid, Data),
    {keep_state, refresh_subscription(Data1), [{reply, From, modern}]};
ready({call, From}, {subscribe, _Uri, _Pid}, _Data) ->
    {keep_state_and_data, [{reply, From, legacy}]};
ready({call, From}, {unsubscribe, Uri, Pid}, #data{era = modern} = Data) ->
    Data1 = del_sub(Uri, Pid, Data),
    {keep_state, refresh_subscription(Data1), [{reply, From, modern}]};
ready({call, From}, {unsubscribe, _Uri, _Pid}, _Data) ->
    {keep_state_and_data, [{reply, From, legacy}]};
ready(cast, {add_subscriber, Uri, Pid}, Data) ->
    {keep_state, add_sub(Uri, Pid, Data)};
ready(cast, {remove_subscriber, Uri, Pid}, Data) ->
    {keep_state, del_sub(Uri, Pid, Data)};
ready(cast, {async_reply, Tag, Result}, Data) ->
    {Data1, Actions} = deliver_async_reply(Tag, Result, Data),
    {keep_state, Data1, Actions};
ready({timeout, {req, Id}}, request_timeout, Data) ->
    timeout_pending(Id, Data);
ready({timeout, {round, Ref}}, round_timeout, Data) ->
    timeout_round(Ref, Data);
ready(state_timeout, ping_tick, Data) ->
    {Data1, Actions} = issue_ping(Data),
    {keep_state, Data1, Actions};
ready(
    info,
    {mcp_in, Pid, Json},
    #data{transport = {_, Pid}} = Data
) ->
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

common_handler(
    info,
    {mcp_closed, Pid, _Reason},
    #data{transport = {_, Pid}}
) ->
    {stop, normal};
common_handler(info, {'EXIT', _, _}, _Data) ->
    keep_state_and_data;
common_handler(cast, close, Data) ->
    case Data#data.transport of
        {Mod, Pid} ->
            try
                Mod:close(Pid)
            catch
                _:_ -> ok
            end;
        _ ->
            ok
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
        {error, Id, Code, Message, ErrData} ->
            handle_error_response(Id, Code, Message, ErrData, State, Data);
        _ ->
            keep_state_and_data
    end.

decode(Json) ->
    case barrel_mcp_protocol:decode(Json) of
        {ok, Map} -> barrel_mcp_protocol:decode_envelope(Map);
        Err -> Err
    end.

handle_response(Id, Result, probing, Data) ->
    case maps:take(Id, Data#data.pending) of
        {#pending{method = <<"server/discover">>}, Rest} ->
            handle_discover_result(Result, Data#data{pending = Rest});
        _ ->
            keep_state_and_data
    end;
handle_response(Id, Result, initializing, Data) ->
    case maps:take(Id, Data#data.pending) of
        {#pending{method = <<"initialize">>}, Rest} ->
            handle_initialize_result(Result, Data#data{pending = Rest});
        {#pending{method = <<"server/discover">>}, Rest} ->
            handle_discover_result(Result, Data#data{pending = Rest});
        _ ->
            keep_state_and_data
    end;
%% The response to `subscriptions/listen' is what ends it, so it settles
%% the retained id rather than a pending request.
handle_response(Id, _Result, _State, #data{sub_id = Id} = Data) ->
    {keep_state, Data#data{sub_id = undefined}};
handle_response(Id, Result, _State, Data) ->
    case maps:take(Id, Data#data.pending) of
        {#pending{caller = ping} = P, Rest} ->
            Data1 = settle_data(P, Data#data{pending = Rest, ping_failures = 0}),
            {keep_state, Data1, [drop_req_timeout(Id)]};
        {#pending{caller = From} = P, Rest} when From =/= init ->
            Data0 = settle_data(P, Data#data{pending = Rest}),
            {Result1, Data1} = observe_result(P, Result, Data0),
            case check_result_type(P, Result1, Data1) of
                {error, Why} ->
                    gen_statem:reply(From, {error, {invalid_result, Why}}),
                    {keep_state, Data1, [drop_req_timeout(Id)]};
                ok ->
                    settle_or_retry(Id, From, P, Result1, Data1)
            end;
        _ ->
            keep_state_and_data
    end.

settle_or_retry(Id, From, P, Result, Data) ->
    case input_required(Result, Data) of
        false ->
            gen_statem:reply(From, {ok, Result}),
            {keep_state, Data, [drop_req_timeout(Id)]};
        true ->
            {Data1, Actions} = begin_input_round(P, Result, Data),
            {keep_state, Data1, [drop_req_timeout(Id) | Actions]}
    end.

%% A version error is the one error that identifies a modern server: it
%% understood the probe and named what it does serve. Retry with a
%% revision off that list rather than falling back, because a
%% modern-only server has no handshake to fall back to.
%%
%% `protocol_version' is undefined until the first retry sets it, which
%% is what bounds this to one: a server that rejects the revision it
%% just advertised has nothing left to offer.
handle_error_response(
    _Id,
    ?MCP_UNSUPPORTED_PROTOCOL_VERSION,
    _Message,
    ErrData,
    probing,
    #data{protocol_version = undefined} = Data
) ->
    case mutual_version(supported_versions(ErrData)) of
        undefined ->
            fall_back_or_stop(Data, unsupported_version);
        Version ->
            Data1 = Data#data{protocol_version = Version, pending = #{}},
            open_with(Data1, init_timeout(Data1))
    end;
handle_error_response(_Id, _Code, _Message, _ErrData, probing, Data) ->
    fall_back_or_stop(Data, probe_rejected);
handle_error_response(_Id, Code, Message, _ErrData, initializing, _Data) ->
    {stop, {init_failed, Code, Message}};
handle_error_response(Id, Code, Message, _ErrData, _State, Data) ->
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
drop_progress(Tok, Data) -> Data#data{progress = maps:remove(Tok, Data#data.progress)}.

drop_req_timeout(Id) ->
    {{timeout, {req, Id}}, infinity, request_timeout}.

handle_server_request(
    Id,
    Method,
    Params,
    _State,
    #data{handler_mod = Mod, handler_state = HS} = Data
) ->
    case ask_handler_for(Mod, Method, Params, HS) of
        {reply, Result, HS1} ->
            send_envelope(Data, barrel_mcp_protocol:encode_response(Id, Result)),
            {keep_state, Data#data{handler_state = HS1}};
        {error, Code, Msg, HS1} ->
            send_envelope(Data, barrel_mcp_protocol:encode_error(Id, Code, Msg)),
            {keep_state, Data#data{handler_state = HS1}};
        {async, Tag, HS1} ->
            Async = (Data#data.async_replies)#{Tag => Id},
            {keep_state, Data#data{
                handler_state = HS1,
                async_replies = Async
            }}
    end.

%% One entry point for both paths a server can ask on: a legacy request,
%% and a modern `inputRequests' entry.
ask_handler_for(Mod, <<"elicitation/create">>, Params, HS) ->
    case url_elicitation(Params) of
        no -> Mod:handle_request(<<"elicitation/create">>, Params, HS);
        {ok, Request} -> ask_url_consent(Mod, Request, HS);
        {error, Reason} -> refuse_url(Reason, Params, HS)
    end;
ask_handler_for(Mod, Method, Params, HS) ->
    Mod:handle_request(Method, Params, HS).

%% "Clients MUST treat requests without a `mode' field as form mode"
%% (2026-07-28/client/elicitation.mdx:97).
url_elicitation(Params) when is_map(Params) ->
    case maps:get(<<"mode">>, Params, <<"form">>) of
        <<"url">> -> url_request(Params);
        _ -> no
    end;
url_elicitation(_Params) ->
    no.

url_request(Params) ->
    Url = maps:get(<<"url">>, Params, undefined),
    case barrel_mcp_elicitation:inspect_url(Url) of
        {error, _} = Err ->
            Err;
        {ok, Host} ->
            Base = #{
                url => Url,
                host => Host,
                message => maps:get(<<"message">>, Params, <<>>)
            },
            case maps:get(<<"elicitationId">>, Params, undefined) of
                Id when is_binary(Id) -> {ok, Base#{elicitation_id => Id}};
                _ -> {ok, Base}
            end
    end.

%% Cancelled rather than declined: nobody was asked, so there is no
%% decision to report.
refuse_url(Reason, Params, HS) ->
    logger:warning(
        "Refused a URL-mode elicitation: ~p (host=~p)",
        [Reason, safe_host(Params)]
    ),
    {reply, elicitation_action(cancel), HS}.

%% The host only: a credential would be in the path or query.
safe_host(Params) ->
    case barrel_mcp_elicitation:inspect_url(maps:get(<<"url">>, Params, undefined)) of
        {ok, Host} -> Host;
        _ -> undefined
    end.

ask_url_consent(Mod, Request, HS) ->
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, handle_elicitation_url, 2) of
        false ->
            %% No consent UI means no consent.
            {reply, elicitation_action(decline), HS};
        true ->
            case Mod:handle_elicitation_url(Request, HS) of
                {async, Tag, HS1} -> {async, Tag, HS1};
                {Action, HS1} -> {reply, elicitation_action(Action), HS1}
            end
    end.

%% "For URL mode: the `content' field is omitted" (elicitation.mdx:445).
elicitation_action(accept) -> #{<<"action">> => <<"accept">>};
elicitation_action(decline) -> #{<<"action">> => <<"decline">>};
elicitation_action(_Other) -> #{<<"action">> => <<"cancel">>}.

deliver_async_reply(Tag, Result0, Data) ->
    Result = normalize_async_reply(Result0),
    case deliver_input_reply(Tag, Result, Data) of
        {ok, {Data1, Actions}} -> {Data1, Actions};
        not_found -> {deliver_server_reply(Tag, Result, Data), []}
    end.

%% A deferred URL-mode consent answers with the decision alone. Nothing
%% else uses these atoms as a result.
normalize_async_reply(accept) -> elicitation_action(accept);
normalize_async_reply(decline) -> elicitation_action(decline);
normalize_async_reply(cancel) -> elicitation_action(cancel);
normalize_async_reply(Result) -> Result.

deliver_server_reply(Tag, Result, Data) ->
    case maps:take(Tag, Data#data.async_replies) of
        {Id, Rest} ->
            Envelope =
                case Result of
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

handle_server_notification(
    <<"notifications/resources/updated">> = Method,
    Params,
    _State,
    Data
) ->
    Uri = maps:get(<<"uri">>, Params, <<>>),
    notify_subscribers(Uri, Params, Data),
    dispatch_notification(Method, Params, Data);
handle_server_notification(
    <<"notifications/progress">> = Method,
    Params,
    _State,
    Data
) ->
    notify_progress(Params, Data),
    dispatch_notification(Method, Params, Data);
%% The server tears a subscription down by cancelling its listen id, so
%% the retained id goes with it rather than waiting for a response that
%% now names nothing.
handle_server_notification(
    <<"notifications/cancelled">> = Method,
    Params,
    _State,
    #data{sub_id = SubId} = Data
) when SubId =/= undefined ->
    case maps:get(<<"requestId">>, Params, undefined) of
        SubId -> dispatch_notification(Method, Params, Data#data{sub_id = undefined});
        _ -> dispatch_notification(Method, Params, Data)
    end;
handle_server_notification(Method, Params, _State, Data) ->
    dispatch_notification(Method, Params, Data).

dispatch_notification(
    Method,
    Params,
    #data{handler_mod = Mod, handler_state = HS} = Data
) ->
    case Mod:handle_notification(Method, Params, HS) of
        {ok, HS1} ->
            {keep_state, Data#data{handler_state = HS1}}
    end.

notify_subscribers(Uri, Params, Data) ->
    case maps:get(Uri, Data#data.subscriptions, []) of
        [] ->
            ok;
        Pids ->
            lists:foreach(
                fun(P) -> P ! {mcp_resource_updated, Uri, Params} end,
                Pids
            ),
            ok
    end.

notify_progress(Params, Data) ->
    case maps:get(<<"progressToken">>, Params, undefined) of
        undefined ->
            ok;
        Tok ->
            case maps:get(Tok, Data#data.progress, undefined) of
                undefined ->
                    ok;
                Pid ->
                    Pid ! {mcp_progress, Tok, Params},
                    ok
            end
    end.

%%====================================================================
%% Tool definitions
%%====================================================================

%% A `tools/list' result is the only place a client learns which
%% arguments a tool wants mirrored into headers, so it is read on the
%% way past rather than left to whoever called.
observe_result(#pending{method = <<"tools/list">>}, Result, Data) ->
    case maps:get(<<"tools">>, Result, undefined) of
        Tools when is_list(Tools) ->
            {Kept, Bindings} = scan_tools(Tools),
            {Result#{<<"tools">> => Kept}, cache_tool_headers(Bindings, Data)};
        _ ->
            {Result, Data}
    end;
observe_result(_Pending, Result, Data) ->
    {Result, Data}.

%% A tool definition we cannot act on is dropped on its own. Offering it
%% and failing on use would be worse, and one malformed tool must not
%% take the rest of the catalogue with it.
scan_tools(Tools) ->
    lists:foldr(fun scan_tool/2, {[], #{}}, Tools).

scan_tool(Tool, {Kept, Bindings}) ->
    Name = maps:get(<<"name">>, Tool, <<>>),
    case check_peer_tool(Tool) of
        {error, Reason} ->
            logger:warning(
                "barrel_mcp client: excluding tool ~ts from tools/list: ~p",
                [Name, Reason]
            ),
            {Kept, Bindings};
        {ok, Tool1, []} ->
            {[Tool1 | Kept], Bindings};
        {ok, Tool1, Params} ->
            {[Tool1 | Kept], Bindings#{Name => Params}}
    end.

%% Two different failures. An `inputSchema' we cannot use is fatal to the
%% tool: it is what arguments are built against and what header
%% mirroring is read from. An `outputSchema' we cannot use is not, since
%% nothing here validates a result against it, so only that field goes.
check_peer_tool(Tool) ->
    Schema = maps:get(<<"inputSchema">>, Tool, #{}),
    case usable_schema(Schema) of
        {error, Reason} ->
            {error, {input_schema, Reason}};
        ok when not is_map(Schema) ->
            {error, {input_schema, not_an_object}};
        ok ->
            case barrel_mcp_headers:scan_header_params(Schema) of
                {error, Reason} -> {error, {x_mcp_header, Reason}};
                {ok, Params} -> {ok, without_bad_output_schema(Tool), Params}
            end
    end.

without_bad_output_schema(Tool) ->
    case maps:find(<<"outputSchema">>, Tool) of
        error ->
            Tool;
        {ok, Schema} ->
            case usable_schema(Schema) of
                ok ->
                    Tool;
                {error, Reason} ->
                    logger:warning(
                        "barrel_mcp client: dropping the outputSchema of tool ~ts: ~p",
                        [maps:get(<<"name">>, Tool, <<>>), Reason]
                    ),
                    maps:remove(<<"outputSchema">>, Tool)
            end
    end.

%% Both that it is a schema at all, and that its references resolve
%% without reaching the network.
usable_schema(Schema) when is_map(Schema) ->
    case barrel_mcp_jsonschema:validate_schema(Schema) of
        {error, Errors} ->
            {error, {not_a_schema, Errors}};
        ok ->
            case barrel_mcp_jsonschema:compile(Schema) of
                {ok, _} -> ok;
                {error, Reason} -> {error, Reason}
            end
    end;
usable_schema(_Schema) ->
    {error, not_an_object}.

%% Header mirroring arrived with 2026-07-28, and only the HTTP transport
%% has headers to mirror into.
cache_tool_headers(Bindings, #data{era = modern, transport = Transport} = Data) when
    element(1, Transport) =:= barrel_mcp_client_http
->
    ok = barrel_mcp_client_http:set_tool_headers(element(2, Transport), Bindings),
    Data;
cache_tool_headers(_Bindings, Data) ->
    Data.

%%====================================================================
%% Subscriptions
%%====================================================================

%% One stream carries every URI currently subscribed. Changing the set
%% means replacing it: the filter is fixed when the stream opens, so
%% there is nothing to amend in place.
refresh_subscription(#data{transport = {barrel_mcp_client_http, Pid}} = Data) ->
    case maps:keys(Data#data.subscriptions) of
        [] ->
            ok = barrel_mcp_client_http:close_subscription(Pid),
            Data;
        Uris ->
            {Id, Data1} = next_id(Data),
            Body = barrel_mcp_protocol:encode(
                barrel_mcp_protocol:encode_request(
                    Id,
                    <<"subscriptions/listen">>,
                    with_request_meta(
                        #{
                            <<"notifications">> => #{
                                <<"resourceSubscriptions">> => Uris
                            }
                        },
                        Data1
                    )
                )
            ),
            ok = barrel_mcp_client_http:open_subscription(Pid, Body),
            Data1
    end;
%% stdio has one channel, so the listen request is sent like any other
%% and its notifications arrive interleaved. Changing the filter means
%% cancelling first: two overlapping streams would deliver twice.
refresh_subscription(#data{transport = {barrel_mcp_client_stdio, _}} = Data) ->
    Data1 = cancel_stdio_subscription(Data),
    case maps:keys(Data1#data.subscriptions) of
        [] ->
            Data1;
        Uris ->
            {Id, Data2} = next_id(Data1),
            Params = #{
                <<"notifications">> => #{<<"resourceSubscriptions">> => Uris}
            },
            send_envelope(
                Data2,
                barrel_mcp_protocol:encode_request(
                    Id, <<"subscriptions/listen">>, with_request_meta(Params, Data2)
                )
            ),
            %% Retained without a request timeout: the response is the
            %% end of the subscription, not a late answer.
            Data2#data{sub_id = Id}
    end;
refresh_subscription(Data) ->
    Data.

cancel_stdio_subscription(#data{sub_id = undefined} = Data) ->
    Data;
cancel_stdio_subscription(#data{sub_id = Id} = Data) ->
    send_cancelled(Id, <<"filter changed">>, Data),
    Data#data{sub_id = undefined}.

%%====================================================================
%% Multi round-trip requests
%%====================================================================

%% A client that does not understand a result must not act on it, so an
%% unrecognised discriminator is an error rather than a success.
check_result_type(_P, _Result, #data{era = Era}) when Era =/= modern ->
    %% Legacy carries no discriminator; absent means complete.
    ok;
check_result_type(#pending{method = Method}, Result, Data) when is_map(Result) ->
    case maps:get(<<"resultType">>, Result, undefined) of
        undefined -> {error, missing_result_type};
        <<"complete">> -> ok;
        <<"input_required">> -> ok;
        <<"task">> -> task_result_allowed(Method, Data);
        Other -> {error, {unknown_result_type, Other}}
    end;
check_result_type(_P, _Result, _Data) ->
    ok.

%% "A server MUST NOT return CreateTaskResult to a client that did not
%% include the extension capability on its request, regardless of prior
%% declarations" (ext-tasks tasks.md:59): what we sent, not what the
%% server advertised.
task_result_allowed(Method, #data{spec = Spec}) ->
    Declared = capabilities_to_wire(maps:get(capabilities, Spec, #{})),
    Extensions = maps:get(<<"extensions">>, Declared, #{}),
    case is_map(Extensions) andalso maps:is_key(?MCP_EXT_TASKS, Extensions) of
        false -> {error, task_without_extension};
        true -> task_augmentable(Method)
    end.

%% The only task-augmentable method the extension defines, and one for
%% anything else "MUST" read as an invalid response (tasks.md:59).
task_augmentable(<<"tools/call">>) -> ok;
task_augmentable(Method) -> {error, {task_not_allowed_for, Method}}.

%% Only a modern server answers this way. A legacy one issues real
%% requests instead, which `handle_server_request/5' serves.
input_required(#{<<"resultType">> := <<"input_required">>}, #data{era = modern}) ->
    true;
input_required(_Result, _Data) ->
    false.

begin_input_round(#pending{caller = From, method = Method, params = Params} = P, Result, Data) ->
    Round = #mrtr{
        caller = From,
        method = Method,
        params = Params,
        timeout = P#pending.timeout,
        deadline = P#pending.deadline,
        request_state = maps:get(<<"requestState">>, Result, undefined),
        rounds = P#pending.rounds
    },
    dispatch_input_requests(maps:get(<<"inputRequests">>, Result, #{}), Round, Data).

%% Ask the handler for each thing the server wants. A handler that
%% answers immediately is collected here; one that defers is recorded
%% and the round waits for `reply_async/3'.
dispatch_input_requests(Requests, Round, Data) when is_map(Requests) ->
    Ref = make_ref(),
    {Round1, Data1} = maps:fold(
        fun(Key, Request, {R, D}) -> ask_handler(Ref, Key, Request, R, D) end,
        {Round, Data},
        Requests
    ),
    Rounds = (Data1#data.mrtr)#{Ref => Round1},
    maybe_retry(Ref, Data1#data{mrtr = Rounds});
dispatch_input_requests(_Requests, Round, Data) ->
    %% No requests at all: the server only wants the state echoed back.
    Ref = make_ref(),
    maybe_retry(Ref, Data#data{mrtr = (Data#data.mrtr)#{Ref => Round}}).

%% Time left of the caller's budget. Rounds share it rather than each
%% getting a fresh one, or a request could outlive the timeout the
%% caller asked for several times over.
round_remaining(infinity) ->
    infinity;
round_remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

ask_handler(Ref, Key, Request, Round, #data{handler_mod = Mod, handler_state = HS} = Data) ->
    Method = maps:get(<<"method">>, Request, <<>>),
    Params = maps:get(<<"params">>, Request, #{}),
    case ask_handler_for(Mod, Method, Params, HS) of
        {reply, Result, HS1} ->
            Responses = (Round#mrtr.responses)#{Key => Result},
            {Round#mrtr{responses = Responses}, Data#data{handler_state = HS1}};
        {async, Tag, HS1} ->
            Awaiting = (Round#mrtr.awaiting)#{Tag => {Ref, Key}},
            {Round#mrtr{awaiting = Awaiting}, Data#data{handler_state = HS1}};
        {error, Code, Msg, HS1} ->
            %% The client cannot produce what was asked for, so there
            %% is nothing to retry with.
            Responses = (Round#mrtr.responses)#{Key => {error, Code, Msg}},
            {Round#mrtr{responses = Responses}, Data#data{handler_state = HS1}}
    end.

%% Re-issue once every input request has an answer.
maybe_retry(Ref, Data) ->
    case maps:get(Ref, Data#data.mrtr, undefined) of
        undefined ->
            {Data, []};
        #mrtr{awaiting = Awaiting} = Round when map_size(Awaiting) =:= 0 ->
            Rounds = maps:remove(Ref, Data#data.mrtr),
            {Data1, Actions} = finish_input_round(Round, Data#data{mrtr = Rounds}),
            {Data1, [cancel_round_timeout(Ref) | Actions]};
        Waiting ->
            %% Still waiting on a deferred handler. The round holds the
            %% caller's budget now that the request timeout is gone, so
            %% it needs its own. Re-arming recomputes from the shared
            %% deadline, so it cannot extend anything.
            {Data, [arm_round_timeout(Ref, Waiting)]}
    end.

arm_round_timeout(Ref, #mrtr{deadline = Deadline}) ->
    {{timeout, {round, Ref}}, round_remaining(Deadline), round_timeout}.

cancel_round_timeout(Ref) ->
    {{timeout, {round, Ref}}, infinity, round_timeout}.

finish_input_round(#mrtr{caller = From, responses = Responses} = Round, Data) ->
    case [E || {_K, {error, _, _} = E} <- maps:to_list(Responses)] of
        [{error, Code, Msg} | _] ->
            gen_statem:reply(From, {error, {input_failed, Code, Msg}}),
            {Data, []};
        [] ->
            retry_request(Round, Data)
    end.

retry_request(#mrtr{rounds = Rounds} = Round, Data) ->
    Max = maps:get(max_input_rounds, Data#data.spec, ?DEFAULT_MAX_INPUT_ROUNDS),
    case Rounds > Max of
        true ->
            gen_statem:reply(
                Round#mrtr.caller,
                {error, {too_many_input_rounds, Max}}
            ),
            {Data, []};
        false ->
            send_retry(Round, round_remaining(Round#mrtr.deadline), Data)
    end.

%% A retry is an independent request: a new id, the original params,
%% the answers gathered, and the state echoed back untouched.
send_retry(#mrtr{caller = From}, 0, Data) ->
    %% The budget went on the earlier attempts; there is no point
    %% starting another.
    gen_statem:reply(From, {error, timeout}),
    {Data, []};
send_retry(#mrtr{method = Method, params = Params, timeout = Timeout} = Round, Remaining, Data) ->
    {Id, Data1} = next_id(Data),
    Retry = with_input_responses(Params, Round),
    send_envelope(
        Data1,
        barrel_mcp_protocol:encode_request(
            Id, Method, with_request_meta(Retry, Data1)
        )
    ),
    P = #pending{
        caller = Round#mrtr.caller,
        method = Method,
        params = Params,
        timeout = Timeout,
        deadline = Round#mrtr.deadline,
        %% Carried forward so a further input_required counts up
        %% rather than starting over.
        progress_token = progress_token_from_params(Params),
        rounds = Round#mrtr.rounds + 1
    },
    Pending = (Data1#data.pending)#{Id => P},
    Actions =
        case Remaining of
            infinity -> [];
            _ -> [{{timeout, {req, Id}}, Remaining, request_timeout}]
        end,
    {Data1#data{pending = Pending}, Actions}.

with_input_responses(Params, #mrtr{responses = Responses, request_state = State}) ->
    P1 =
        case map_size(Responses) of
            0 -> Params;
            _ -> Params#{<<"inputResponses">> => Responses}
        end,
    case State of
        undefined -> P1;
        _ -> P1#{<<"requestState">> => State}
    end.

%% An async handler reply that belongs to a round rather than to a
%% server-initiated request.
deliver_input_reply(Tag, Result, Data) ->
    case find_round(Tag, Data#data.mrtr) of
        undefined ->
            not_found;
        {Ref, Key, Round} ->
            Round1 = Round#mrtr{
                awaiting = maps:remove(Tag, Round#mrtr.awaiting),
                responses = (Round#mrtr.responses)#{Key => Result}
            },
            Rounds = (Data#data.mrtr)#{Ref => Round1},
            {ok, maybe_retry(Ref, Data#data{mrtr = Rounds})}
    end.

%% `deliver_async_reply/3' may now need to arm a timeout for a retry it
%% just triggered, so it returns actions alongside the new state.

find_round(Tag, Rounds) ->
    maps:fold(
        fun
            (Ref, #mrtr{awaiting = Awaiting} = Round, undefined) ->
                case maps:get(Tag, Awaiting, undefined) of
                    {Ref, Key} -> {Ref, Key, Round};
                    _ -> undefined
                end;
            (_Ref, _Round, Found) ->
                Found
        end,
        undefined,
        Rounds
    ).

%% A round whose handler never answered. The caller has been waiting on
%% it since the original request, so it gets the same timeout it would
%% have got had the server simply not replied.
timeout_round(Ref, Data) ->
    case maps:take(Ref, Data#data.mrtr) of
        {#mrtr{caller = From}, Rounds} ->
            gen_statem:reply(From, {error, timeout}),
            {keep_state, Data#data{mrtr = Rounds}};
        error ->
            keep_state_and_data
    end.

%%====================================================================
%% Initialize handling
%%====================================================================

%% Which era this connection speaks, from the version the caller
%% pinned. Unrecognised values fall back to the handshake, which is
%% what every server before 2026-07-28 understands.
%% Pinning a revision we do not implement is a caller error, not a
%% runtime condition: silently opening a handshake and taking whatever
%% the server offers would give them something other than what they
%% asked for, without saying so.
era_of(Spec) ->
    case maps:get(protocol_version, Spec, auto) of
        auto ->
            auto;
        Version when is_binary(Version) ->
            case barrel_mcp_version:era(Version) of
                unknown -> {error, {unsupported_protocol_version, Version}};
                Era -> Era
            end;
        Other ->
            {error, {invalid_protocol_version, Other}}
    end.

%% Everything a modern request has to carry, on every request: there is
%% no handshake to have established it.
request_meta(#data{spec = Spec, protocol_version = Negotiated}) ->
    Base = #{
        ?MCP_META_PROTOCOL_VERSION => modern_version(Spec, Negotiated),
        ?MCP_META_CLIENT_CAPABILITIES =>
            capabilities_to_wire(maps:get(capabilities, Spec, #{}))
    },
    case maps:get(client_info, Spec, undefined) of
        undefined -> Base;
        Info -> Base#{?MCP_META_CLIENT_INFO => normalize_keys(Info)}
    end.

%% Before discovery settles there is nothing negotiated, so the probe
%% names the newest revision we implement.
modern_version(_Spec, Negotiated) when is_binary(Negotiated) ->
    Negotiated;
modern_version(Spec, _Negotiated) ->
    case maps:get(protocol_version, Spec, auto) of
        V when is_binary(V) -> V;
        _ -> ?MCP_LATEST_MODERN_VERSION
    end.

build_initialize_params(#data{spec = Spec}) ->
    ClientInfo0 = maps:get(
        client_info,
        Spec,
        #{
            <<"name">> => <<"barrel_mcp_client">>,
            <<"version">> => <<"3.0.0">>
        }
    ),
    ClientInfo = normalize_keys(ClientInfo0),
    Caps = capabilities_to_wire(maps:get(capabilities, Spec, #{})),
    Version = maps:get(protocol_version, Spec, ?MCP_LATEST_LEGACY_VERSION),
    #{
        <<"protocolVersion">> => Version,
        <<"capabilities">> => Caps,
        <<"clientInfo">> => ClientInfo
    }.

%% Sugar -> spec-shaped wire form. `true' becomes an empty object;
%% maps are passed through with binary keys.
capabilities_to_wire(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key = cap_key(K),
            Acc#{Key => cap_value(Key, V)}
        end,
        #{},
        Map
    ).

%% Modes are declared as objects, not booleans: `{"form": {}, "url": {}}'
%% (2026-07-28/client/elicitation.mdx:55).
cap_value(<<"elicitation">>, Map) when is_map(Map) ->
    maps:fold(
        fun
            (_K, false, Acc) -> Acc;
            (K, true, Acc) -> Acc#{cap_subkey(K) => #{}};
            (K, V, Acc) -> Acc#{cap_subkey(K) => V}
        end,
        #{},
        Map
    );
cap_value(_Key, V) ->
    cap_value(V).

cap_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
cap_key(K) when is_binary(K) -> K.

cap_value(true) ->
    #{};
cap_value(false) ->
    undefined;
cap_value(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            case V of
                false -> Acc;
                _ -> Acc#{cap_subkey(K) => cap_subvalue(V)}
            end
        end,
        #{},
        Map
    );
cap_value(_) ->
    #{}.

cap_subkey(list_changed) -> <<"listChanged">>;
cap_subkey(K) when is_atom(K) -> atom_to_binary(K, utf8);
cap_subkey(K) when is_binary(K) -> K.

cap_subvalue(true) -> true;
cap_subvalue(V) -> V.

normalize_keys(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            Key =
                case K of
                    A when is_atom(A) -> atom_to_binary(A, utf8);
                    B when is_binary(B) -> B
                end,
            Acc#{Key => V}
        end,
        #{},
        Map
    ).

%% Discovery is not a handshake: nothing is negotiated, the server just
%% reports what it serves. A version we cannot speak is fatal, since
%% every subsequent request would be rejected the same way.
handle_discover_result(Result, Data) ->
    Supported = maps:get(<<"supportedVersions">>, Result, []),
    case mutual_version(Supported) of
        undefined ->
            %% Modern, but not on any revision we implement. Probing
            %% may still find a handshake it will answer.
            fall_back_or_stop(Data, {no_mutual_version, Supported});
        Version ->
            Meta = maps:get(<<"_meta">>, Result, #{}),
            Data1 = Data#data{
                era = modern,
                server_capabilities = maps:get(<<"capabilities">>, Result, #{}),
                server_info = maps:get(?MCP_META_SERVER_INFO, Meta, #{}),
                protocol_version = Version
            },
            {next_state, ready, Data1, [arm_ping_timer(Data1)]}
    end.

%% What an UnsupportedProtocolVersion error offers instead.
supported_versions(ErrData) when is_map(ErrData) ->
    maps:get(<<"supported">>, ErrData, []);
supported_versions(_ErrData) ->
    [].

%% The server lists newest first, so the first of ours it names is the
%% newest both ends speak.
mutual_version(Supported) when is_list(Supported) ->
    case [V || V <- Supported, lists:member(V, ?MCP_MODERN_VERSIONS)] of
        [Version | _] -> Version;
        [] -> undefined
    end;
mutual_version(_Supported) ->
    undefined.

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
    send_envelope(
        Data,
        barrel_mcp_protocol:encode_notification(
            <<"notifications/initialized">>, #{}
        )
    ),
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
                {error, _} = Err ->
                    Err;
                _ ->
                    Opts = #{
                        url => Url,
                        auth => Auth,
                        open_event_stream => true,
                        headers => maps:get(http_headers, Spec, []),
                        legacy_sse_url => maps:get(legacy_sse_url, Spec, undefined),
                        %% A 401 can arrive before any version is
                        %% negotiated; the auth flow branches on the
                        %% one the host asked for then.
                        requested_version =>
                            case maps:get(protocol_version, Spec, auto) of
                                auto -> undefined;
                                Requested -> Requested
                            end
                    },
                    case barrel_mcp_client_http:connect(self(), Opts) of
                        {ok, Pid} ->
                            link(Pid),
                            {ok, Data#data{transport = {barrel_mcp_client_http, Pid}}};
                        Err ->
                            Err
                    end
            end;
        {stdio, StdioOpts} ->
            case barrel_mcp_client_stdio:connect(self(), StdioOpts) of
                {ok, Pid} ->
                    link(Pid),
                    {ok, Data#data{transport = {barrel_mcp_client_stdio, Pid}}};
                Err ->
                    Err
            end
    end.

send_envelope(#data{transport = {Mod, Pid}}, Envelope) ->
    Json = iolist_to_binary(json:encode(Envelope)),
    Mod:send(Pid, Json);
send_envelope(_, _) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

next_id(#data{request_id = N} = Data) ->
    {N, Data#data{request_id = N + 1}}.

deadline(infinity) ->
    infinity;
deadline(T) when is_integer(T) ->
    erlang:monotonic_time(millisecond) + T.

request(Pid, Method, Params) ->
    request(Pid, Method, Params, ?DEFAULT_REQUEST_TIMEOUT).

request(Pid, Method, Params, Timeout) ->
    CallTimeout =
        case Timeout of
            infinity -> infinity;
            T when is_integer(T) -> T + 5000
        end,
    gen_statem:call(Pid, {request, Method, Params, Timeout}, CallTimeout).

walk_all(Fetch) ->
    barrel_mcp_pagination:walk(Fetch).

page_opts(undefined) -> #{want_cursor => true};
page_opts(Cursor) -> #{cursor => Cursor, want_cursor => true}.

paged(Pid, Method, ResultKey, Opts) ->
    Params =
        case maps:get(cursor, Opts, undefined) of
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
        Err ->
            Err
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

%% A legacy request carries only what the caller put in `_meta'; a
%% modern one also carries the protocol fields, merged so a progress
%% token set by the caller survives.
with_request_meta(Params, #data{era = legacy}) ->
    Params;
with_request_meta(Params, #data{era = modern} = Data) ->
    Existing =
        case maps:get(<<"_meta">>, Params, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    Params#{<<"_meta">> => maps:merge(Existing, request_meta(Data))}.

progress_token_from_params(#{<<"_meta">> := #{<<"progressToken">> := Tok}}) ->
    Tok;
progress_token_from_params(_) ->
    undefined.

%%====================================================================
%% Ping cadence
%%====================================================================

%% There is no ping in the modern era, so a configured cadence would
%% only produce method-not-found on a timer.
ping_interval(#data{era = modern}) ->
    infinity;
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
                {Mod, TPid} ->
                    try
                        Mod:close(TPid)
                    catch
                        _:_ -> ok
                    end;
                _ ->
                    ok
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
    send_envelope(
        Data1,
        barrel_mcp_protocol:encode_request(Id, <<"ping">>, #{})
    ),
    P = #pending{
        caller = ping,
        method = <<"ping">>,
        deadline = deadline(?DEFAULT_PING_TIMEOUT)
    },
    Pending = (Data1#data.pending)#{Id => P},
    {Data1#data{pending = Pending}, [
        {{timeout, {req, Id}}, ?DEFAULT_PING_TIMEOUT, request_timeout},
        arm_ping_timer(Data1)
    ]}.

%% A method the negotiated revision removed is not something to send
%% and let the server reject: the caller gets a clear answer instead.
is_supported(Method, #data{era = modern}) when
    Method =:= <<"initialize">>;
    Method =:= <<"ping">>;
    Method =:= <<"logging/setLevel">>;
    Method =:= <<"tasks/list">>;
    Method =:= <<"tasks/result">>
->
    false;
%% Likewise the other way: these arrived with 2026-07-28.
is_supported(Method, #data{era = Era}) when
    Era =/= modern,
    Method =:= <<"subscriptions/listen">>
->
    false;
is_supported(Method, #data{era = Era}) when
    Era =/= modern,
    Method =:= <<"tasks/update">>
->
    false;
is_supported(<<"initialize">>, _) ->
    true;
is_supported(<<"ping">>, _) ->
    true;
is_supported(<<"notifications/", _/binary>>, _) ->
    true;
is_supported(_, #data{server_capabilities = undefined}) ->
    false;
is_supported(<<"tools/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"tools">>, Caps);
%% Subscribing needs the sub-capability, not just the family: a server
%% advertising `resources' without `subscribe' has no subscribe method.
is_supported(<<"resources/subscribe">>, #data{server_capabilities = Caps}) ->
    sub_capability(Caps, <<"resources">>, <<"subscribe">>);
is_supported(<<"resources/unsubscribe">>, #data{server_capabilities = Caps}) ->
    sub_capability(Caps, <<"resources">>, <<"subscribe">>);
is_supported(<<"resources/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"resources">>, Caps);
is_supported(<<"prompts/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"prompts">>, Caps);
is_supported(<<"completion/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"completions">>, Caps) orelse maps:is_key(<<"completion">>, Caps);
is_supported(<<"logging/", _/binary>>, #data{server_capabilities = Caps}) ->
    maps:is_key(<<"logging">>, Caps);
is_supported(<<"tasks/", _/binary>>, #data{era = modern} = Data) ->
    %% Modern servers advertise tasks as an extension, not a capability,
    %% and its object is empty: naming the identifier is the
    %% declaration, so there is nothing finer to check.
    Caps = Data#data.server_capabilities,
    Extensions = maps:get(<<"extensions">>, Caps, #{}),
    is_map(Extensions) andalso maps:is_key(?MCP_EXT_TASKS, Extensions);
is_supported(<<"tasks/", Op/binary>>, #data{server_capabilities = Caps}) ->
    task_op_declared(maps:get(<<"tasks">>, Caps, undefined), Op);
is_supported(_, _) ->
    true.

%% A legacy `tasks' capability names each operation it has, so a server
%% offering `get' and `list' has not thereby offered `cancel'. An object
%% we cannot read at all is treated as declaring nothing.
task_op_declared(Tasks, Op) when is_map(Tasks) ->
    maps:is_key(Op, Tasks);
task_op_declared(_Tasks, _Op) ->
    false.

sub_capability(Caps, Family, Key) ->
    case maps:get(Family, Caps, undefined) of
        Sub when is_map(Sub) -> declared(maps:get(Key, Sub, false));
        _ -> false
    end.

%% A sub-capability is a boolean in the schema. Anything else a peer
%% puts there is not a declaration we can act on.
declared(true) -> true;
declared(_) -> false.

do_cancel(Id, #data{pending = Pending} = Data) ->
    case maps:take(Id, Pending) of
        {#pending{caller = From} = P, Rest} when From =/= init, From =/= ping ->
            gen_statem:reply(From, {error, cancelled}),
            signal_cancel(Id, <<"cancelled by client">>, Data),
            Data1 = settle_data(P, Data#data{pending = Rest}),
            {keep_state, Data1, [drop_req_timeout(Id)]};
        _ ->
            keep_state_and_data
    end.

%% "How a client signals cancellation depends on the transport"
%% (2026-07-28/basic/patterns/cancellation.mdx:38). Legacy runs the
%% other way: there a disconnect "SHOULD NOT be interpreted as the
%% client cancelling" (2025-11-25/basic/transports.mdx:128).
signal_cancel(Id, Reason, #data{era = modern, transport = Transport} = Data) when
    Transport =/= undefined
->
    case barrel_mcp_client_transport:cancel_request(Transport, Id) of
        ok -> ok;
        unsupported -> send_cancelled(Id, Reason, Data)
    end;
signal_cancel(Id, Reason, Data) ->
    send_cancelled(Id, Reason, Data).

send_cancelled(Id, Reason, Data) ->
    send_envelope(
        Data,
        barrel_mcp_protocol:encode_notification(
            <<"notifications/cancelled">>,
            #{<<"requestId">> => Id, <<"reason">> => Reason}
        )
    ),
    ok.

timeout_pending(Id, #data{pending = Pending} = Data) ->
    case maps:take(Id, Pending) of
        {#pending{caller = ping} = P, Rest} ->
            Data1 = settle_data(P, bump_ping_failures(Data#data{pending = Rest})),
            signal_cancel(Id, <<"timeout">>, Data1),
            maybe_close_on_ping_failures(Data1, Id);
        {#pending{caller = From} = P, Rest} when From =/= init ->
            gen_statem:reply(From, {error, timeout}),
            signal_cancel(Id, <<"timeout">>, Data),
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
        [] ->
            Data;
        L ->
            case lists:delete(Pid, L) of
                [] -> Data#data{subscriptions = maps:remove(Uri, Subs)};
                L1 -> Data#data{subscriptions = Subs#{Uri => L1}}
            end
    end.

%%====================================================================
%% Termination
%%====================================================================

terminate(
    Reason,
    _State,
    #data{handler_mod = Mod, handler_state = HS, transport = T}
) ->
    case T of
        {Tmod, Pid} ->
            try
                Tmod:close(Pid)
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end,
    _ = code:ensure_loaded(Mod),
    case erlang:function_exported(Mod, terminate, 2) of
        true ->
            try
                Mod:terminate(Reason, HS)
            catch
                _:_ -> ok
            end;
        false ->
            ok
    end,
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.
