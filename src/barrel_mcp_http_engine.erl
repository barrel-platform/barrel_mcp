%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Transport-neutral MCP HTTP engine.
%%%
%%% Holds the protocol logic for both the simple HTTP transport and
%%% the Streamable HTTP transport (POST/GET/DELETE/OPTIONS, SSE,
%%% sessions, CORS, Origin validation, authentication, the OAuth
%%% protected-resource-metadata endpoint and async tool calls)
%%% WITHOUT any dependency on a concrete HTTP server.
%%%
%%% A binding (the built-in `barrel_mcp_http_listener' h1/h2 server,
%%% or an external adapter such as Livery's) reads the request line
%%% and body, then calls {@link handle/6} with:
%%% <ul>
%%%   <li>`Method' — the request method binary (`<<"POST">>' …).</li>
%%%   <li>`Path' — the request target (query string allowed; it is
%%%       stripped here).</li>
%%%   <li>`Headers' — a `[{binary(), binary()}]' proplist.
%%%       Lookups are case-insensitive.</li>
%%%   <li>`Body' — the full request body (`<<>>' when none).</li>
%%%   <li>`Responder' — a map of I/O closures (see below).</li>
%%%   <li>`Config' — the engine configuration (see {@link config/0}).</li>
%%% </ul>
%%%
%%% The `Responder' abstracts response delivery so the engine never
%%% touches a socket:
%%% ```
%%% #{reply        => fun((Status, Headers, Body) -> ok),
%%%   stream_start => fun((Status, Headers) -> ok),
%%%   stream_chunk => fun((iodata()) -> ok | {error, term()}),
%%%   stream_end   => fun(() -> ok)}
%%% '''
%%% `Headers' passed to the closures is a `[{binary(), binary()}]'
%%% proplist (lowercase names). A streaming (SSE) response is
%%% `stream_start' then repeated `stream_chunk' then `stream_end'.
%%%
%%% `handle/6' runs in the calling (per-request) process. For a
%%% long-lived GET SSE stream it blocks in a receive loop until the
%%% session is terminated or the binding signals a client disconnect
%%% by sending the calling process the message `mcp_disconnect'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_engine).

-include("barrel_mcp.hrl").

-export([handle/6]).

%% Shared helpers reused by the transport start/1 functions.
-export([
    is_loopback/1,
    resolve_allowed_origins/2,
    normalize_resource_metadata/1,
    inject_resource_metadata_url/2,
    init_auth/1,
    ensure_session_manager/0
]).

-type responder() :: #{
    reply := fun((non_neg_integer(), [{binary(), binary()}], iodata()) -> ok),
    stream_start := fun((non_neg_integer(), [{binary(), binary()}]) -> ok),
    stream_chunk := fun((iodata()) -> ok | {error, term()}),
    stream_end := fun(() -> ok)
}.

-type config() :: #{
    mode := stream | simple,
    auth_config := map(),
    session_enabled => boolean(),
    allowed_origins => any | [term()],
    allow_missing_origin => boolean(),
    sse_buffer_size => pos_integer(),
    resource_metadata => undefined | map(),
    _ => _
}.

-export_type([responder/0, config/0]).

%% Cap incoming SSE response size mirrors the client-side cap.
-define(MAX_RESP_BYTES, 16 * 1024 * 1024).

%%====================================================================
%% Entry point
%%====================================================================

-spec handle(binary(), binary(), [{binary(), binary()}], binary(),
             responder(), config()) -> ok.
handle(Method, RawPath, Headers, Body, Responder, Config) ->
    Path = strip_query(RawPath),
    %% The protected-resource-metadata document is served before
    %% Origin validation, matching the old standalone handler.
    case {Path, maps:get(resource_metadata, Config, undefined)} of
        {<<"/.well-known/oauth-protected-resource">>, #{document := Doc}} ->
            serve_prm(Responder, Doc);
        _ ->
            case validate_origin(Headers, Config) of
                ok ->
                    dispatch(maps:get(mode, Config, stream),
                             Method, Headers, Body, Responder, Config);
                {error, _Reason} ->
                    %% 403 with no CORS header so the browser surfaces
                    %% the rejection rather than retrying.
                    reply(Responder, 403, #{}, <<>>)
            end
    end.

serve_prm(Responder, Doc) ->
    Body = iolist_to_binary(json:encode(Doc)),
    reply(Responder, 200,
          #{<<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"public, max-age=300">>},
          Body).

%%====================================================================
%% Method dispatch
%%====================================================================

%% --- Simple transport (POST/OPTIONS only, no sessions, no SSE) ---
dispatch(simple, <<"POST">>, Headers, Body, Responder, Config) ->
    simple_post(Headers, Body, Responder, Config);
dispatch(simple, <<"OPTIONS">>, Headers, _Body, Responder, Config) ->
    reply(Responder, 204, cors_headers(Headers, Config, #{}), <<>>);
dispatch(simple, _Method, Headers, _Body, Responder, Config) ->
    reply(Responder, 405,
          cors_headers(Headers, Config,
                       #{<<"content-type">> => <<"application/json">>,
                         <<"allow">> => <<"POST, OPTIONS">>}),
          <<"{\"error\":\"Method not allowed\"}">>);

%% --- Streamable transport ---
dispatch(stream, <<"POST">>, Headers, Body, Responder, Config) ->
    stream_post(Headers, Body, Responder, Config);
dispatch(stream, <<"GET">>, Headers, _Body, Responder, Config) ->
    stream_get_sse(Headers, Responder, Config);
dispatch(stream, <<"DELETE">>, Headers, _Body, Responder, Config) ->
    stream_delete(Headers, Responder, Config);
dispatch(stream, <<"OPTIONS">>, Headers, _Body, Responder, Config) ->
    reply(Responder, 204, cors_headers(Headers, Config, #{}), <<>>);
dispatch(stream, _Method, Headers, _Body, Responder, Config) ->
    reply(Responder, 405,
          cors_headers(Headers, Config,
                       #{<<"content-type">> => <<"application/json">>,
                         <<"allow">> => <<"POST, GET, DELETE, OPTIONS">>}),
          <<"{\"error\":\"Method not allowed\"}">>).

%%====================================================================
%% Simple transport
%%====================================================================

simple_post(Headers, Body, Responder, Config) ->
    AuthConfig = maps:get(auth_config, Config, #{provider => barrel_mcp_auth_none}),
    AuthRequest = #{headers => extract_headers(Headers, AuthConfig)},
    case authenticate(AuthConfig, AuthRequest) of
        {ok, AuthInfo} ->
            simple_post_authenticated(Headers, Body, Responder, Config, AuthInfo);
        {error, Reason} ->
            auth_error(Headers, Responder, AuthConfig, Reason)
    end.

simple_post_authenticated(Headers, Body, Responder, Config, AuthInfo) ->
    case barrel_mcp_protocol:decode(Body) of
        {ok, Request} ->
            RequestWithAuth = with_auth(Request, AuthInfo),
            case barrel_mcp_protocol:handle(RequestWithAuth) of
                no_response ->
                    reply(Responder, 204, cors_headers(Headers, Config, #{}), <<>>);
                {async, Plan} ->
                    Result = barrel_mcp_protocol:drive_async_plan(Plan, 60000),
                    reply_json(Headers, Responder, Config, 200, Result);
                Result ->
                    reply_json(Headers, Responder, Config, 200, Result)
            end;
        {error, parse_error} ->
            Err = barrel_mcp_protocol:error_response(null, ?JSONRPC_PARSE_ERROR,
                                                     <<"Parse error">>),
            reply_json(Headers, Responder, Config, 400, Err)
    end.

reply_json(Headers, Responder, Config, Status, Envelope) ->
    Json = barrel_mcp_protocol:encode(Envelope),
    reply(Responder, Status,
          cors_headers(Headers, Config,
                       #{<<"content-type">> => <<"application/json">>}),
          Json).

%%====================================================================
%% Streamable transport — POST
%%====================================================================

stream_post(Headers, Body, Responder, Config) ->
    case validate_accept_header(Headers) of
        {error, Reason} ->
            reply(Responder, 406, cors_headers(Headers, Config, #{}),
                  json_encode(#{<<"error">> => Reason}));
        ok ->
            AuthConfig = maps:get(auth_config, Config,
                                  #{provider => barrel_mcp_auth_none}),
            AuthRequest = #{headers => extract_headers(Headers, AuthConfig)},
            case authenticate(AuthConfig, AuthRequest) of
                {ok, AuthInfo} ->
                    stream_post_authed(Headers, Body, Responder, Config, AuthInfo);
                {error, Reason} ->
                    auth_error(Headers, Responder, AuthConfig, Reason)
            end
    end.

stream_post_authed(Headers, Body, Responder, Config, AuthInfo) ->
    SessionEnabled = maps:get(session_enabled, Config, true),
    case barrel_mcp_protocol:decode(Body) of
        {ok, Request} when is_list(Request) ->
            reply_jsonrpc_error(Headers, Responder, Config, undefined, 400, null,
                                ?JSONRPC_INVALID_REQUEST,
                                <<"Batch requests are not supported">>);
        {ok, Request} when is_map(Request) ->
            %% Pass the raw request through the response-vs-request
            %% split; `_auth' is attached only on the request path
            %% (handle_dispatch), never on inbound responses.
            stream_post_request(Headers, Responder, Config, SessionEnabled,
                                Request, AuthInfo);
        {error, parse_error} ->
            reply_jsonrpc_error(Headers, Responder, Config, undefined, 400, null,
                                ?JSONRPC_PARSE_ERROR, <<"Parse error">>)
    end.

%% Keep both the original request (for response detection) and an
%% auth-tagged copy used when dispatching to the protocol core.
stream_post_request(Headers, Responder, Config, SessionEnabled, Request, AuthInfo) ->
    case is_jsonrpc_response(Request) of
        true ->
            handle_inbound_response(Headers, Responder, Config, Request);
        false ->
            handle_inbound_request(Headers, Responder, Config, SessionEnabled,
                                   Request, AuthInfo)
    end.

is_jsonrpc_response(R) ->
    is_map_key(<<"id">>, R) andalso
        (is_map_key(<<"result">>, R) orelse is_map_key(<<"error">>, R)) andalso
        not is_map_key(<<"method">>, R).

handle_inbound_response(Headers, Responder, Config, #{<<"id">> := RespId} = Request) ->
    _ = barrel_mcp_session:deliver_response(RespId, Request),
    reply(Responder, 202, cors_headers(Headers, Config, #{}), <<>>).

handle_inbound_request(Headers, Responder, Config, SessionEnabled, Request, AuthInfo) ->
    Method = maps:get(<<"method">>, Request, undefined),
    case lookup_session(Headers, Config, SessionEnabled, Method) of
        {ok, SessionId} ->
            handle_dispatch(Headers, Responder, Config, SessionId, Request, AuthInfo);
        {error, missing_session_id} ->
            reply_jsonrpc_error(Headers, Responder, Config, undefined, 400, null,
                                ?JSONRPC_INVALID_REQUEST,
                                <<"Mcp-Session-Id header required">>);
        {error, unknown_session} ->
            reply_jsonrpc_error(Headers, Responder, Config, undefined, 404, null,
                                ?JSONRPC_INVALID_REQUEST,
                                <<"Unknown Mcp-Session-Id">>)
    end.

handle_dispatch(Headers, Responder, Config, SessionId, Request, AuthInfo) ->
    _ = case SessionId of
            undefined -> ok;
            _ -> barrel_mcp_session:update_activity(SessionId)
        end,
    Method = maps:get(<<"method">>, Request, undefined),
    case validate_protocol_version(Headers, SessionId, Method) of
        {error, ProtoErr} ->
            reply_jsonrpc_error(Headers, Responder, Config, SessionId, 400, null,
                                ?JSONRPC_INVALID_REQUEST, ProtoErr);
        ok ->
            ProtocolState0 = case SessionId of
                                 undefined -> #{};
                                 _ -> #{session_id => SessionId}
                             end,
            ProtocolState = ProtocolState0#{auth_info => AuthInfo},
            case barrel_mcp_protocol:handle(with_auth(Request, AuthInfo),
                                            ProtocolState) of
                no_response ->
                    Hdrs = add_session_header(
                             cors_headers(Headers, Config, #{}), SessionId),
                    reply(Responder, 202, Hdrs, <<>>);
                {async, AsyncPlan} ->
                    handle_async_tool_call(Headers, Responder, Config, SessionId,
                                           Request, AsyncPlan);
                Result ->
                    _ = maybe_capture_initialize_version(SessionId, Method, Result),
                    case wants_sse_response(Headers) of
                        true ->
                            stream_sse_response(Headers, Responder, Config,
                                                SessionId, Result);
                        false ->
                            ResponseJson = barrel_mcp_protocol:encode(Result),
                            Hdrs = add_session_header(
                                     cors_headers(Headers, Config,
                                                  #{<<"content-type">> =>
                                                        <<"application/json">>}),
                                     SessionId),
                            reply(Responder, 200, Hdrs, ResponseJson)
                    end
            end
    end.

%%====================================================================
%% Async tool calls
%%====================================================================

handle_async_tool_call(Headers, Responder, Config, SessionId, Request, AsyncPlan) ->
    RequestId = maps:get(request_id, AsyncPlan),
    Spawn = maps:get(spawn, AsyncPlan),
    Timeout = maps:get(timeout, AsyncPlan, 60000),
    Params = maps:get(<<"params">>, Request, #{}),
    ToolName = maps:get(<<"name">>, Params, <<>>),
    LongRunning = is_long_running_tool(ToolName),
    Meta = maps:get(<<"_meta">>, Params, #{}),
    ProgressToken = maps:get(<<"progressToken">>, Meta, undefined),
    Self = self(),
    case LongRunning of
        true ->
            handle_long_running_call(Headers, Responder, Config, SessionId,
                                     RequestId, ToolName, ProgressToken, Meta, Spawn);
        false ->
            Ctx = #{
                session_id => SessionId,
                request_id => RequestId,
                progress_token => ProgressToken,
                meta => Meta,
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
            deliver_tool_outcome(Headers, Responder, Config, SessionId,
                                 RequestId, Outcome)
    end.

is_long_running_tool(Name) ->
    case barrel_mcp_registry:find(tool, Name) of
        {ok, Handler} -> maps:get(long_running, Handler, false);
        error -> false
    end.

handle_long_running_call(Headers, Responder, Config, SessionId, RequestId,
                         ToolName, ProgressToken, Meta, Spawn) ->
    {ok, TaskId} = barrel_mcp_tasks:create(SessionId, ToolName, #{}),
    Collector = spawn_task_collector(SessionId, TaskId),
    Ctx = #{
        session_id => SessionId,
        request_id => RequestId,
        progress_token => ProgressToken,
        meta => Meta,
        emit_progress => emit_progress_fun(SessionId, ProgressToken),
        reply_to => Collector
    },
    Worker = Spawn(Ctx),
    _ = barrel_mcp_tasks:set_worker(SessionId, TaskId,
                                    #{worker => Worker, request_id => RequestId}),
    Task = case barrel_mcp_tasks:get(SessionId, TaskId) of
               {ok, T} -> T;
               _ -> #{<<"taskId">> => TaskId, <<"status">> => <<"working">>}
           end,
    send_tool_envelope(Headers, Responder, Config, SessionId, RequestId,
                       #{<<"task">> => Task}).

spawn_task_collector(SessionId, TaskId) ->
    spawn(fun() -> task_collector_loop(SessionId, TaskId) end).

task_collector_loop(SessionId, TaskId) ->
    receive
        {tool_result, _ReqId, Result} ->
            Content = barrel_mcp_protocol:format_tool_result_external(Result),
            barrel_mcp_tasks:finish(SessionId, TaskId, #{<<"content">> => Content});
        {tool_structured, _ReqId, Data, Content} ->
            barrel_mcp_tasks:finish(SessionId, TaskId,
                                    #{<<"content">> => Content,
                                      <<"structuredContent">> => Data});
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
    Outcome = receive
        {tool_result, RequestId, Result} -> {result, Result, #{}};
        {tool_result_meta, RequestId, Result, Meta} -> {result, Result, Meta};
        {tool_structured, RequestId, Data, Content} -> {structured, Data, Content, #{}};
        {tool_structured_meta, RequestId, Data, Content, Meta} ->
            {structured, Data, Content, Meta};
        {tool_error, RequestId, Content} -> {tool_error, Content, #{}};
        {tool_error_meta, RequestId, Content, Meta} -> {tool_error, Content, Meta};
        {tool_failed, RequestId, Reason} -> {failed, Reason};
        {tool_validation_failed, RequestId, Errors} -> {validation_failed, Errors};
        {cancelled, RequestId} -> cancelled
    after Timeout ->
        timeout
    end,
    case Outcome of
        cancelled -> cancelled;
        timeout -> timeout;
        _ ->
            %% Cancellation race: prefer a pending cancel.
            receive
                {cancelled, RequestId} -> cancelled
            after 50 -> Outcome
            end
    end.

deliver_tool_outcome(Headers, Responder, Config, SessionId, _RequestId, cancelled) ->
    Hdrs = add_session_header(cors_headers(Headers, Config, #{}), SessionId),
    reply(Responder, 200, Hdrs, <<>>);
deliver_tool_outcome(Headers, Responder, Config, SessionId, RequestId,
                     {result, Result, Meta}) ->
    Content = barrel_mcp_protocol:format_tool_result_external(Result),
    send_tool_envelope(Headers, Responder, Config, SessionId, RequestId,
                       #{<<"content">> => Content}, Meta);
deliver_tool_outcome(Headers, Responder, Config, SessionId, RequestId,
                     {structured, Data, Content, Meta}) ->
    send_tool_envelope(Headers, Responder, Config, SessionId, RequestId,
                       #{<<"content">> => Content,
                         <<"structuredContent">> => Data}, Meta);
deliver_tool_outcome(Headers, Responder, Config, SessionId, RequestId,
                     {tool_error, Content, Meta}) ->
    send_tool_envelope(Headers, Responder, Config, SessionId, RequestId,
                       #{<<"content">> => Content, <<"isError">> => true}, Meta);
deliver_tool_outcome(Headers, Responder, Config, SessionId, RequestId,
                     {validation_failed, Errors}) ->
    Msg = iolist_to_binary(io_lib:format("Invalid tool input: ~p", [Errors])),
    send_tool_envelope(Headers, Responder, Config, SessionId, RequestId,
                       #{<<"content">> =>
                            [#{<<"type">> => <<"text">>, <<"text">> => Msg}],
                         <<"isError">> => true});
deliver_tool_outcome(Headers, Responder, Config, SessionId, RequestId, {failed, _}) ->
    send_jsonrpc_error_envelope(Headers, Responder, Config, SessionId, RequestId,
                                ?MCP_TOOL_ERROR, <<"Internal tool error">>);
deliver_tool_outcome(Headers, Responder, Config, SessionId, RequestId, timeout) ->
    send_jsonrpc_error_envelope(Headers, Responder, Config, SessionId, RequestId,
                                ?MCP_TOOL_ERROR, <<"Tool timed out">>).

send_tool_envelope(Headers, Responder, Config, SessionId, RequestId, Result) ->
    send_tool_envelope(Headers, Responder, Config, SessionId, RequestId, Result, #{}).

send_tool_envelope(Headers, Responder, Config, SessionId, RequestId, Result, Meta) ->
    Resp = barrel_mcp_protocol:success_response(RequestId, Result, Meta),
    Json = barrel_mcp_protocol:encode(Resp),
    Hdrs = add_session_header(
             cors_headers(Headers, Config,
                          #{<<"content-type">> => <<"application/json">>}),
             SessionId),
    reply(Responder, 200, Hdrs, Json).

send_jsonrpc_error_envelope(Headers, Responder, Config, SessionId, Id, Code, Message) ->
    Resp = barrel_mcp_protocol:error_response(Id, Code, Message),
    Json = barrel_mcp_protocol:encode(Resp),
    Hdrs = add_session_header(
             cors_headers(Headers, Config,
                          #{<<"content-type">> => <<"application/json">>}),
             SessionId),
    reply(Responder, 200, Hdrs, Json).

reply_jsonrpc_error(Headers, Responder, Config, SessionId, Status, Id, Code, Message) ->
    Resp = barrel_mcp_protocol:error_response(Id, Code, Message),
    Json = barrel_mcp_protocol:encode(Resp),
    Hdrs = add_session_header(
             cors_headers(Headers, Config,
                          #{<<"content-type">> => <<"application/json">>}),
             SessionId),
    reply(Responder, Status, Hdrs, Json).

%%====================================================================
%% Session resolution / protocol version
%%====================================================================

lookup_session(_Headers, _Config, false, _Method) ->
    {ok, undefined};
lookup_session(Headers, Config, true, Method) ->
    case {Method, session_header(Headers)} of
        {<<"initialize">>, undefined} ->
            {ok, SessionId} = barrel_mcp_session:create(#{}),
            BufMax = maps:get(sse_buffer_size, Config, 256),
            _ = barrel_mcp_session:set_sse_buffer_max(SessionId, BufMax),
            {ok, SessionId};
        {<<"initialize">>, SessionId} ->
            case barrel_mcp_session:get(SessionId) of
                {ok, _} -> {ok, SessionId};
                {error, not_found} -> {error, unknown_session}
            end;
        {_, undefined} ->
            {error, missing_session_id};
        {_, SessionId} ->
            case barrel_mcp_session:get(SessionId) of
                {ok, _} -> {ok, SessionId};
                {error, not_found} -> {error, unknown_session}
            end
    end.

validate_protocol_version(_Headers, _Sid, <<"initialize">>) -> ok;
validate_protocol_version(Headers, SessionId, _Method) ->
    case header(<<"mcp-protocol-version">>, Headers, undefined) of
        undefined ->
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

maybe_capture_initialize_version(SessionId, <<"initialize">>,
                                 #{<<"result">> :=
                                       #{<<"protocolVersion">> := Version}})
  when is_binary(SessionId) ->
    _ = barrel_mcp_session:set_protocol_version(SessionId, Version),
    ok;
maybe_capture_initialize_version(_, _, _) -> ok.

%%====================================================================
%% Streamable transport — GET (long-lived SSE) and DELETE
%%====================================================================

stream_get_sse(Headers, Responder, Config) ->
    case maps:get(session_enabled, Config, true) of
        false ->
            reply(Responder, 400, cors_headers(Headers, Config, #{}),
                  json_encode(#{<<"error">> => <<"Sessions not enabled">>}));
        true ->
            case session_header(Headers) of
                undefined ->
                    reply(Responder, 400, cors_headers(Headers, Config, #{}),
                          json_encode(#{<<"error">> =>
                                            <<"Mcp-Session-Id header required">>}));
                SessionId ->
                    stream_get_sse_session(Headers, Responder, Config, SessionId)
            end
    end.

stream_get_sse_session(Headers, Responder, Config, SessionId) ->
    case barrel_mcp_session:get(SessionId) of
        {ok, _Session} ->
            Hdrs = add_session_header(
                     cors_headers(Headers, Config,
                                  #{<<"content-type">> => <<"text/event-stream">>,
                                    <<"cache-control">> => <<"no-cache">>,
                                    <<"connection">> => <<"keep-alive">>}),
                     SessionId),
            stream_start(Responder, 200, Hdrs),
            replay_sse_events(Responder, SessionId,
                              header(<<"last-event-id">>, Headers, undefined)),
            _ = barrel_mcp_session:set_sse_pid(SessionId, self()),
            sse_loop(Responder, SessionId);
        {error, not_found} ->
            reply(Responder, 404, cors_headers(Headers, Config, #{}),
                  json_encode(#{<<"error">> => <<"Unknown Mcp-Session-Id">>}))
    end.

%% Long-lived SSE pump. Runs in the per-request process until the
%% session is terminated, the client disconnects (`mcp_disconnect'
%% from the binding) or a chunk write fails.
sse_loop(Responder, SessionId) ->
    receive
        session_terminated ->
            sse_cleanup(Responder, SessionId);
        mcp_disconnect ->
            sse_cleanup(Responder, SessionId);
        {sse_event, EventId, Data} ->
            case push_sse_event(Responder, EventId, Data) of
                ok ->
                    _ = barrel_mcp_session:record_sse_event(SessionId, EventId, Data),
                    sse_loop(Responder, SessionId);
                {error, _} ->
                    sse_cleanup(Responder, SessionId)
            end;
        {sse_send_message, Message} ->
            EventId = generate_event_id(),
            case push_sse_event(Responder, EventId, Message) of
                ok ->
                    _ = barrel_mcp_session:record_sse_event(SessionId, EventId, Message),
                    sse_loop(Responder, SessionId);
                {error, _} ->
                    sse_cleanup(Responder, SessionId)
            end;
        _Other ->
            sse_loop(Responder, SessionId)
    end.

sse_cleanup(Responder, SessionId) ->
    catch barrel_mcp_session:set_sse_pid(SessionId, undefined),
    _ = stream_end(Responder),
    ok.

stream_delete(Headers, Responder, Config) ->
    case session_header(Headers) of
        undefined ->
            reply(Responder, 400, cors_headers(Headers, Config, #{}),
                  json_encode(#{<<"error">> => <<"Mcp-Session-Id header required">>}));
        SessionId ->
            case barrel_mcp_session:get(SessionId) of
                {ok, _} ->
                    barrel_mcp_session:delete(SessionId),
                    reply(Responder, 204, cors_headers(Headers, Config, #{}), <<>>);
                {error, not_found} ->
                    reply(Responder, 404, cors_headers(Headers, Config, #{}),
                          json_encode(#{<<"error">> => <<"Unknown Mcp-Session-Id">>}))
            end
    end.

%%====================================================================
%% SSE helpers
%%====================================================================

%% Single-event SSE response to a POST: open, send the result, close.
stream_sse_response(Headers, Responder, Config, SessionId, Result) ->
    Hdrs = add_session_header(
             cors_headers(Headers, Config,
                          #{<<"content-type">> => <<"text/event-stream">>,
                            <<"cache-control">> => <<"no-cache">>}),
             SessionId),
    stream_start(Responder, 200, Hdrs),
    _ = push_sse_event(Responder, generate_event_id(), Result),
    stream_end(Responder).

push_sse_event(Responder, EventId, Data) ->
    Json = json_encode(Data),
    EventData = iolist_to_binary([<<"id: ">>, EventId, <<"\n">>,
                                  <<"data: ">>, Json, <<"\n\n">>]),
    stream_chunk(Responder, EventData).

generate_event_id() ->
    integer_to_binary(erlang:system_time(microsecond)).

replay_sse_events(_Responder, _SessionId, undefined) ->
    ok;
replay_sse_events(Responder, SessionId, LastId) ->
    case barrel_mcp_session:events_since(SessionId, LastId) of
        {ok, Events} ->
            lists:foreach(fun({EventId, Payload}) ->
                _ = push_sse_event(Responder, EventId, Payload)
            end, Events),
            ok;
        truncated ->
            _ = push_sse_event(Responder, generate_event_id(),
                               #{<<"jsonrpc">> => <<"2.0">>,
                                 <<"method">> => <<"notifications/replay_truncated">>,
                                 <<"params">> => #{}}),
            ok;
        {error, not_found} -> ok
    end.

%%====================================================================
%% Validation helpers
%%====================================================================

validate_accept_header(Headers) ->
    Accept = header(<<"accept">>, Headers, <<"*/*">>),
    HasWildcard = binary:match(Accept, <<"*/*">>) =/= nomatch,
    HasJson = binary:match(Accept, <<"application/json">>) =/= nomatch,
    HasSse = binary:match(Accept, <<"text/event-stream">>) =/= nomatch,
    case HasWildcard orelse (HasJson andalso HasSse) of
        true -> ok;
        false ->
            {error, <<"Accept header must include both application/json"
                      " and text/event-stream">>}
    end.

wants_sse_response(Headers) ->
    Accept = header(<<"accept">>, Headers, <<>>),
    HasJson = binary:match(Accept, <<"application/json">>) =/= nomatch,
    HasSse = binary:match(Accept, <<"text/event-stream">>) =/= nomatch,
    case {HasJson, HasSse} of
        {false, true} -> true;
        {true, true} ->
            SsePos = match_pos(Accept, <<"text/event-stream">>),
            JsonPos = match_pos(Accept, <<"application/json">>),
            SsePos < JsonPos;
        _ -> false
    end.

match_pos(Bin, Needle) ->
    case binary:match(Bin, Needle) of
        nomatch -> infinity;
        {P, _} -> P
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

auth_error(Headers, Responder, AuthConfig, Reason) ->
    {StatusCode, AuthHeaders, Body} =
        barrel_mcp_auth:challenge_response(AuthConfig, Reason),
    %% AuthHeaders is a map; merge with CORS and emit as a list.
    Merged = maps:merge(AuthHeaders,
                        cors_headers(Headers, #{auth_config => AuthConfig}, #{})),
    reply(Responder, StatusCode, Merged, Body).

extract_headers(Headers, AuthConfig) ->
    Names = case AuthConfig of
                undefined -> [<<"authorization">>, <<"x-api-key">>];
                _ ->
                    case barrel_mcp_auth:auth_headers(AuthConfig) of
                        [] -> [<<"authorization">>, <<"x-api-key">>];
                        Decl -> Decl
                    end
            end,
    lists:foldl(fun(Name, Acc) ->
        case header(Name, Headers, undefined) of
            undefined -> Acc;
            Value -> Acc#{Name => Value}
        end
    end, #{}, Names).

%% The user-facing `resource_metadata' option processing.
normalize_resource_metadata(undefined) ->
    undefined;
normalize_resource_metadata(#{resource := ResourceUrl} = M) ->
    Doc = maps:without([metadata_url], M),
    MetaUrl = case maps:get(metadata_url, M, undefined) of
        undefined -> derive_prm_url(ResourceUrl);
        Explicit when is_binary(Explicit) -> Explicit
    end,
    #{document => Doc, url => MetaUrl}.

derive_prm_url(Resource) when is_binary(Resource) ->
    case uri_string:parse(Resource) of
        #{scheme := Scheme, host := Host} = Parsed ->
            PortPart = case maps:get(port, Parsed, undefined) of
                undefined -> <<>>;
                P -> iolist_to_binary([<<":">>, integer_to_binary(P)])
            end,
            iolist_to_binary([Scheme, <<"://">>, Host, PortPart,
                              <<"/.well-known/oauth-protected-resource">>]);
        _ ->
            <<Resource/binary, "/.well-known/oauth-protected-resource">>
    end.

inject_resource_metadata_url(AuthConfig, undefined) ->
    AuthConfig;
inject_resource_metadata_url(#{provider_state := State} = AuthConfig, #{url := Url})
  when is_map(State) ->
    AuthConfig#{provider_state => State#{resource_metadata_url => Url}};
inject_resource_metadata_url(AuthConfig, _) ->
    AuthConfig.

%%====================================================================
%% CORS
%%====================================================================

cors_headers(Headers, Config, Extra) ->
    BaseAllowHeaders = [<<"content-type">>, <<"accept">>,
                        <<"mcp-session-id">>, <<"mcp-protocol-version">>,
                        <<"last-event-id">>],
    AuthHeaders = case maps:get(auth_config, Config, undefined) of
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
    WithOrigin = case header(<<"origin">>, Headers, undefined) of
                     undefined -> Base;
                     Origin -> Base#{<<"access-control-allow-origin">> => Origin,
                                     <<"vary">> => <<"Origin">>}
                 end,
    maps:merge(WithOrigin, Extra).

%%====================================================================
%% Origin validation + bind helpers
%%====================================================================

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

parse_origin(<<"null">>) ->
    null;
parse_origin(Bin) when is_binary(Bin) ->
    case uri_string:parse(Bin) of
        #{scheme := Scheme, host := Host} = U ->
            #{scheme => to_bin(Scheme), host => to_bin(Host),
              port => maps:get(port, U, any)};
        _ ->
            #{scheme => undefined, host => Bin, port => any}
    end.

is_loopback({127, _, _, _}) -> true;
is_loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback("localhost") -> true;
is_loopback(<<"localhost">>) -> true;
is_loopback(_) -> false.

validate_origin(Headers, Config) ->
    Allowed = maps:get(allowed_origins, Config, any),
    AllowMissing = maps:get(allow_missing_origin, Config, true),
    case header(<<"origin">>, Headers, undefined) of
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

%%====================================================================
%% Session manager bootstrap
%%====================================================================

ensure_session_manager() ->
    case whereis(barrel_mcp_session) of
        undefined ->
            case whereis(barrel_mcp_sup) of
                undefined -> barrel_mcp_session:start_link();
                _ -> ok
            end;
        _ ->
            ok
    end.

%%====================================================================
%% Request/response plumbing
%%====================================================================

%% Tag the decoded request with the authenticated principal under
%% `_auth' before handing it to the protocol core. Authentication
%% always yields an info map (auth_none included), so there is no
%% untagged path.
with_auth(Request, AuthInfo) -> Request#{<<"_auth">> => AuthInfo}.

session_header(Headers) ->
    header(<<"mcp-session-id">>, Headers, undefined).

add_session_header(Headers, undefined) -> Headers;
add_session_header(Headers, SessionId) ->
    Headers#{<<"mcp-session-id">> => SessionId}.

%% Case-insensitive header lookup over a `[{binary(), binary()}]' list.
header(Name, Headers, Default) ->
    Lower = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(to_bin(K)) =:= Lower end,
                      Headers) of
        {value, {_, V}} -> to_bin(V);
        false -> Default
    end.

reply(Responder, Status, HeadersMap, Body) ->
    Fun = maps:get(reply, Responder),
    Fun(Status, headers_list(HeadersMap), Body),
    ok.

stream_start(Responder, Status, HeadersMap) ->
    Fun = maps:get(stream_start, Responder),
    Fun(Status, headers_list(HeadersMap)),
    ok.

stream_chunk(Responder, Data) ->
    Fun = maps:get(stream_chunk, Responder),
    Fun(Data).

stream_end(Responder) ->
    Fun = maps:get(stream_end, Responder),
    Fun().

headers_list(Map) -> maps:to_list(Map).

json_encode(Data) ->
    iolist_to_binary(json:encode(Data)).

strip_query(Path) ->
    case binary:split(Path, <<"?">>) of
        [P, _] -> P;
        [P] -> P
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> iolist_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
