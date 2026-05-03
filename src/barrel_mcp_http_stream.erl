%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc MCP Streamable HTTP Transport (Protocol Version 2025-03-26).
%%%
%%% Implements the MCP Streamable HTTP transport for Claude Code integration.
%%% This transport uses:
%%% - POST for client requests with JSON or SSE streaming responses
%%% - GET for server-to-client notification streams (SSE)
%%% - DELETE for session termination
%%% - OPTIONS for CORS preflight
%%%
%%% Accept header must include both application/json and text/event-stream.
%%% Session management via Mcp-Session-Id header.
%%%
%%% @reference <a href="https://spec.modelcontextprotocol.io/specification/basic/transports/">MCP Transport Specification</a>
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_stream).

-behaviour(cowboy_loop).

-include("barrel_mcp.hrl").

%% API
-export([
    start/1,
    stop/0
]).

%% Helpers re-used by the legacy `barrel_mcp_http' transport.
-export([
    is_loopback/1,
    resolve_allowed_origins/2,
    validate_origin/2
]).

%% Cowboy loop handler callbacks
-export([init/2, info/3, terminate/3]).

-define(STREAM_LISTENER, barrel_mcp_http_stream_listener).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the Streamable HTTP server.
%%
%% == Security defaults ==
%%
%% Since version 1.2 the server binds to `127.0.0.1' by default.
%% Public binds (any non-loopback IP) require an explicit
%% `allowed_origins' to prevent DNS-rebinding and CORS-style
%% attacks. The server validates the `Origin' header on every
%% request and rejects mismatches with HTTP 403.
%%
%% == Options ==
%%
%% <ul>
%%   <li>`port' — TCP port (default 9090).</li>
%%   <li>`ip' — bind address (default `{127,0,0,1}').</li>
%%   <li>`auth' — authentication provider config.</li>
%%   <li>`session_enabled' — `true' (default) to use
%%       `Mcp-Session-Id' sessions.</li>
%%   <li>`ssl' — TLS options (`certfile', `keyfile',
%%       optional `cacertfile').</li>
%%   <li>`allowed_origins' — `[binary()] | any'. List of allowed
%%       Origin values (case-sensitive scheme/host/port match) or
%%       the atom `any' to disable validation. Required for
%%       non-loopback binds. Defaults to a loopback allow-list when
%%       bound to `127.0.0.1' / `::1'.</li>
%%   <li>`allow_missing_origin' — `true' to accept requests with
%%       no `Origin' header (typical of non-browser clients).
%%       Defaults to `true' on loopback, `false' otherwise.</li>
%% </ul>
-spec start(Opts) -> {ok, pid()} | {error, term()} when
    Opts :: #{
        port => pos_integer(),
        ip => inet:ip_address(),
        auth => map(),
        session_enabled => boolean(),
        ssl => map(),
        allowed_origins => [binary()] | any,
        allow_missing_origin => boolean()
    }.
start(Opts) ->
    Port = maps:get(port, Opts, 9090),
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    SessionEnabled = maps:get(session_enabled, Opts, true),

    Loopback = is_loopback(Ip),
    case resolve_allowed_origins(Loopback,
                                 maps:get(allowed_origins, Opts, undefined)) of
        {error, _} = Err ->
            Err;
        {ok, AllowedOrigins} ->
            AllowMissing = maps:get(allow_missing_origin, Opts, Loopback),

            %% Ensure session manager is started if sessions are enabled
            _ = case SessionEnabled of
                true -> ensure_session_manager();
                false -> ok
            end,

            AuthConfig = init_auth(maps:get(auth, Opts, #{})),

            HandlerState = #{
                auth_config => AuthConfig,
                session_enabled => SessionEnabled,
                allowed_origins => AllowedOrigins,
                allow_missing_origin => AllowMissing,
                sse_buffer_size => maps:get(sse_buffer_size, Opts, 256)
            },

            Routes = [
                {'_', [
                    {"/mcp", ?MODULE, HandlerState},
                    {"/", ?MODULE, HandlerState}
                ]}
            ],
            Dispatch = cowboy_router:compile(Routes),

            case maps:get(ssl, Opts, undefined) of
                #{certfile := Cert, keyfile := Key} = SslOpts ->
                    CaCert = maps:get(cacertfile, SslOpts, undefined),
                    TlsOpts = [
                        {port, Port},
                        {ip, Ip},
                        {certfile, Cert},
                        {keyfile, Key}
                    ] ++ case CaCert of
                        undefined -> [];
                        _ -> [{cacertfile, CaCert}]
                    end,
                    cowboy:start_tls(?STREAM_LISTENER, TlsOpts, #{
                        env => #{dispatch => Dispatch},
                        idle_timeout => infinity
                    });
                _ ->
                    cowboy:start_clear(?STREAM_LISTENER, [
                        {port, Port},
                        {ip, Ip}
                    ], #{
                        env => #{dispatch => Dispatch},
                        idle_timeout => infinity
                    })
            end
    end.

