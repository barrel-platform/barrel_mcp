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
    call_tool/3, call_tool/4,
    %% Resources
    list_resources/1, list_resources/2,
    list_resource_templates/1, list_resource_templates/2,
    read_resource/2,
    subscribe/2, unsubscribe/2,
    %% Prompts
    list_prompts/1, list_prompts/2,
    get_prompt/3,
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
      auth => none | {bearer, binary()} | {oauth, map()},
      protocol_version => binary(),
      request_timeout => pos_integer(),
      init_timeout => pos_integer()}.

-export_type([connect_spec/0]).

-define(DEFAULT_REQUEST_TIMEOUT, 30000).
-define(DEFAULT_INIT_TIMEOUT, 30000).

-record(pending, {
    caller :: init | {pid(), term()},
    method :: binary(),
    deadline :: integer() | infinity
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

%% @doc List tools on the server. Single page.
-spec list_tools(pid()) -> {ok, [map()]} | {error, term()}.
list_tools(Pid) ->
    list_tools(Pid, #{}).

-spec list_tools(pid(), map()) -> {ok, [map()], NextCursor :: binary() | undefined} |
                                  {ok, [map()]} | {error, term()}.
list_tools(Pid, Opts) ->
    paged(Pid, <<"tools/list">>, <<"tools">>, Opts).

%% @doc Call a tool. Args are forwarded as `arguments'.
-spec call_tool(pid(), binary(), map()) -> {ok, map()} | {error, term()}.
call_tool(Pid, Name, Args) ->
    call_tool(Pid, Name, Args, #{}).

-spec call_tool(pid(), binary(), map(), map()) -> {ok, map()} | {error, term()}.
call_tool(Pid, Name, Args, Opts) ->
    Params0 = #{<<"name">> => Name, <<"arguments">> => Args},
    Params = maybe_attach_progress_token(Params0, Opts),
    request(Pid, <<"tools/call">>, Params, request_timeout(Opts)).

-spec list_resources(pid()) -> {ok, [map()]} | {error, term()}.
list_resources(Pid) -> list_resources(Pid, #{}).

list_resources(Pid, Opts) ->
    paged(Pid, <<"resources/list">>, <<"resources">>, Opts).

list_resource_templates(Pid) -> list_resource_templates(Pid, #{}).

list_resource_templates(Pid, Opts) ->
    paged(Pid, <<"resources/templates/list">>, <<"resourceTemplates">>, Opts).

read_resource(Pid, Uri) ->
    request(Pid, <<"resources/read">>, #{<<"uri">> => Uri}).

subscribe(Pid, Uri) ->
    case request(Pid, <<"resources/subscribe">>, #{<<"uri">> => Uri}) of
        {ok, _} = Ok ->
            ok = gen_statem:cast(Pid, {add_subscriber, Uri, self()}),
            Ok;
        Err -> Err
    end.

unsubscribe(Pid, Uri) ->
    case request(Pid, <<"resources/unsubscribe">>, #{<<"uri">> => Uri}) of
        {ok, _} = Ok ->
            ok = gen_statem:cast(Pid, {remove_subscriber, Uri, self()}),
            Ok;
        Err -> Err
    end.

list_prompts(Pid) -> list_prompts(Pid, #{}).

list_prompts(Pid, Opts) ->
    paged(Pid, <<"prompts/list">>, <<"prompts">>, Opts).

get_prompt(Pid, Name, Args) ->
    request(Pid, <<"prompts/get">>, #{
        <<"name">> => Name,
        <<"arguments">> => Args
    }).

complete(Pid, Ref, Argument) ->
    request(Pid, <<"completion/complete">>, #{
        <<"ref">> => Ref,
        <<"argument">> => Argument
    }).

set_log_level(Pid, Level) when is_binary(Level) ->
    request(Pid, <<"logging/setLevel">>, #{<<"level">> => Level}).

ping(Pid) ->
    request(Pid, <<"ping">>, #{}).

%% @doc Cancel a previously-issued request by id. Sends
%% `notifications/cancelled' and removes the pending slot so the
%% caller receives `{error, cancelled}'.
cancel(Pid, RequestId) ->
    gen_statem:cast(Pid, {cancel, RequestId}).

%% @doc Deliver an asynchronous reply for a request that the handler
%% returned `{async, Tag, _}' for. Result may be a plain term (sent as
%% a JSON-RPC `result') or `{error, Code, Message}'.
reply_async(Pid, Tag, Result) ->
    gen_statem:cast(Pid, {async_reply, Tag, Result}).

server_info(Pid) ->
    gen_statem:call(Pid, server_info).

server_capabilities(Pid) ->
    gen_statem:call(Pid, server_capabilities).

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
            P = #pending{caller = From, method = Method,
                         deadline = deadline(Timeout)},
            Pending = (Data1#data.pending)#{Id => P},
            Actions = case Timeout of
                          infinity -> [];
                          T -> [{{timeout, {req, Id}}, T, request_timeout}]
                      end,
            {keep_state, Data1#data{pending = Pending}, Actions}
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
        {#pending{caller = From}, Rest} when From =/= init ->
            gen_statem:reply(From, {ok, Result}),
            {keep_state, Data#data{pending = Rest},
             [{{timeout, {req, Id}}, infinity, request_timeout}]};
        _ ->
            keep_state_and_data
    end.

handle_error_response(_Id, Code, Message, initializing, _Data) ->
    {stop, {init_failed, Code, Message}};
handle_error_response(Id, Code, Message, _State, Data) ->
    case maps:take(Id, Data#data.pending) of
        {#pending{caller = From}, Rest} when From =/= init ->
            gen_statem:reply(From, {error, {Code, Message}}),
            {keep_state, Data#data{pending = Rest},
             [{{timeout, {req, Id}}, infinity, request_timeout}]};
        _ ->
            keep_state_and_data
    end.

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
    {next_state, ready, Data1}.

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
is_supported(_, _) -> true.

do_cancel(Id, #data{pending = Pending} = Data) ->
    case maps:take(Id, Pending) of
        {#pending{caller = From}, Rest} when From =/= init ->
            gen_statem:reply(From, {error, cancelled}),
            send_envelope(Data, barrel_mcp_protocol:encode_notification(
                <<"notifications/cancelled">>,
                #{<<"requestId">> => Id, <<"reason">> => <<"cancelled by client">>})),
            {keep_state, Data#data{pending = Rest},
             [{{timeout, {req, Id}}, infinity, request_timeout}]};
        _ ->
            keep_state_and_data
    end.

timeout_pending(Id, #data{pending = Pending} = Data) ->
    case maps:take(Id, Pending) of
        {#pending{caller = From}, Rest} when From =/= init ->
            gen_statem:reply(From, {error, timeout}),
            send_envelope(Data, barrel_mcp_protocol:encode_notification(
                <<"notifications/cancelled">>,
                #{<<"requestId">> => Id, <<"reason">> => <<"timeout">>})),
            {keep_state, Data#data{pending = Rest}};
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