%% @doc Stop the Streamable HTTP server.
-spec stop() -> ok | {error, not_found}.
stop() ->
    cowboy:stop_listener(?STREAM_LISTENER).

%%====================================================================
%% Cowboy Loop Handler Callbacks
%%====================================================================

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case validate_origin(Req0, State) of
        ok ->
            dispatch_method(Method, Req0, State);
        {error, _Reason} ->
            %% Respond 403 with no body. We deliberately omit
            %% Access-Control-Allow-Origin so the browser surfaces
            %% the rejection rather than retrying.
            Req = cowboy_req:reply(403, #{}, <<>>, Req0),
            {ok, Req, State}
    end.

dispatch_method(<<"POST">>, Req0, State)    -> handle_post(Req0, State);
dispatch_method(<<"GET">>, Req0, State)     -> handle_get_sse(Req0, State);
dispatch_method(<<"DELETE">>, Req0, State)  -> handle_delete(Req0, State);
dispatch_method(<<"OPTIONS">>, Req0, State) -> handle_options(Req0, State);
dispatch_method(_, Req0, State) ->
    Req = cowboy_req:reply(405, cors_response_headers(Req0, State, #{
        <<"content-type">> => <<"application/json">>,
        <<"allow">> => <<"POST, GET, DELETE, OPTIONS">>
    }), <<"{\"error\":\"Method not allowed\"}">>, Req0),
    {ok, Req, State}.

info(session_terminated, Req, State) ->
    %% Session was terminated, close the SSE stream
    {stop, Req, State};

info({sse_event, EventId, Data}, Req, State) ->
    send_sse_event(Req, EventId, Data),
    record_event(State, EventId, Data),
    {ok, Req, State};

info({sse_send_message, Message}, Req, State) ->
    EventId = generate_event_id(),
    send_sse_event(Req, EventId, Message),
    record_event(State, EventId, Message),
    {ok, Req, State};

info(_Info, Req, State) ->
    {ok, Req, State}.

terminate(_Reason, _Req, State) ->
    case maps:find(sse_session, State) of
        {ok, SessionId} when is_binary(SessionId) ->
            catch barrel_mcp_session:set_sse_pid(SessionId, undefined);
        _ -> ok
    end,
    ok.

%%====================================================================
%% HTTP Method Handlers
%%====================================================================

handle_post(Req0, State) ->
    %% Validate Accept header
    case validate_accept_header(Req0) of
        {error, Reason} ->
            Req = cowboy_req:reply(406, cors_response_headers(Req0, State, #{}),
                json_encode(#{<<"error">> => Reason}), Req0),
            {ok, Req, State};
        ok ->
            %% Authenticate
            AuthConfig = maps:get(auth_config, State, #{provider => barrel_mcp_auth_none}),
            Headers = extract_headers(Req0, AuthConfig),
            AuthRequest = #{headers => Headers},

            case authenticate(AuthConfig, AuthRequest) of
                {ok, AuthInfo} ->
                    handle_post_authenticated(Req0, State#{auth_info => AuthInfo});
                {error, Reason} ->
                    handle_auth_error(Req0, State, AuthConfig, Reason)
            end
    end.

handle_post_authenticated(Req0, State) ->
    SessionEnabled = maps:get(session_enabled, State, true),
    %% Read body first; we need to inspect the method to know whether
    %% we may create a session (`initialize') or must look one up.
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case barrel_mcp_protocol:decode(Body) of
        {ok, Request} when is_list(Request) ->
            %% Batches are not supported.
            reply_jsonrpc_error(Req1, State, undefined, 400, null,
                                ?JSONRPC_INVALID_REQUEST,
                                <<"Batch requests are not supported">>);
        {ok, Request} when is_map(Request) ->
            handle_post_request(Req1, State, SessionEnabled, Request);
        {error, parse_error} ->
            reply_jsonrpc_error(Req1, State, undefined, 400, null,
                                -32700, <<"Parse error">>)
    end.

handle_post_request(Req0, State, SessionEnabled, Request) ->
    %% Distinguish a JSON-RPC RESPONSE (carries result/error + id)
    %% from a regular request/notification.
    case is_jsonrpc_response(Request) of
        true ->
            handle_inbound_response(Req0, State, SessionEnabled, Request);
        false ->
            handle_inbound_request(Req0, State, SessionEnabled, Request)
    end.

is_jsonrpc_response(R) ->
    is_map_key(<<"id">>, R) andalso
        (is_map_key(<<"result">>, R) orelse is_map_key(<<"error">>, R)) andalso
        not is_map_key(<<"method">>, R).

handle_inbound_response(Req0, State, _SessionEnabled,
                        #{<<"id">> := RespId} = Request) ->
    _ = barrel_mcp_session:deliver_response(RespId, Request),
    %% Per Streamable HTTP, accepted server-bound responses return 202.
    Req = cowboy_req:reply(202, cors_response_headers(Req0, State, #{}),
                           <<>>, Req0),
    {ok, Req, State}.

handle_inbound_request(Req0, State, SessionEnabled, Request) ->
    Method = maps:get(<<"method">>, Request, undefined),
    case lookup_session_for_request(Req0, State, SessionEnabled, Method) of
        {ok, SessionId, State1} ->
            handle_dispatch(Req0, State1, SessionId, Request);
        {error, missing_session_id} ->
            reply_jsonrpc_error(Req0, State, undefined, 400, null,
                                ?JSONRPC_INVALID_REQUEST,
                                <<"Mcp-Session-Id header required">>);
        {error, unknown_session} ->
            reply_jsonrpc_error(Req0, State, undefined, 404, null,
                                ?JSONRPC_INVALID_REQUEST,
                                <<"Unknown Mcp-Session-Id">>)
    end.

handle_dispatch(Req0, State, SessionId, Request) ->
    %% Update session activity if we have a session.
    _ = case SessionId of
            undefined -> ok;
            _ -> barrel_mcp_session:update_activity(SessionId)
        end,

    Method = maps:get(<<"method">>, Request, undefined),

    case validate_protocol_version(Req0, State, SessionId, Method) of
        {error, ProtoErr} ->
            reply_jsonrpc_error(Req0, State, SessionId, 400, null,
                                ?JSONRPC_INVALID_REQUEST, ProtoErr);
        ok ->
            AuthInfo = maps:get(auth_info, State, undefined),
            ProtocolState0 = case SessionId of
                                 undefined -> #{};
                                 _ -> #{session_id => SessionId}
                             end,
            ProtocolState = case AuthInfo of
                                undefined -> ProtocolState0;
                                _ -> ProtocolState0#{auth_info => AuthInfo}
                            end,
            RequestWithAuth = case AuthInfo of
                                  undefined -> Request;
                                  _ -> Request#{<<"_auth">> => AuthInfo}
                              end,
            case barrel_mcp_protocol:handle(RequestWithAuth, ProtocolState) of
                no_response ->
                    Headers = add_session_header(
                                cors_response_headers(Req0, State, #{}),
                                SessionId),
                    Req = cowboy_req:reply(202, Headers, <<>>, Req0),
                    {ok, Req, State};
                {async, AsyncPlan} ->
                    handle_async_tool_call(Req0, State, SessionId,
                                            Method, RequestWithAuth, AsyncPlan);
                Result ->
                    State1 = maybe_capture_initialize_version(
                                State, SessionId, Method, Result),
                    case wants_sse_response(Req0) of
                        true ->
                            stream_sse_response(Req0, State1, SessionId, Result);
                        false ->
                            ResponseJson = barrel_mcp_protocol:encode(Result),
                            Headers = add_session_header(
                                        cors_response_headers(Req0, State1, #{
                                            <<"content-type">> =>
                                                <<"application/json">>
                                        }),
                                        SessionId),
                            Req = cowboy_req:reply(200, Headers, ResponseJson, Req0),
                            {ok, Req, State1}
                    end
            end
    end.

%% Drive an async tool call: build Ctx, spawn the worker, record the
%% in-flight entry, wait for the result or cancellation.
%%
%% When the tool is registered with `long_running => true', return
%% immediately with a `taskId' and let the worker continue in the
%% background; clients track progress via `tasks/get'.
handle_async_tool_call(Req0, State, SessionId, _Method,
                        RequestWithAuth, AsyncPlan) ->
    RequestId = maps:get(request_id, AsyncPlan),
    Spawn = maps:get(spawn, AsyncPlan),
    Timeout = maps:get(timeout, AsyncPlan, 60000),
    Params = maps:get(<<"params">>, RequestWithAuth, #{}),
    ToolName = maps:get(<<"name">>, Params, <<>>),
    LongRunning = is_long_running_tool(ToolName),
    ProgressToken = case Params of
                        #{<<"_meta">> := #{<<"progressToken">> := T}} -> T;
                        _ -> undefined
                    end,
    Self = self(),
    case LongRunning of
        true ->
            handle_long_running_call(Req0, State, SessionId, RequestId,
                                      ToolName, ProgressToken, Spawn);
        false ->
            Ctx = #{
                session_id => SessionId,
                request_id => RequestId,
                progress_token => ProgressToken,
                emit_progress => emit_progress_fun(SessionId, ProgressToken),
                reply_to => Self
            },
            WorkerPid = Spawn(Ctx),
            case SessionId of
                undefined -> ok;
                _ -> ok = barrel_mcp_session:record_in_flight(
                            SessionId, RequestId, WorkerPid, Self)
            end,
            Outcome = wait_for_tool(RequestId, Timeout),
            case SessionId of
                undefined -> ok;
                _ -> ok = barrel_mcp_session:clear_in_flight(SessionId, RequestId)
            end,
            deliver_tool_outcome(Req0, State, SessionId, RequestId, Outcome)
    end.

is_long_running_tool(Name) ->
    case barrel_mcp_registry:find(tool, Name) of
        {ok, Handler} -> maps:get(long_running, Handler, false);
        error -> false
    end.

%% Long-running tool: create a task, spawn the worker bound to a
%% private collector that updates the task store, return the taskId
%% to the caller right away.
handle_long_running_call(Req0, State, SessionId, RequestId, ToolName,
                          ProgressToken, Spawn) ->
    {ok, TaskId} = barrel_mcp_tasks:create(SessionId, ToolName, #{}),
    Collector = spawn_task_collector(SessionId, TaskId),
    Ctx = #{
        session_id => SessionId,
        request_id => RequestId,
        progress_token => ProgressToken,
        emit_progress => emit_progress_fun(SessionId, ProgressToken),
        reply_to => Collector
    },
    _Worker = Spawn(Ctx),
    Result = #{<<"taskId">> => TaskId,
               <<"status">> => <<"running">>},
    send_tool_envelope(Req0, State, SessionId, RequestId, Result).

%% Tiny worker that funnels tool outcomes into the task registry.
spawn_task_collector(SessionId, TaskId) ->
    spawn(fun() -> task_collector_loop(SessionId, TaskId) end).

task_collector_loop(SessionId, TaskId) ->
    receive
        {tool_result, _ReqId, Result} ->
            barrel_mcp_tasks:finish(SessionId, TaskId, Result);
        {tool_structured, _ReqId, Data, _Content} ->
            barrel_mcp_tasks:finish(SessionId, TaskId, Data);
        {tool_error, _ReqId, Content} ->
            barrel_mcp_tasks:fail(SessionId, TaskId, {tool_error, Content});
        {tool_failed, _ReqId, Reason} ->
            barrel_mcp_tasks:fail(SessionId, TaskId, Reason);
        {tool_validation_failed, _ReqId, Errors} ->
            barrel_mcp_tasks:fail(SessionId, TaskId, {validation_failed, Errors});
        {cancelled, _ReqId} ->
            barrel_mcp_tasks:cancel(SessionId, TaskId);
        _Other ->
            task_collector_loop(SessionId, TaskId)
    end.

emit_progress_fun(undefined, _Token) ->
    fun(_, _, _) -> ok end;
emit_progress_fun(_Sid, undefined) ->
    fun(_, _, _) -> ok end;
emit_progress_fun(SessionId, Token) ->
    fun(Progress, Total, _Message) ->
        barrel_mcp_session:notify_progress(SessionId, Token, Progress, Total)
    end.

wait_for_tool(RequestId, Timeout) ->
    receive
        {tool_result, RequestId, Result} -> {result, Result};
        {tool_structured, RequestId, Data, Content} ->
            {structured, Data, Content};
        {tool_error, RequestId, Content} -> {tool_error, Content};
        {tool_failed, RequestId, Reason} -> {failed, Reason};
        {tool_validation_failed, RequestId, Errors} ->
            {validation_failed, Errors};
        {cancelled, RequestId} -> cancelled
    after Timeout ->
        timeout
    end.

deliver_tool_outcome(Req0, State, SessionId, _RequestId, cancelled) ->
    %% Per the MCP cancellation guidance the receiver SHOULD NOT
    %% send a JSON-RPC response for a cancelled request. We close
    %% the HTTP request with a 200 + empty body so the connection
    %% wraps cleanly without a JSON envelope.
    Headers = add_session_header(
                cors_response_headers(Req0, State, #{}), SessionId),
    Req = cowboy_req:reply(200, Headers, <<>>, Req0),
    {ok, Req, State};
deliver_tool_outcome(Req0, State, SessionId, RequestId, {result, Result}) ->
    Content = barrel_mcp_protocol:format_tool_result_external(Result),
    send_tool_envelope(Req0, State, SessionId, RequestId,
                       #{<<"content">> => Content});
deliver_tool_outcome(Req0, State, SessionId, RequestId,
                      {structured, Data, Content}) ->
    send_tool_envelope(Req0, State, SessionId, RequestId,
                       #{<<"content">> => Content,
                         <<"structuredContent">> => Data});
deliver_tool_outcome(Req0, State, SessionId, RequestId,
                      {tool_error, Content}) ->
    send_tool_envelope(Req0, State, SessionId, RequestId,
                       #{<<"content">> => Content,
                         <<"isError">> => true});
deliver_tool_outcome(Req0, State, SessionId, RequestId,
                      {validation_failed, Errors}) ->
    Msg = iolist_to_binary(io_lib:format("Invalid tool input: ~p", [Errors])),
    send_tool_envelope(Req0, State, SessionId, RequestId,
                       #{<<"content">> =>
                            [#{<<"type">> => <<"text">>, <<"text">> => Msg}],
                         <<"isError">> => true});
deliver_tool_outcome(Req0, State, SessionId, RequestId, {failed, Reason}) ->
    send_jsonrpc_error_envelope(Req0, State, SessionId, RequestId,
                                ?MCP_TOOL_ERROR,
                                iolist_to_binary(io_lib:format("~p", [Reason])));
deliver_tool_outcome(Req0, State, SessionId, RequestId, timeout) ->
    send_jsonrpc_error_envelope(Req0, State, SessionId, RequestId,
                                ?MCP_TOOL_ERROR, <<"Tool timed out">>).

send_tool_envelope(Req0, State, SessionId, RequestId, Result) ->
    Resp = #{<<"jsonrpc">> => <<"2.0">>,
             <<"id">> => RequestId,
             <<"result">> => Result},
    Json = barrel_mcp_protocol:encode(Resp),
    Headers = add_session_header(
                cors_response_headers(Req0, State, #{
                    <<"content-type">> => <<"application/json">>}),
                SessionId),
    Req = cowboy_req:reply(200, Headers, Json, Req0),
    {ok, Req, State}.

send_jsonrpc_error_envelope(Req0, State, SessionId, Id, Code, Message) ->
    Resp = barrel_mcp_protocol:error_response(Id, Code, Message),
    Json = barrel_mcp_protocol:encode(Resp),
    Headers = add_session_header(
                cors_response_headers(Req0, State, #{
                    <<"content-type">> => <<"application/json">>}),
                SessionId),
    Req = cowboy_req:reply(200, Headers, Json, Req0),
    {ok, Req, State}.

reply_jsonrpc_error(Req0, State, SessionId, Status, Id, Code, Message) ->
    ErrorResponse = barrel_mcp_protocol:error_response(Id, Code, Message),
    ResponseJson = barrel_mcp_protocol:encode(ErrorResponse),
    Headers = add_session_header(
                cors_response_headers(Req0, State, #{
                    <<"content-type">> => <<"application/json">>
                }), SessionId),
    Req = cowboy_req:reply(Status, Headers, ResponseJson, Req0),
    {ok, Req, State}.

%% Look up (or, for `initialize', create) the session for the
%% request. Returns:
%%   {ok, SessionId | undefined, NewState}
%%   {error, missing_session_id} — no header, header was required
%%   {error, unknown_session}   — header present but id not registered
lookup_session_for_request(_Req, State, false, _Method) ->
    {ok, undefined, State};
lookup_session_for_request(Req, State, true, Method) ->
    Header = get_session_from_request(Req),
    case {Method, Header} of
        {<<"initialize">>, undefined} ->
            {ok, SessionId} = barrel_mcp_session:create(#{}),
            BufMax = maps:get(sse_buffer_size, State, 256),
            _ = barrel_mcp_session:set_sse_buffer_max(SessionId, BufMax),
            {ok, SessionId, State#{session_id => SessionId}};
        {<<"initialize">>, SessionId} ->
            case barrel_mcp_session:get(SessionId) of
                {ok, _} -> {ok, SessionId, State#{session_id => SessionId}};
                {error, not_found} ->
                    {ok, NewSid} = barrel_mcp_session:create(#{}),
                    {ok, NewSid, State#{session_id => NewSid}}
            end;
        {_, undefined} ->
            {error, missing_session_id};
        {_, SessionId} ->
            case barrel_mcp_session:get(SessionId) of
                {ok, _} -> {ok, SessionId, State#{session_id => SessionId}};
                {error, not_found} -> {error, unknown_session}
            end
    end.

%% Validate the `MCP-Protocol-Version' header per the spec:
%% - On initialize, the header is optional (the body carries the
%%   version).
%% - For subsequent requests:
%%   * present + supported → ok
%%   * present + unsupported → error (400 with supported list)
%%   * missing → fall back to the session-stored negotiated
%%     version; if none, assume <<"2025-03-26">>.
validate_protocol_version(_Req, _State, _Sid, <<"initialize">>) -> ok;
validate_protocol_version(Req, _State, SessionId, _Method) ->
    case cowboy_req:header(<<"mcp-protocol-version">>, Req) of
        undefined ->
            %% Session-stored value or default fallback. Either way: ok.
            ok;
        Version ->
            case lists:member(Version, ?MCP_SUPPORTED_VERSIONS) of
                true ->
                    case SessionId of
                        undefined -> ok;
                        _ ->
                            _ = barrel_mcp_session:set_protocol_version(
                                  SessionId, Version),
                            ok
                    end;
                false ->
                    {error, iolist_to_binary([
                        <<"Bad MCP-Protocol-Version: ">>, Version,
                        <<". Supported: ">>,
                        lists:join(<<", ">>, ?MCP_SUPPORTED_VERSIONS)
                    ])}
            end
    end.

%% After a successful initialize, store the negotiated
%% `protocolVersion' on the session so later requests can fall back
%% to it when the header is missing.
maybe_capture_initialize_version(State, SessionId, <<"initialize">>,
                                 #{<<"result">> := #{<<"protocolVersion">> :=
                                                      Version}})
  when is_binary(SessionId) ->
    _ = barrel_mcp_session:set_protocol_version(SessionId, Version),
    State;
maybe_capture_initialize_version(State, _, _, _) -> State.

handle_get_sse(Req0, State) ->
    SessionEnabled = maps:get(session_enabled, State, true),
    case SessionEnabled of
        false ->
            Req = cowboy_req:reply(400, cors_response_headers(Req0, State, #{}),
                json_encode(#{<<"error">> => <<"Sessions not enabled">>}), Req0),
            {ok, Req, State};
        true ->
            case get_session_from_request(Req0) of
                undefined ->
                    Req = cowboy_req:reply(400, cors_response_headers(Req0, State, #{}),
                        json_encode(#{<<"error">> => <<"Mcp-Session-Id header required">>}), Req0),
                    {ok, Req, State};
                SessionId ->
                    case barrel_mcp_session:get(SessionId) of
                        {ok, _Session} ->
                            ResponseHeaders = add_session_header(
                                cors_response_headers(Req0, State, #{
                                    <<"content-type">> => <<"text/event-stream">>,
                                    <<"cache-control">> => <<"no-cache">>,
                                    <<"connection">> => <<"keep-alive">>
                                }), SessionId),
                            Req = cowboy_req:stream_reply(200, ResponseHeaders, Req0),
                            ok = replay_sse_events(Req, SessionId,
                                cowboy_req:header(<<"last-event-id">>, Req0)),
                            _ = barrel_mcp_session:set_sse_pid(SessionId, self()),
                            {cowboy_loop, Req, State#{sse_session => SessionId}};
                        {error, not_found} ->
                            Req = cowboy_req:reply(404,
                                cors_response_headers(Req0, State, #{}),
                                json_encode(#{<<"error">> => <<"Unknown Mcp-Session-Id">>}),
                                Req0),
                            {ok, Req, State}
                    end
            end
    end.

handle_delete(Req0, State) ->
    case get_session_from_request(Req0) of
        undefined ->
            Req = cowboy_req:reply(400,
                cors_response_headers(Req0, State, #{}),
                json_encode(#{<<"error">> => <<"Mcp-Session-Id header required">>}),
                Req0),
            {ok, Req, State};
        SessionId ->
            case barrel_mcp_session:get(SessionId) of
                {ok, _} ->
                    barrel_mcp_session:delete(SessionId),
                    Req = cowboy_req:reply(204,
                        cors_response_headers(Req0, State, #{}),
                        <<>>, Req0),
                    {ok, Req, State};
                {error, not_found} ->
                    Req = cowboy_req:reply(404,
                        cors_response_headers(Req0, State, #{}),
                        json_encode(#{<<"error">> => <<"Unknown Mcp-Session-Id">>}),
                        Req0),
                    {ok, Req, State}
            end
    end.

handle_options(Req0, State) ->
    Req = cowboy_req:reply(204, cors_response_headers(Req0, State, #{}),
                           <<>>, Req0),
    {ok, Req, State}.

%%====================================================================
%% SSE Helpers
%%====================================================================

stream_sse_response(Req0, State, SessionId, Result) ->
    ResponseHeaders = add_session_header(
        cors_response_headers(Req0, State, #{
            <<"content-type">> => <<"text/event-stream">>,
            <<"cache-control">> => <<"no-cache">>
        }), SessionId),
    Req = cowboy_req:stream_reply(200, ResponseHeaders, Req0),

    %% Send the response as an SSE event
    EventId = generate_event_id(),
    send_sse_event(Req, EventId, Result),

    %% Close the stream
    cowboy_req:stream_body(<<>>, fin, Req),
    {ok, Req, State}.

send_sse_event(Req, EventId, Data) ->
    Json = json_encode(Data),
    EventData = iolist_to_binary([
        <<"id: ">>, EventId, <<"\n">>,
        <<"data: ">>, Json, <<"\n\n">>
    ]),
    cowboy_req:stream_body(EventData, nofin, Req).

generate_event_id() ->
    integer_to_binary(erlang:system_time(microsecond)).

%% Buffer the SSE event on the owning session so a later GET with
%% `Last-Event-Id' can replay it.
record_event(State, EventId, Payload) ->
    case maps:get(sse_session, State, undefined) of
        undefined -> ok;
        SessionId ->
            _ = barrel_mcp_session:record_sse_event(SessionId, EventId, Payload),
            ok
    end.

%% Replay SSE events newer than `LastId' on a freshly opened GET
%% stream. When the buffered window has rolled past `LastId', emit a
%% synthetic `notifications/replay_truncated' event so the client
%% knows to resync.
replay_sse_events(_Req, _SessionId, undefined) ->
    ok;
replay_sse_events(Req, SessionId, LastId) ->
    case barrel_mcp_session:events_since(SessionId, LastId) of
        {ok, Events} ->
            lists:foreach(fun({EventId, Payload}) ->
                send_sse_event(Req, EventId, Payload)
            end, Events),
            ok;
        truncated ->
            send_sse_event(Req, generate_event_id(), #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"method">> => <<"notifications/replay_truncated">>,
                <<"params">> => #{}
            }),
            ok;
        {error, not_found} -> ok
    end.

%%====================================================================
%% Session Helpers
%%====================================================================

get_session_from_request(Req) ->
    cowboy_req:header(<<"mcp-session-id">>, Req, undefined).

add_session_header(Headers, undefined) ->
    Headers;
add_session_header(Headers, SessionId) ->
    Headers#{<<"mcp-session-id">> => SessionId}.

%%====================================================================
%% Validation Helpers
%%====================================================================

validate_accept_header(Req) ->
    Accept = cowboy_req:header(<<"accept">>, Req, <<"*/*">>),
    %% Accept header should include application/json and/or text/event-stream
    %% or be */* (accept anything)
    case Accept of
        <<"*/*">> ->
            ok;
        _ ->
            HasJson = binary:match(Accept, <<"application/json">>) =/= nomatch,
            HasSse = binary:match(Accept, <<"text/event-stream">>) =/= nomatch,
            HasWildcard = binary:match(Accept, <<"*/*">>) =/= nomatch,
            %% Allow any of: wildcard, JSON, or SSE
            case HasWildcard orelse HasJson orelse HasSse of
                true -> ok;
                false -> {error, <<"Accept header must include application/json or text/event-stream">>}
            end
    end.

wants_sse_response(Req) ->
    Accept = cowboy_req:header(<<"accept">>, Req, <<>>),
    %% Check if SSE is PREFERRED over JSON
    %% Return true only if:
    %% 1. Accept is ONLY text/event-stream (no application/json)
    %% 2. Or SSE comes before JSON in the Accept header
    HasJson = binary:match(Accept, <<"application/json">>) =/= nomatch,
    HasSse = binary:match(Accept, <<"text/event-stream">>) =/= nomatch,
    case {HasJson, HasSse} of
        {false, true} ->
            %% Only SSE accepted, use SSE
            true;
        {true, true} ->
            %% Both accepted, check order (SSE first = prefer SSE)
            SsePos = case binary:match(Accept, <<"text/event-stream">>) of
                nomatch -> infinity;
                {P, _} -> P
            end,
            JsonPos = case binary:match(Accept, <<"application/json">>) of
                nomatch -> infinity;
                {P2, _} -> P2
            end,
            SsePos < JsonPos;
        _ ->
            %% JSON only or neither, use JSON
            false
    end.

%%====================================================================
%% Authentication
%%====================================================================

init_auth(#{provider := Provider} = AuthOpts) ->
    ProviderOpts = maps:get(provider_opts, AuthOpts, #{}),
    ProviderState = case erlang:function_exported(Provider, init, 1) of
        true ->
            case Provider:init(ProviderOpts) of
                {ok, S} -> S;
                _ -> undefined
            end;
        false ->
            undefined
    end,
    AuthOpts#{provider_state => ProviderState};
init_auth(AuthOpts) ->
    init_auth(AuthOpts#{provider => barrel_mcp_auth_none}).

authenticate(#{provider := barrel_mcp_auth_none}, _Request) ->
    barrel_mcp_auth_none:authenticate(#{}, undefined);
authenticate(AuthConfig, Request) ->
    barrel_mcp_auth:authenticate(AuthConfig, Request, AuthConfig).

handle_auth_error(Req0, State, AuthConfig, Reason) ->
    {StatusCode, AuthHeaders, Body} = barrel_mcp_auth:challenge_response(AuthConfig, Reason),
    Headers = maps:merge(AuthHeaders, cors_response_headers(Req0, State, #{})),
    Req = cowboy_req:reply(StatusCode, Headers, Body, Req0),
    {ok, Req, State}.

extract_headers(Req, AuthConfig) ->
    Names = case AuthConfig of
                undefined -> [<<"authorization">>, <<"x-api-key">>];
                _ ->
                    Decl = barrel_mcp_auth:auth_headers(AuthConfig),
                    case Decl of
                        [] -> [<<"authorization">>, <<"x-api-key">>];
                        _ -> Decl
                    end
            end,
    lists:foldl(fun(Name, Acc) ->
        case cowboy_req:header(Name, Req) of
            undefined -> Acc;
            Value -> Acc#{Name => Value}
        end
    end, #{}, Names).

%%====================================================================
%% CORS
%%====================================================================

%% Build the CORS headers for the current request. Echoes the
%% validated `Origin' (no wildcard); omits `Access-Control-Allow-Origin'
%% when the request had no Origin header. The allowed-headers list is
%% derived from the configured auth provider so custom headers
%% (e.g. `X-API-Key', a custom `header_name') are honoured.
-spec cors_response_headers(cowboy_req:req(), map(), map()) -> map().
cors_response_headers(Req, State, Extra) ->
    BaseAllowHeaders = [<<"content-type">>, <<"accept">>,
                        <<"mcp-session-id">>, <<"mcp-protocol-version">>,
                        <<"last-event-id">>],
    AuthHeaders = case maps:get(auth_config, State, undefined) of
                      undefined -> [];
                      AC -> barrel_mcp_auth:auth_headers(AC)
                  end,
    AllowHeaders = lists:join(<<", ">>, BaseAllowHeaders ++ AuthHeaders),
    ExposeHeaders = <<"www-authenticate, mcp-session-id, mcp-protocol-version">>,
    Base = #{
        <<"access-control-allow-methods">> => <<"POST, GET, DELETE, OPTIONS">>,
        <<"access-control-allow-headers">> => iolist_to_binary(AllowHeaders),
        <<"access-control-expose-headers">> => ExposeHeaders
    },
    WithOrigin = case cowboy_req:header(<<"origin">>, Req) of
                     undefined -> Base;
                     Origin ->
                         Base#{<<"access-control-allow-origin">> => Origin,
                               <<"vary">> => <<"Origin">>}
                 end,
    maps:merge(WithOrigin, Extra).

%%====================================================================
%% Origin validation + bind helpers
%%====================================================================

%% Resolve the operator's `allowed_origins' input into the structural
%% form used at request time. On loopback we provide a sensible
%% default; on public binds the operator must opt in.
resolve_allowed_origins(_Loopback, any) ->
    {ok, any};
resolve_allowed_origins(true, undefined) ->
    {ok, default_loopback_origins()};
resolve_allowed_origins(false, undefined) ->
    {error, allowed_origins_required};
resolve_allowed_origins(_Loopback, List) when is_list(List) ->
    {ok, [parse_origin(O) || O <- List]}.

default_loopback_origins() ->
    [#{scheme => <<"http">>, host => <<"localhost">>, port => any},
     #{scheme => <<"http">>, host => <<"127.0.0.1">>, port => any},
     #{scheme => <<"http">>, host => <<"[::1]">>, port => any}].

%% `<<"null">>' is special: browsers send it from sandboxed contexts.
%% Encode it explicitly.
parse_origin(<<"null">>) ->
    null;
parse_origin(Bin) when is_binary(Bin) ->
    case uri_string:parse(Bin) of
        #{scheme := Scheme, host := Host} = U ->
            #{scheme => to_bin(Scheme),
              host => to_bin(Host),
              port => maps:get(port, U, any)};
        _ ->
            #{scheme => undefined, host => Bin, port => any}
    end.

is_loopback({127, _, _, _}) -> true;
is_loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback("localhost") -> true;
is_loopback(<<"localhost">>) -> true;
is_loopback(_) -> false.

%% Validate the request's `Origin' against the configured allow-list.
%% Returns `ok' on accept, `{error, Reason}' on reject.
-spec validate_origin(cowboy_req:req(), map()) ->
    ok | {error, atom()}.
validate_origin(Req, State) ->
    Allowed = maps:get(allowed_origins, State, any),
    AllowMissing = maps:get(allow_missing_origin, State, true),
    case cowboy_req:header(<<"origin">>, Req) of
        undefined when AllowMissing -> ok;
        undefined -> {error, missing_origin};
        Origin -> match_origin(Origin, Allowed)
    end.

match_origin(_Origin, any) -> ok;
match_origin(<<"null">>, Allowed) ->
    case lists:member(null, Allowed) of
        true -> ok;
        false -> {error, origin_null_not_allowed}
    end;
match_origin(Origin, Allowed) ->
    Parsed = parse_origin(Origin),
    case lists:any(fun(A) -> origin_matches(A, Parsed) end, Allowed) of
        true -> ok;
        false -> {error, origin_not_allowed}
    end.

origin_matches(null, _) -> false;
origin_matches(#{scheme := S, host := H, port := P}, Parsed) ->
    SOk = (S =:= undefined) orelse (S =:= maps:get(scheme, Parsed)),
    HOk = (H =:= maps:get(host, Parsed)),
    POk = (P =:= any) orelse (P =:= maps:get(port, Parsed)),
    SOk andalso HOk andalso POk;
origin_matches(_, _) -> false.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> iolist_to_binary(L).

%%====================================================================
%% Utilities
%%====================================================================

json_encode(Data) ->
    iolist_to_binary(json:encode(Data)).

ensure_session_manager() ->
    case whereis(barrel_mcp_session) of
        undefined ->
            %% Start session manager under barrel_mcp_sup if available
            case whereis(barrel_mcp_sup) of
                undefined ->
                    %% Start standalone
                    barrel_mcp_session:start_link();
                _ ->
                    %% Let supervisor handle it
                    ok
            end;
        _ ->
            ok
    end.
