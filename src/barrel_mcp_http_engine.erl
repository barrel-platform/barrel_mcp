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
%%%   <li>`Config' — the engine configuration (see the `config()' type).</li>
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
    subscription_keepalive_ms => pos_integer(),
    resource_metadata => undefined | map(),
    _ => _
}.

-export_type([responder/0, config/0]).

%% Cap incoming SSE response size mirrors the client-side cap.
-define(MAX_RESP_BYTES, 16 * 1024 * 1024).

%%====================================================================
%% Entry point
%%====================================================================

-spec handle(
    binary(),
    binary(),
    [{binary(), binary()}],
    binary(),
    responder(),
    config()
) -> ok.
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
                    route(Method, Path, RawPath, Headers, Body, Responder, Config);
                {error, _Reason} ->
                    %% 403 with no CORS header so the browser surfaces
                    %% the rejection rather than retrying.
                    reply(Responder, 403, #{}, <<>>)
            end
    end.

%% The 2024-11-05 transport lives on its own two routes, and only when
%% they are configured: a GET there and a Streamable GET are otherwise
%% indistinguishable.
route(<<"GET">>, Path, _RawPath, Headers, _Body, Responder, Config) when
    map_get(sse_path, Config) =:= Path
->
    legacy_sse_open(Headers, Responder, Config);
route(<<"POST">>, Path, RawPath, Headers, Body, Responder, Config) when
    map_get(sse_message_path, Config) =:= Path
->
    legacy_sse_post(RawPath, Headers, Body, Responder, Config);
route(Method, _Path, _RawPath, Headers, Body, Responder, Config) ->
    dispatch(maps:get(mode, Config, stream), Method, Headers, Body, Responder, Config).

serve_prm(Responder, Doc) ->
    Body = iolist_to_binary(json:encode(Doc)),
    reply(
        Responder,
        200,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"public, max-age=300">>
        },
        Body
    ).

%%====================================================================
%% Method dispatch
%%====================================================================

%% --- Simple transport (POST/OPTIONS only, no sessions, no SSE) ---
dispatch(simple, <<"POST">>, Headers, Body, Responder, Config) ->
    simple_post(Headers, Body, Responder, Config);
dispatch(simple, <<"OPTIONS">>, Headers, _Body, Responder, Config) ->
    reply(Responder, 204, cors_headers(Headers, Config, #{}), <<>>);
dispatch(simple, _Method, Headers, _Body, Responder, Config) ->
    method_not_allowed(Headers, Responder, Config, <<"POST, OPTIONS">>);
%% --- Streamable transport ---
dispatch(stream, <<"POST">>, Headers, Body, Responder, Config) ->
    stream_post(Headers, Body, Responder, Config);
dispatch(stream, <<"GET">>, Headers, _Body, Responder, Config) ->
    case sessions_enabled(Config) of
        true -> stream_get_sse(Headers, Responder, Config);
        false -> modern_only_method(Headers, Responder, Config)
    end;
dispatch(stream, <<"DELETE">>, Headers, _Body, Responder, Config) ->
    case sessions_enabled(Config) of
        true -> stream_delete(Headers, Responder, Config);
        false -> modern_only_method(Headers, Responder, Config)
    end;
dispatch(stream, <<"OPTIONS">>, Headers, _Body, Responder, Config) ->
    reply(Responder, 204, cors_headers(Headers, Config, #{}), <<>>);
dispatch(stream, _Method, Headers, _Body, Responder, Config) ->
    method_not_allowed(Headers, Responder, Config, <<"POST, GET, DELETE, OPTIONS">>).

%% Sessions off means only 2026-07-28 is served, which has neither a
%% standalone GET stream nor a DELETE. An older client that tries either
%% "SHOULD" get 405 (2026-07-28/.../streamable-http.mdx:683).
modern_only_method(Headers, Responder, Config) ->
    method_not_allowed(Headers, Responder, Config, <<"POST, OPTIONS">>).

method_not_allowed(Headers, Responder, Config, Allow) ->
    reply(
        Responder,
        405,
        cors_headers(
            Headers,
            Config,
            #{
                <<"content-type">> => <<"application/json">>,
                <<"allow">> => Allow
            }
        ),
        <<"{\"error\":\"Method not allowed\"}">>
    ).

sessions_enabled(Config) ->
    case maps:get(session_enabled, Config, true) of
        false -> false;
        _ -> true
    end.

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
                    Result = barrel_mcp_protocol:drive_async_plan(
                        Plan,
                        60000,
                        AuthInfo
                    ),
                    reply_json(Headers, Responder, Config, 200, Result);
                Result ->
                    reply_json(Headers, Responder, Config, 200, Result)
            end;
        {error, parse_error} ->
            Err = barrel_mcp_protocol:error_response(
                null,
                ?JSONRPC_PARSE_ERROR,
                <<"Parse error">>
            ),
            reply_json(Headers, Responder, Config, 400, Err)
    end.

reply_json(Headers, Responder, Config, Status, Envelope) ->
    Json = barrel_mcp_protocol:encode(Envelope),
    reply(
        Responder,
        Status,
        cors_headers(
            Headers,
            Config,
            #{<<"content-type">> => <<"application/json">>}
        ),
        Json
    ).

%%====================================================================
%% Streamable transport — POST
%%====================================================================

stream_post(Headers, Body, Responder, Config) ->
    case validate_accept_header(Headers) of
        {error, Reason} ->
            reply(
                Responder,
                406,
                cors_headers(Headers, Config, #{}),
                json_encode(#{<<"error">> => Reason})
            );
        ok ->
            AuthConfig = maps:get(
                auth_config,
                Config,
                #{provider => barrel_mcp_auth_none}
            ),
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
        {ok, Batch} when is_list(Batch) ->
            stream_post_batch(Headers, Responder, Config, SessionEnabled, Batch, AuthInfo);
        {ok, Request} when is_map(Request) ->
            %% Pass the raw request through the response-vs-request
            %% split; `_auth' is attached only on the request path
            %% (handle_dispatch), never on inbound responses.
            stream_post_request(
                Headers,
                Responder,
                Config,
                SessionEnabled,
                Request,
                AuthInfo
            );
        {error, parse_error} ->
            reply_jsonrpc_error(
                Headers,
                Responder,
                Config,
                undefined,
                400,
                null,
                ?JSONRPC_PARSE_ERROR,
                <<"Parse error">>
            )
    end.

%% A batch never carries a session id of its own and never creates one,
%% so it reuses the session the header names, if any. Whether it is
%% accepted at all depends on the negotiated revision, which the
%% protocol core decides.
stream_post_batch(Headers, Responder, Config, SessionEnabled, Batch, AuthInfo) ->
    SessionId =
        case lookup_session(Headers, Config, SessionEnabled, undefined) of
            {ok, Sid} -> Sid;
            {error, _} -> undefined
        end,
    ProtocolState = #{
        auth_info => AuthInfo,
        protocol_version => negotiated_version(Headers, SessionId),
        session_id => SessionId
    },
    case barrel_mcp_protocol:handle(with_auth_elements(Batch, AuthInfo), ProtocolState) of
        no_response ->
            Hdrs = add_session_header(cors_headers(Headers, Config, #{}), SessionId),
            reply(Responder, 202, Hdrs, <<>>);
        Response when is_map(Response) ->
            %% A refusal of the whole envelope, not a per-element answer.
            reply_json(Headers, Responder, Config, 400, Response);
        Responses when is_list(Responses) ->
            reply_json(Headers, Responder, Config, 200, Responses)
    end.

with_auth_elements(Batch, AuthInfo) ->
    [
        case E of
            M when is_map(M) -> with_auth(M, AuthInfo);
            Other -> Other
        end
     || E <- Batch
    ].

%% Keep both the original request (for response detection) and an
%% auth-tagged copy used when dispatching to the protocol core.
%%
%% This is the era fork. It sits after decode and before session
%% lookup, so a modern request never touches the session machinery and
%% every legacy request takes exactly the path it did before.
stream_post_request(Headers, Responder, Config, SessionEnabled, Request, AuthInfo) ->
    case is_jsonrpc_response(Request) of
        true ->
            %% Only legacy clients send responses: modern servers never
            %% issue requests, so there is nothing to answer.
            handle_inbound_response(Headers, Responder, Config, Request);
        false ->
            case barrel_mcp_ctx:era(barrel_mcp_ctx:from_request(Request)) of
                modern ->
                    handle_modern_request(
                        Headers,
                        Responder,
                        Config,
                        Request,
                        AuthInfo
                    );
                legacy ->
                    handle_inbound_request(
                        Headers,
                        Responder,
                        Config,
                        SessionEnabled,
                        Request,
                        AuthInfo
                    )
            end
    end.

%%====================================================================
%% Streamable transport — modern (2026-07-28) requests
%%====================================================================

%% Stateless: no session to look up, none to mint, and no
%% `Mcp-Session-Id' on the way back.
handle_modern_request(Headers, Responder, Config, Request, AuthInfo) ->
    case validate_metadata_headers(Headers, Request) of
        {error, Message} ->
            Id = maps:get(<<"id">>, Request, null),
            reply_jsonrpc_error(
                Headers,
                Responder,
                Config,
                undefined,
                400,
                Id,
                ?MCP_HEADER_MISMATCH,
                Message
            );
        ok ->
            dispatch_modern_request(Headers, Responder, Config, Request, AuthInfo)
    end.

%% The headers mirror body fields so an intermediary can route without
%% parsing the body. If the two disagree, one component has acted on a
%% different request than the other will, so the request is rejected
%% rather than resolved in favour of either.
validate_metadata_headers(Headers, Request) ->
    case maps:is_key(<<"id">>, Request) of
        false ->
            %% A notification. This revision leaves header requirements
            %% for notification POSTs undefined, so there is nothing to
            %% hold it to.
            ok;
        true ->
            validate_request_headers(Headers, Request)
    end.

validate_request_headers(Headers, Request) ->
    Method = maps:get(<<"method">>, Request, <<>>),
    Params = params_of(Request),
    case check_protocol_version_header(Headers, Params) of
        {error, _} = Err ->
            Err;
        ok ->
            barrel_mcp_headers:validate(
                Headers,
                Method,
                Params,
                header_params_for(Method, Params)
            )
    end.

%% The header has to carry the same version as the body: an
%% intermediary enforcing policy reads one, the server executes on the
%% other.
check_protocol_version_header(Headers, Params) ->
    Meta = maps:get(<<"_meta">>, Params, #{}),
    Declared = maps:get(?MCP_META_PROTOCOL_VERSION, Meta, undefined),
    Header = header(<<"mcp-protocol-version">>, Headers, undefined),
    check_protocol_version_header(Header, Declared, is_binary(Declared)).

%% The declared version reaches us from a peer's `_meta' and is
%% interpolated into the mismatch message. A number or a null there
%% would raise `badarg' instead of returning an error, so it is
%% confirmed to be a string before any message is built.
check_protocol_version_header(_Header, _Declared, false) ->
    {error, <<"Header mismatch: protocol version in _meta must be a string">>};
check_protocol_version_header(undefined, _Declared, true) ->
    {error, <<"Header mismatch: MCP-Protocol-Version header is required">>};
check_protocol_version_header(Declared, Declared, true) ->
    ok;
check_protocol_version_header(Other, Declared, true) ->
    {error,
        <<"Header mismatch: MCP-Protocol-Version header value '", Other/binary,
            "' does not match body value '", Declared/binary, "'">>}.

%% Only a tool call mirrors parameters, and only the ones its schema
%% opted into. The bindings were validated and stored at registration.
header_params_for(<<"tools/call">>, Params) ->
    case barrel_mcp_registry:find(tool, maps:get(<<"name">>, Params, <<>>)) of
        {ok, Handler} -> maps:get(header_params, Handler, []);
        error -> []
    end;
header_params_for(_Method, _Params) ->
    [].

params_of(Request) ->
    case maps:get(<<"params">>, Request, #{}) of
        P when is_map(P) -> P;
        _ -> #{}
    end.

dispatch_modern_request(Headers, Responder, Config, Request, AuthInfo) ->
    case
        barrel_mcp_protocol:handle(
            with_auth(Request, AuthInfo),
            #{auth_info => AuthInfo, streaming => true}
        )
    of
        no_response ->
            reply(Responder, 202, cors_headers(Headers, Config, #{}), <<>>);
        {subscribe, Sub} ->
            handle_subscription(Headers, Responder, Config, Sub);
        {async, AsyncPlan} ->
            handle_async_tool_call(
                Headers,
                Responder,
                Config,
                undefined,
                Request,
                AsyncPlan,
                AuthInfo
            );
        Result ->
            case wants_sse_response(Headers) of
                true ->
                    stream_sse_response(Headers, Responder, Config, undefined, Result);
                false ->
                    Hdrs = cors_headers(
                        Headers,
                        Config,
                        #{<<"content-type">> => <<"application/json">>}
                    ),
                    reply(
                        Responder,
                        modern_status(Result),
                        Hdrs,
                        barrel_mcp_protocol:encode(Result)
                    )
            end
    end.

%%====================================================================
%% Streamable transport — subscriptions/listen
%%====================================================================

%% The response stream to a `subscriptions/listen' request stays open
%% and carries the notifications the client opted into. Runs in the
%% per-request process until the client goes away or the server ends
%% the subscription.
handle_subscription(Headers, Responder, Config, #{id := SubId, filter := Filter}) ->
    Hdrs = cors_headers(
        Headers,
        Config,
        #{
            <<"content-type">> => <<"text/event-stream">>,
            <<"cache-control">> => <<"no-cache">>,
            <<"x-accel-buffering">> => <<"no">>
        }
    ),
    stream_start(Responder, 200, Hdrs),
    %% Register before acknowledging, so nothing fired between the two
    %% is lost. Ordering is still guaranteed because this process is
    %% the only writer: a notification arriving now waits in the
    %% mailbox and is written after the acknowledgment, which the spec
    %% requires to come first.
    ok = barrel_mcp_subscriptions:subscribe(SubId, Filter),
    _ = push_sse_data(Responder, acknowledgment(SubId, Filter)),
    subscription_loop(Responder, SubId, keepalive_interval(Config)).

acknowledgment(SubId, Filter) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/subscriptions/acknowledged">>,
        <<"params">> => #{
            <<"_meta">> => #{?MCP_META_SUBSCRIPTION_ID => SubId},
            <<"notifications">> => honoured(Filter)
        }
    }.

%% Report back what we agreed to, in the wire shape the client used.
honoured(Filter) ->
    Flags = [
        {tools_list_changed, <<"toolsListChanged">>},
        {prompts_list_changed, <<"promptsListChanged">>},
        {resources_list_changed, <<"resourcesListChanged">>}
    ],
    Base = lists:foldl(
        fun({Key, WireKey}, Acc) ->
            case maps:get(Key, Filter, false) of
                true -> Acc#{WireKey => true};
                false -> Acc
            end
        end,
        #{},
        Flags
    ),
    Base1 =
        case maps:get(resource_subscriptions, Filter, []) of
            [] -> Base;
            Uris -> Base#{<<"resourceSubscriptions">> => Uris}
        end,
    %% Only the ids we agreed to deliver. An id belonging to someone
    %% else, or naming no task, is left out rather than refused, so a
    %% caller cannot learn which of the two it was.
    case maps:get(task_ids, Filter, []) of
        [] -> Base1;
        Ids -> Base1#{<<"taskIds">> => Ids}
    end.

subscription_loop(Responder, SubId, Interval) ->
    receive
        {mcp_notification, SubId, Envelope} ->
            case push_sse_data(Responder, Envelope) of
                ok -> subscription_loop(Responder, SubId, Interval);
                {error, _} -> end_subscription(Responder, SubId)
            end;
        {mcp_subscription_close, SubId} ->
            %% "MUST send notifications/cancelled referencing a
            %% subscriptions/listen request ID when it tears down that
            %% subscription stream" (cancellation.mdx:12), then "SHOULD
            %% respond to the original subscriptions/listen request with
            %% a completion result" (subscriptions.mdx:130).
            _ = push_sse_data(Responder, subscription_cancelled(SubId)),
            _ = push_sse_data(Responder, subscription_closed(SubId)),
            end_subscription(Responder, SubId);
        mcp_disconnect ->
            end_subscription(Responder, SubId);
        {'EXIT', _Conn, _Reason} ->
            end_subscription(Responder, SubId);
        _Other ->
            subscription_loop(Responder, SubId, Interval)
    after Interval ->
        %% An SSE comment. Keeps intermediaries and idle timeouts from
        %% dropping a quiet stream; clients ignore it.
        case stream_chunk(Responder, <<":\r\n">>) of
            ok -> subscription_loop(Responder, SubId, Interval);
            {error, _} -> end_subscription(Responder, SubId)
        end
    end.

%% The one purpose a server may send this for: "Servers MUST NOT send
%% notifications/cancelled for any other purpose" (cancellation.mdx:12).
subscription_cancelled(SubId) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/cancelled">>,
        <<"params">> => #{
            <<"_meta">> => #{?MCP_META_SUBSCRIPTION_ID => SubId},
            <<"requestId">> => SubId,
            <<"reason">> => <<"Subscription torn down by the server">>
        }
    }.

subscription_closed(SubId) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => SubId,
        <<"result">> => #{
            <<"resultType">> => <<"complete">>,
            <<"_meta">> => #{?MCP_META_SUBSCRIPTION_ID => SubId}
        }
    }.

end_subscription(Responder, SubId) ->
    _ =
        (try
            barrel_mcp_subscriptions:unsubscribe(SubId)
        catch
            _:_ -> ok
        end),
    _ = stream_end(Responder),
    ok.

keepalive_interval(Config) ->
    maps:get(subscription_keepalive_ms, Config, 15000).

%% The 2026-07-28 transport binding pins a few JSON-RPC errors to an
%% HTTP status so an intermediary can act on them without parsing the
%% body: an unimplemented method is 404, and a malformed or
%% unservable request is 400. Everything else, including ordinary
%% handler failures, stays 200 with the error in the body.
modern_status(#{<<"error">> := #{<<"code">> := Code}}) ->
    case Code of
        ?JSONRPC_METHOD_NOT_FOUND -> 404;
        ?JSONRPC_INVALID_PARAMS -> 400;
        ?MCP_HEADER_MISMATCH -> 400;
        ?MCP_MISSING_CLIENT_CAPABILITY -> 400;
        ?MCP_UNSUPPORTED_PROTOCOL_VERSION -> 400;
        _ -> 200
    end;
modern_status(_Result) ->
    200.

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
            reply_jsonrpc_error(
                Headers,
                Responder,
                Config,
                undefined,
                400,
                null,
                ?JSONRPC_INVALID_REQUEST,
                <<"Mcp-Session-Id header required">>
            );
        {error, unknown_session} ->
            reply_jsonrpc_error(
                Headers,
                Responder,
                Config,
                undefined,
                404,
                null,
                ?JSONRPC_INVALID_REQUEST,
                <<"Unknown Mcp-Session-Id">>
            )
    end.

handle_dispatch(Headers, Responder, Config, SessionId, Request, AuthInfo) ->
    _ =
        case SessionId of
            undefined -> ok;
            _ -> barrel_mcp_session:update_activity(SessionId)
        end,
    Method = maps:get(<<"method">>, Request, undefined),
    case validate_protocol_version(Headers, SessionId, Method) of
        {error, ProtoErr} ->
            reply_jsonrpc_error(
                Headers,
                Responder,
                Config,
                SessionId,
                400,
                null,
                ?JSONRPC_INVALID_REQUEST,
                ProtoErr
            );
        ok ->
            ProtocolState0 =
                case SessionId of
                    undefined -> #{};
                    _ -> #{session_id => SessionId}
                end,
            %% The negotiated revision decides whether a batch is
            %% accepted at all, so the protocol core needs it rather
            %% than only the session id it is recorded against.
            ProtocolState = ProtocolState0#{
                auth_info => AuthInfo,
                protocol_version => negotiated_version(Headers, SessionId)
            },
            case
                barrel_mcp_protocol:handle(
                    with_auth(Request, AuthInfo),
                    ProtocolState
                )
            of
                no_response ->
                    Hdrs = add_session_header(
                        cors_headers(Headers, Config, #{}), SessionId
                    ),
                    reply(Responder, 202, Hdrs, <<>>);
                {async, AsyncPlan} ->
                    handle_async_tool_call(
                        Headers,
                        Responder,
                        Config,
                        SessionId,
                        Request,
                        AsyncPlan,
                        AuthInfo
                    );
                Result ->
                    _ = maybe_capture_initialize_version(SessionId, Method, Result),
                    case wants_sse_response(Headers) of
                        true ->
                            stream_sse_response(
                                Headers,
                                Responder,
                                Config,
                                SessionId,
                                Result
                            );
                        false ->
                            ResponseJson = barrel_mcp_protocol:encode(Result),
                            Hdrs = add_session_header(
                                cors_headers(
                                    Headers,
                                    Config,
                                    #{
                                        <<"content-type">> =>
                                            <<"application/json">>
                                    }
                                ),
                                SessionId
                            ),
                            reply(Responder, 200, Hdrs, ResponseJson)
                    end
            end
    end.

%%====================================================================
%% Async tool calls
%%====================================================================

handle_async_tool_call(
    Headers,
    Responder,
    Config,
    SessionId,
    Request,
    AsyncPlan,
    AuthInfo
) ->
    RequestId = maps:get(request_id, AsyncPlan),
    Spawn = maps:get(spawn, AsyncPlan),
    Timeout = maps:get(timeout, AsyncPlan, 60000),
    %% What the reply needs: the session to echo (legacy only) and the
    %% request context that decorates a modern result.
    Reply = #{
        session_id => SessionId,
        ctx => maps:get(ctx, AsyncPlan, undefined),
        plan => AsyncPlan
    },
    Params = maps:get(<<"params">>, Request, #{}),
    ToolName = maps:get(<<"name">>, Params, <<>>),
    RequestCtx = maps:get(ctx, Reply),
    %% A tool may be long-running, but a client that never declared the
    %% tasks extension has no way to poll one, so it is run
    %% synchronously instead.
    LongRunning =
        barrel_mcp_protocol:long_running_tool(ToolName) andalso
            tasks_available(RequestCtx),
    Meta = maps:get(<<"_meta">>, Params, #{}),
    ProgressToken = maps:get(<<"progressToken">>, Meta, undefined),
    Self = self(),
    case LongRunning of
        true ->
            handle_long_running_call(
                Headers,
                Responder,
                Config,
                Reply,
                RequestId,
                ToolName,
                ProgressToken,
                Meta,
                Spawn,
                AuthInfo
            );
        false ->
            %% Opting into progress or logging turns the reply into an
            %% SSE stream, opened before the tool runs.
            LogLevel = request_log_level(Reply),
            Streaming = streams_notifications(Reply, ProgressToken, LogLevel),
            EmitProgress =
                case Streaming of
                    true -> self_progress_fun(Self, RequestId, ProgressToken);
                    false -> emit_progress_fun(SessionId, ProgressToken)
                end,
            EmitLog =
                case Streaming of
                    true -> self_log_fun(Self, RequestId, LogLevel);
                    false -> emit_log_fun(Reply, SessionId)
                end,
            Ctx = #{
                session_id => SessionId,
                request_id => RequestId,
                progress_token => ProgressToken,
                meta => Meta,
                emit_progress => EmitProgress,
                emit_log => EmitLog,
                reply_to => Self,
                auth_info => AuthInfo
            },
            OnProgress = start_progress_stream(
                Streaming, Headers, Responder, Config, Reply
            ),
            WorkerPid = Spawn(Ctx),
            %% No worker means nothing to cancel, and its `tool_failed'
            %% is already on its way.
            case {SessionId, is_pid(WorkerPid)} of
                {undefined, _} ->
                    ok;
                {_, false} ->
                    ok;
                {_, true} ->
                    ok = barrel_mcp_session:record_in_flight(
                        SessionId, RequestId, WorkerPid, Self
                    )
            end,
            Outcome0 = wait_for_tool(
                RequestId, Timeout, OnProgress, cancels_on_disconnect(Reply)
            ),
            Outcome = settle_disconnect(Outcome0, WorkerPid),
            case SessionId of
                undefined -> ok;
                _ -> ok = barrel_mcp_session:clear_in_flight(SessionId, RequestId)
            end,
            case Streaming of
                true ->
                    finish_progress_stream(Responder, Reply, RequestId, Outcome);
                false ->
                    deliver_tool_outcome(
                        Headers,
                        Responder,
                        Config,
                        Reply,
                        RequestId,
                        Outcome
                    )
            end
    end.

%% Legacy delivers both out of band on the session channel, so only a
%% modern request that opted in needs its response turned into a stream.
streams_notifications(_Reply, undefined, undefined) ->
    false;
streams_notifications(#{ctx := Ctx}, _Token, _Level) when Ctx =/= undefined ->
    barrel_mcp_ctx:is_modern(Ctx);
streams_notifications(_Reply, _Token, _Level) ->
    false.

%% 2026-07-28: the server "MUST treat a client disconnect as
%% cancellation of that request"
%% (2026-07-28/basic/patterns/cancellation.mdx:38). Through 2025-11-25:
%% "disconnection SHOULD NOT be interpreted as the client cancelling its
%% request" (2025-11-25/basic/transports.mdx:128).
cancels_on_disconnect(#{ctx := Ctx}) when Ctx =/= undefined ->
    barrel_mcp_ctx:is_modern(Ctx);
cancels_on_disconnect(_Reply) ->
    false.

%% Nobody left to answer, so stop the worker and use the outcome that
%% has no envelope.
settle_disconnect(disconnected, WorkerPid) ->
    _ =
        case is_pid(WorkerPid) andalso is_process_alive(WorkerPid) of
            true -> exit(WorkerPid, kill);
            false -> ok
        end,
    cancelled;
settle_disconnect(Outcome, _WorkerPid) ->
    Outcome.

%% `undefined' unless this request named a level in its `_meta'.
request_log_level(#{ctx := Ctx}) when Ctx =/= undefined ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        true -> barrel_mcp_ctx:log_level(Ctx);
        false -> undefined
    end;
request_log_level(_Reply) ->
    undefined.

start_progress_stream(false, _Headers, _Responder, _Config, _Reply) ->
    fun(_Envelope) -> ok end;
start_progress_stream(true, Headers, Responder, Config, Reply) ->
    Hdrs = reply_headers(
        Headers,
        Config,
        Reply,
        #{
            <<"content-type">> => <<"text/event-stream">>,
            <<"cache-control">> => <<"no-cache">>,
            %% Tell reverse proxies not to buffer, or progress arrives
            %% in one lump at the end.
            <<"x-accel-buffering">> => <<"no">>
        }
    ),
    stream_start(Responder, 200, Hdrs),
    fun(Envelope) ->
        _ = push_sse_data(Responder, Envelope),
        ok
    end.

%% The final response terminates the stream. A cancelled call has no
%% response to send, so the stream just ends.
%%
%% The status was committed when the stream opened, so an error that
%% would otherwise be pinned to a 4xx travels as a JSON-RPC error on a
%% 200 here. That is inherent to having started streaming.
finish_progress_stream(Responder, Reply, RequestId, cancelled) ->
    _ = Reply,
    _ = RequestId,
    stream_end(Responder);
finish_progress_stream(Responder, Reply, RequestId, Outcome) ->
    _ = push_sse_data(Responder, tool_outcome_envelope(Reply, RequestId, Outcome)),
    stream_end(Responder).

handle_long_running_call(
    Headers,
    Responder,
    Config,
    Reply,
    RequestId,
    ToolName,
    ProgressToken,
    Meta,
    Spawn,
    AuthInfo
) ->
    RequestCtx = maps:get(ctx, Reply),
    Owner = task_owner(RequestCtx),
    Params = maps:get(params, Reply, #{}),
    case barrel_mcp_tasks:create(Owner, ToolName, #{params => Params}) of
        {error, too_many_tasks} ->
            %% Refused at admission, and the caller is still waiting,
            %% so it is told rather than left to poll a task that was
            %% never created.
            reply_json(
                Headers,
                Responder,
                Config,
                200,
                barrel_mcp_protocol:error_response(
                    RequestId,
                    ?JSONRPC_INTERNAL_ERROR,
                    <<"Too many concurrent tasks">>
                )
            );
        {ok, TaskId} ->
            start_task_worker(
                {Headers, Responder, Config},
                Reply,
                #{
                    request_id => RequestId,
                    progress_token => ProgressToken,
                    meta => Meta,
                    spawn => Spawn,
                    auth_info => AuthInfo,
                    owner => Owner,
                    task_id => TaskId,
                    ctx => RequestCtx
                }
            )
    end.

start_task_worker({Headers, Responder, Config}, Reply, Work) ->
    #{
        request_id := RequestId,
        progress_token := ProgressToken,
        meta := Meta,
        spawn := Spawn,
        auth_info := AuthInfo,
        owner := Owner,
        task_id := TaskId,
        ctx := RequestCtx
    } = Work,
    SessionId = maps:get(session_id, Reply),
    {_Collector, Worker} = barrel_mcp_protocol:spawn_task_collector(
        Owner,
        TaskId,
        fun(Collector) ->
            Spawn(#{
                session_id => SessionId,
                request_id => RequestId,
                progress_token => ProgressToken,
                meta => Meta,
                emit_progress => emit_progress_fun(SessionId, ProgressToken),
                emit_log => emit_log_fun(Reply, SessionId),
                reply_to => Collector,
                auth_info => AuthInfo
            })
        end
    ),
    _ = barrel_mcp_tasks:set_worker(
        Owner,
        TaskId,
        #{worker => Worker, request_id => RequestId}
    ),
    Task =
        case barrel_mcp_tasks:get(Owner, TaskId, barrel_mcp_ctx:era(RequestCtx)) of
            {ok, T} -> T;
            _ -> #{<<"taskId">> => TaskId, <<"status">> => <<"working">>}
        end,
    Result = barrel_mcp_protocol:create_task_result(TaskId, Task, RequestCtx),
    Envelope = tool_success(Reply, RequestId, Result, #{}),
    Hdrs = reply_headers(
        Headers,
        Config,
        Reply,
        #{<<"content-type">> => <<"application/json">>}
    ),
    reply(Responder, 200, Hdrs, barrel_mcp_protocol:encode(Envelope)).

%% `tasks_available/1' and `task_owner/1' live in the protocol core so
%% stdio decides the same way this transport does.
tasks_available(undefined) -> false;
tasks_available(Ctx) -> barrel_mcp_protocol:tasks_enabled(Ctx).

task_owner(undefined) -> undefined;
task_owner(Ctx) -> barrel_mcp_protocol:task_owner(Ctx).

emit_progress_fun(undefined, _Token) ->
    fun(_, _, _) -> ok end;
emit_progress_fun(_Sid, undefined) ->
    fun(_, _, _) -> ok end;
emit_progress_fun(SessionId, Token) ->
    fun(Progress, Total, _Message) ->
        barrel_mcp_session:notify_progress(SessionId, Token, Progress, Total)
    end.

%% Modern era: there is no session channel, and the spec puts
%% request-scoped notifications on the response stream of the request
%% they relate to. The tool worker hands them back to the request
%% process, which writes them out ahead of the final response.
self_progress_fun(_Self, _RequestId, undefined) ->
    fun(_, _, _) -> ok end;
self_progress_fun(Self, RequestId, Token) ->
    fun(Progress, Total, Message) ->
        Self ! {tool_progress, RequestId, progress_params(Token, Progress, Total, Message)},
        ok
    end.

progress_params(Token, Progress, Total, Message) ->
    Base = #{<<"progressToken">> => Token, <<"progress">> => Progress},
    WithTotal =
        case Total of
            undefined -> Base;
            _ -> Base#{<<"total">> => Total}
        end,
    case Message of
        undefined -> WithTotal;
        <<>> -> WithTotal;
        _ -> WithTotal#{<<"message">> => Message}
    end.

progress_notification(Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/progress">>,
        <<"params">> => Params
    }.

%% Legacy logging stays on the session's SSE channel. A modern request
%% has no session, so it drops.
emit_log_fun(_Reply, undefined) ->
    fun(_, _, _) -> ok end;
emit_log_fun(_Reply, SessionId) ->
    fun(Level, Logger, Data) ->
        barrel_mcp:notify_log(SessionId, Level, Logger, Data)
    end.

%% "The server MUST NOT emit notifications/message for a request that
%% does not include this field" (2026-07-28/.../logging.mdx:64).
self_log_fun(_Self, _RequestId, undefined) ->
    fun(_, _, _) -> ok end;
self_log_fun(Self, RequestId, Requested) ->
    Floor = barrel_mcp_session:log_level_priority(Requested),
    fun(Level, Logger, Data) ->
        case barrel_mcp_session:log_level_priority(Level) of
            error ->
                ok;
            Prio when Prio >= Floor ->
                Self ! {tool_log, RequestId, log_params(Level, Logger, Data)},
                ok;
            _ ->
                ok
        end
    end.

log_params(Level, Logger, Data) ->
    Base = #{<<"level">> => level_to_binary(Level), <<"data">> => Data},
    case Logger of
        undefined -> Base;
        _ -> Base#{<<"logger">> => Logger}
    end.

level_to_binary(L) when is_atom(L) -> atom_to_binary(L, utf8);
level_to_binary(L) when is_binary(L) -> L.

log_notification(Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/message">>,
        <<"params">> => Params
    }.

%% `OnEmit' takes each request-scoped notification envelope. Legacy
%% passes a sink: it delivers them on the session channel instead.
wait_for_tool(RequestId, Timeout, OnEmit, CancelOnDisconnect) ->
    Deadline = progress_deadline(Timeout),
    Outcome = collect_tool_outcome(RequestId, Deadline, OnEmit, CancelOnDisconnect),
    case Outcome of
        cancelled ->
            cancelled;
        disconnected ->
            disconnected;
        timeout ->
            timeout;
        _ ->
            %% Cancellation race: prefer a pending cancel.
            receive
                {cancelled, RequestId} -> cancelled
            after 50 -> Outcome
            end
    end.

%% Progress messages must not extend the tool's deadline, so the
%% remaining budget is recomputed on every hop rather than restarting
%% the receive timeout.
progress_deadline(infinity) ->
    infinity;
progress_deadline(Timeout) when is_integer(Timeout) ->
    erlang:monotonic_time(millisecond) + Timeout.

progress_remaining(infinity) ->
    infinity;
progress_remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

collect_tool_outcome(RequestId, Deadline, OnEmit, CancelOnDisconnect) ->
    Outcome =
        receive
            %% Left in the mailbox otherwise, so a legacy request keeps
            %% running. The exit signal is the same event: this process
            %% is linked to the connection.
            mcp_disconnect when CancelOnDisconnect ->
                disconnected;
            {'EXIT', _Conn, _Reason} when CancelOnDisconnect ->
                disconnected;
            {tool_progress, RequestId, Params} ->
                OnEmit(progress_notification(Params)),
                notified;
            {tool_log, RequestId, Params} ->
                OnEmit(log_notification(Params)),
                notified;
            {tool_result, RequestId, Result} ->
                {result, Result, #{}};
            {tool_result_meta, RequestId, Result, Meta} ->
                {result, Result, Meta};
            {tool_structured, RequestId, Data, Content} ->
                {structured, Data, Content, #{}};
            {tool_structured_meta, RequestId, Data, Content, Meta} ->
                {structured, Data, Content, Meta};
            {tool_input_required, RequestId, Requests, State} ->
                {input_required, Requests, State};
            {tool_error, RequestId, Content} ->
                {tool_error, Content, #{}};
            {tool_error_meta, RequestId, Content, Meta} ->
                {tool_error, Content, Meta};
            {tool_failed, RequestId, Reason} ->
                {failed, Reason};
            {tool_validation_failed, RequestId, Errors} ->
                {validation_failed, Errors};
            {cancelled, RequestId} ->
                cancelled
        after progress_remaining(Deadline) ->
            timeout
        end,
    case Outcome of
        notified -> collect_tool_outcome(RequestId, Deadline, OnEmit, CancelOnDisconnect);
        _ -> Outcome
    end.

%% Turn a tool outcome into the JSON-RPC envelope for it. Split out of
%% the reply so the plain and the streaming path produce byte-identical
%% envelopes. `cancelled' has no envelope: there is nothing to answer.
tool_outcome_envelope(Reply, RequestId, {input_required, Requests, State}) ->
    barrel_mcp_protocol:input_required_envelope(
        maps:get(plan, Reply, #{}), Requests, State, RequestId
    );
tool_outcome_envelope(Reply, RequestId, {result, Result, Meta}) ->
    Content = barrel_mcp_protocol:format_tool_result_external(Result),
    tool_success(Reply, RequestId, #{<<"content">> => Content}, Meta);
tool_outcome_envelope(Reply, RequestId, {structured, Data, Content, Meta}) ->
    tool_success(
        Reply,
        RequestId,
        #{
            <<"content">> => Content,
            <<"structuredContent">> => Data
        },
        Meta
    );
tool_outcome_envelope(Reply, RequestId, {tool_error, Content, Meta}) ->
    %% `CallToolResult.content' is an array in every revision.
    tool_success(
        Reply,
        RequestId,
        #{
            <<"content">> => barrel_mcp_protocol:format_tool_result_external(Content),
            <<"isError">> => true
        },
        Meta
    );
tool_outcome_envelope(Reply, RequestId, {validation_failed, Errors}) ->
    Msg = iolist_to_binary(io_lib:format("Invalid tool input: ~p", [Errors])),
    tool_success(
        Reply,
        RequestId,
        #{
            <<"content">> =>
                [#{<<"type">> => <<"text">>, <<"text">> => Msg}],
            <<"isError">> => true
        },
        #{}
    );
tool_outcome_envelope(Reply, RequestId, {failed, _Reason}) ->
    barrel_mcp_protocol:error_response(
        RequestId,
        internal_error_code(Reply),
        <<"Internal tool error">>
    );
tool_outcome_envelope(Reply, RequestId, timeout) ->
    barrel_mcp_protocol:error_response(
        RequestId,
        internal_error_code(Reply),
        <<"Tool timed out">>
    ).

%% `-32000' is in the sub-range 2026-07-28 reserved as legacy and told
%% new implementations not to use (basic/index.mdx:117).
internal_error_code(#{ctx := Ctx}) when Ctx =/= undefined ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        true -> ?JSONRPC_INTERNAL_ERROR;
        false -> ?MCP_TOOL_ERROR
    end;
internal_error_code(_Reply) ->
    ?MCP_TOOL_ERROR.

%% A modern result is decorated here rather than in the protocol core,
%% because this envelope is built by the transport.
tool_success(Reply, RequestId, Result, Meta) ->
    barrel_mcp_protocol:finalize(
        barrel_mcp_protocol:success_response(RequestId, Result, Meta),
        maps:get(ctx, Reply)
    ).

deliver_tool_outcome(Headers, Responder, Config, Reply, _RequestId, cancelled) ->
    Hdrs = reply_headers(Headers, Config, Reply, #{}),
    reply(Responder, 200, Hdrs, <<>>);
deliver_tool_outcome(Headers, Responder, Config, Reply, RequestId, Outcome) ->
    Envelope = tool_outcome_envelope(Reply, RequestId, Outcome),
    Hdrs = reply_headers(
        Headers,
        Config,
        Reply,
        #{<<"content-type">> => <<"application/json">>}
    ),
    %% A tool call can end in one of the errors the transport binding
    %% pins to a status, notably -32021 when a handler asks for a
    %% capability the client never declared. Ordinary tool failures are
    %% not in that table and stay 200, as before.
    reply(
        Responder,
        modern_status(Envelope),
        Hdrs,
        barrel_mcp_protocol:encode(Envelope)
    ).

%% CORS plus the session echo, which a modern reply never carries.
reply_headers(Headers, Config, Reply, Extra) ->
    add_session_header(
        cors_headers(Headers, Config, Extra),
        maps:get(session_id, Reply)
    ).

reply_jsonrpc_error(Headers, Responder, Config, SessionId, Status, Id, Code, Message) ->
    Resp = barrel_mcp_protocol:error_response(Id, Code, Message),
    Json = barrel_mcp_protocol:encode(Resp),
    Hdrs = add_session_header(
        cors_headers(
            Headers,
            Config,
            #{<<"content-type">> => <<"application/json">>}
        ),
        SessionId
    ),
    reply(Responder, Status, Hdrs, Json).

%%====================================================================
%% Session resolution / protocol version
%%====================================================================

lookup_session(_Headers, _Config, false, _Method) ->
    {ok, undefined};
%% Discovery must be reachable before anything else, so it neither
%% requires a session nor mints one. That is what lets a dual-era
%% client probe with `server/discover' the way the stdio binding
%% describes, over HTTP too.
lookup_session(_Headers, _Config, true, <<"server/discover">>) ->
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

%% What this connection settled on, preferring the header the client
%% sends on every post-initialize request and falling back to what the
%% session recorded at the handshake.
negotiated_version(Headers, SessionId) ->
    case header(<<"mcp-protocol-version">>, Headers, undefined) of
        Version when is_binary(Version) ->
            Version;
        undefined when is_binary(SessionId) ->
            case barrel_mcp_session:get_protocol_version(SessionId) of
                {ok, Version} -> Version;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

validate_protocol_version(_Headers, _Sid, <<"initialize">>) ->
    ok;
validate_protocol_version(Headers, SessionId, _Method) ->
    case header(<<"mcp-protocol-version">>, Headers, undefined) of
        undefined ->
            ok;
        Version ->
            case lists:member(Version, ?MCP_SUPPORTED_VERSIONS) of
                true ->
                    case SessionId of
                        undefined ->
                            ok;
                        _ ->
                            _ = barrel_mcp_session:set_protocol_version(
                                SessionId, Version
                            ),
                            ok
                    end;
                false ->
                    {error,
                        iolist_to_binary([
                            <<"Bad MCP-Protocol-Version: ">>,
                            Version,
                            <<". Supported: ">>,
                            lists:join(<<", ">>, ?MCP_SUPPORTED_VERSIONS)
                        ])}
            end
    end.

maybe_capture_initialize_version(
    SessionId,
    <<"initialize">>,
    #{
        <<"result">> :=
            #{<<"protocolVersion">> := Version}
    }
) when
    is_binary(SessionId)
->
    _ = barrel_mcp_session:set_protocol_version(SessionId, Version),
    ok;
maybe_capture_initialize_version(_, _, _) ->
    ok.

%%====================================================================
%% Streamable transport — GET (long-lived SSE) and DELETE
%%====================================================================

stream_get_sse(Headers, Responder, Config) ->
    with_authenticated(
        Headers,
        Responder,
        Config,
        fun() -> stream_get_sse_authed(Headers, Responder, Config) end
    ).

%% Only reached with sessions on: `dispatch/6' answers 405 otherwise.
stream_get_sse_authed(Headers, Responder, Config) ->
    case session_header(Headers) of
        undefined ->
            reply(
                Responder,
                400,
                cors_headers(Headers, Config, #{}),
                json_encode(#{<<"error">> => <<"Mcp-Session-Id header required">>})
            );
        SessionId ->
            stream_get_sse_session(Headers, Responder, Config, SessionId)
    end.

stream_get_sse_session(Headers, Responder, Config, SessionId) ->
    case barrel_mcp_session:get(SessionId) of
        {ok, _Session} ->
            Hdrs = add_session_header(
                cors_headers(
                    Headers,
                    Config,
                    #{
                        <<"content-type">> => <<"text/event-stream">>,
                        <<"cache-control">> => <<"no-cache">>,
                        <<"connection">> => <<"keep-alive">>
                    }
                ),
                SessionId
            ),
            stream_start(Responder, 200, Hdrs),
            replay_sse_events(
                Responder,
                SessionId,
                header(<<"last-event-id">>, Headers, undefined)
            ),
            _ = barrel_mcp_session:set_sse_pid(SessionId, self()),
            sse_loop(Responder, SessionId);
        {error, not_found} ->
            reply(
                Responder,
                404,
                cors_headers(Headers, Config, #{}),
                json_encode(#{<<"error">> => <<"Unknown Mcp-Session-Id">>})
            )
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
        {'EXIT', _Conn, _Reason} ->
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
    _ =
        (try
            barrel_mcp_session:set_sse_pid(SessionId, undefined)
        catch
            _:_ -> ok
        end),
    _ = stream_end(Responder),
    ok.

stream_delete(Headers, Responder, Config) ->
    with_authenticated(
        Headers,
        Responder,
        Config,
        fun() -> stream_delete_authed(Headers, Responder, Config) end
    ).

stream_delete_authed(Headers, Responder, Config) ->
    case session_header(Headers) of
        undefined ->
            reply(
                Responder,
                400,
                cors_headers(Headers, Config, #{}),
                json_encode(#{<<"error">> => <<"Mcp-Session-Id header required">>})
            );
        SessionId ->
            case barrel_mcp_session:get(SessionId) of
                {ok, _} ->
                    barrel_mcp_session:delete(SessionId),
                    reply(Responder, 204, cors_headers(Headers, Config, #{}), <<>>);
                {error, not_found} ->
                    reply(
                        Responder,
                        404,
                        cors_headers(Headers, Config, #{}),
                        json_encode(#{<<"error">> => <<"Unknown Mcp-Session-Id">>})
                    )
            end
    end.

%%====================================================================
%% HTTP+SSE transport (2024-11-05)
%%====================================================================

%% "When a client connects, the server MUST send an `endpoint' event
%% containing a URI for the client to use for sending messages"
%% (2024-11-05/basic/transports.mdx:67).
%%
%% The URI carries the session id, which is crypto-random and so the
%% capability for this connection. It is bound to the principal that
%% opened it, so holding the URL is not on its own enough to post.
legacy_sse_open(Headers, Responder, Config) ->
    with_auth_info(Headers, Responder, Config, fun(AuthInfo) ->
        {ok, SessionId} = barrel_mcp_session:create(#{}),
        _ = barrel_mcp_session:set_principal(SessionId, principal_of(AuthInfo)),
        Hdrs = cors_headers(Headers, Config, #{
            <<"content-type">> => <<"text/event-stream">>,
            <<"cache-control">> => <<"no-cache">>,
            <<"connection">> => <<"keep-alive">>,
            <<"x-accel-buffering">> => <<"no">>
        }),
        stream_start(Responder, 200, Hdrs),
        _ = stream_chunk(Responder, endpoint_event(SessionId, Config)),
        _ = barrel_mcp_session:set_sse_pid(SessionId, self()),
        try
            sse_loop(Responder, SessionId)
        after
            %% The stream is the session, and the last write on the way
            %% out goes to a socket the peer has already closed. Letting
            %% that raise past here would leak the session and leave its
            %% endpoint answering.
            barrel_mcp_session:delete(SessionId)
        end
    end).

endpoint_event(SessionId, Config) ->
    Path = maps:get(sse_message_path, Config),
    iolist_to_binary([
        <<"event: endpoint\ndata: ">>,
        Path,
        <<"?sessionId=">>,
        SessionId,
        <<"\n\n">>
    ]).

%% "All subsequent client messages MUST be sent as HTTP POST requests to
%% this endpoint" (transports.mdx:67), and the answer goes back on the
%% stream rather than in this response.
legacy_sse_post(RawPath, Headers, Body, Responder, Config) ->
    with_auth_info(Headers, Responder, Config, fun(AuthInfo) ->
        case legacy_session_of(RawPath, AuthInfo) of
            {error, Status, Message} ->
                reply(
                    Responder,
                    Status,
                    cors_headers(Headers, Config, #{}),
                    json_encode(#{<<"error">> => Message})
                );
            {ok, SessionId} ->
                legacy_dispatch(SessionId, Headers, Body, Responder, Config, AuthInfo)
        end
    end).

legacy_session_of(RawPath, AuthInfo) ->
    case query_param(<<"sessionId">>, RawPath) of
        undefined ->
            {error, 400, <<"sessionId required">>};
        SessionId ->
            case barrel_mcp_session:get_principal(SessionId) of
                {error, not_found} ->
                    {error, 404, <<"Unknown sessionId">>};
                {ok, Principal} ->
                    case Principal =:= principal_of(AuthInfo) of
                        %% Same answer as an unknown id: whoever holds
                        %% the URL learns nothing about whose it is.
                        false -> {error, 404, <<"Unknown sessionId">>};
                        true -> {ok, SessionId}
                    end
            end
    end.

legacy_dispatch(SessionId, Headers, Body, Responder, Config, AuthInfo) ->
    case barrel_mcp_protocol:decode(Body) of
        {error, _} ->
            push_legacy(
                SessionId,
                barrel_mcp_protocol:error_response(
                    null, ?JSONRPC_PARSE_ERROR, <<"Parse error">>
                )
            ),
            reply(Responder, 202, cors_headers(Headers, Config, #{}), <<>>);
        {ok, Request} ->
            ProtocolState = #{
                auth_info => AuthInfo,
                protocol_version => negotiated_version(Headers, SessionId),
                session_id => SessionId
            },
            Message =
                case Request of
                    M when is_map(M) -> with_auth(M, AuthInfo);
                    Other -> Other
                end,
            _ = legacy_answer(SessionId, Message, ProtocolState),
            reply(Responder, 202, cors_headers(Headers, Config, #{}), <<>>)
    end.

legacy_answer(SessionId, Message, ProtocolState) ->
    case barrel_mcp_protocol:handle(Message, ProtocolState) of
        no_response ->
            ok;
        {async, Plan} ->
            %% Off this request: the POST answers 202 straight away and
            %% the result goes out on the stream whenever it is ready.
            AuthInfo = maps:get(auth_info, ProtocolState),
            _ = spawn(fun() ->
                Response = barrel_mcp_protocol:drive_async_plan(Plan, 60000, AuthInfo),
                push_legacy(SessionId, Response)
            end),
            ok;
        {subscribe, _Sub} ->
            %% Modern-only, and this transport predates it.
            ok;
        Response ->
            _ = maybe_capture_initialize_version(
                SessionId, method_of(Message), Response
            ),
            push_legacy(SessionId, Response)
    end.

method_of(Message) when is_map(Message) -> maps:get(<<"method">>, Message, <<>>);
method_of(_Message) -> <<>>.

push_legacy(SessionId, Response) ->
    case barrel_mcp_session:get_sse_pid(SessionId) of
        {ok, Pid} when is_pid(Pid) ->
            Pid ! {sse_send_message, Response},
            ok;
        _ ->
            ok
    end.

principal_of(AuthInfo) when is_map(AuthInfo) ->
    maps:get(principal, AuthInfo, anonymous);
principal_of(_AuthInfo) ->
    anonymous.

query_param(Name, RawPath) ->
    case binary:split(RawPath, <<"?">>) of
        [_Path, Query] -> find_param(Name, binary:split(Query, <<"&">>, [global]));
        _ -> undefined
    end.

find_param(_Name, []) ->
    undefined;
find_param(Name, [Pair | Rest]) ->
    case binary:split(Pair, <<"=">>) of
        [Name, Value] -> Value;
        _ -> find_param(Name, Rest)
    end.

%%====================================================================
%% SSE helpers
%%====================================================================

%% Single-event SSE response to a POST: open, send the result, close.
stream_sse_response(Headers, Responder, Config, SessionId, Result) ->
    Hdrs = add_session_header(
        cors_headers(
            Headers,
            Config,
            #{
                <<"content-type">> => <<"text/event-stream">>,
                <<"cache-control">> => <<"no-cache">>
            }
        ),
        SessionId
    ),
    stream_start(Responder, 200, Hdrs),
    %% `SessionId' is `undefined' on the modern path and only there, and
    %% 2026-07-28 has no resumability to carry an `id:' for.
    _ =
        case SessionId of
            undefined -> push_sse_data(Responder, Result);
            _ -> push_sse_event(Responder, generate_event_id(), Result)
        end,
    stream_end(Responder).

%% Modern streams carry no event ids: 2026-07-28 removed SSE
%% resumability, so there is nothing for a client to resume from.
push_sse_data(Responder, Data) ->
    stream_chunk(
        Responder,
        iolist_to_binary([<<"data: ">>, json_encode(Data), <<"\n\n">>])
    ).

push_sse_event(Responder, EventId, Data) ->
    Json = json_encode(Data),
    EventData = iolist_to_binary([
        <<"id: ">>,
        EventId,
        <<"\n">>,
        <<"data: ">>,
        Json,
        <<"\n\n">>
    ]),
    stream_chunk(Responder, EventData).

generate_event_id() ->
    integer_to_binary(erlang:system_time(microsecond)).

replay_sse_events(_Responder, _SessionId, undefined) ->
    ok;
replay_sse_events(Responder, SessionId, LastId) ->
    case barrel_mcp_session:events_since(SessionId, LastId) of
        {ok, Events} ->
            lists:foreach(
                fun({EventId, Payload}) ->
                    _ = push_sse_event(Responder, EventId, Payload)
                end,
                Events
            ),
            ok;
        truncated ->
            _ = push_sse_event(
                Responder,
                generate_event_id(),
                #{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"method">> => <<"notifications/replay_truncated">>,
                    <<"params">> => #{}
                }
            ),
            ok;
        {error, not_found} ->
            ok
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
        true ->
            ok;
        false ->
            {error, <<
                "Accept header must include both application/json"
                " and text/event-stream"
            >>}
    end.

wants_sse_response(Headers) ->
    Accept = header(<<"accept">>, Headers, <<>>),
    HasJson = binary:match(Accept, <<"application/json">>) =/= nomatch,
    HasSse = binary:match(Accept, <<"text/event-stream">>) =/= nomatch,
    case {HasJson, HasSse} of
        {false, true} ->
            true;
        {true, true} ->
            SsePos = match_pos(Accept, <<"text/event-stream">>),
            JsonPos = match_pos(Accept, <<"application/json">>),
            SsePos < JsonPos;
        _ ->
            false
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
    _ = code:ensure_loaded(Provider),
    ProviderOpts = maps:get(provider_opts, AuthOpts, #{}),
    ProviderState =
        case erlang:function_exported(Provider, init, 1) of
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

%% Run `Fun' only if the request passes the configured auth provider.
%% Used by the GET (SSE) and DELETE verbs so they enforce the same
%% credential as POST instead of trusting the session id alone. With
%% `barrel_mcp_auth_none' this admits every request unchanged.
%% As `with_authenticated/4', but hands the caller what it authenticated
%% as: the 2024-11-05 transport binds its endpoint to that identity.
with_auth_info(Headers, Responder, Config, Fun) ->
    AuthConfig = maps:get(auth_config, Config, #{provider => barrel_mcp_auth_none}),
    AuthRequest = #{headers => extract_headers(Headers, AuthConfig)},
    case authenticate(AuthConfig, AuthRequest) of
        {ok, AuthInfo} -> Fun(AuthInfo);
        {error, Reason} -> auth_error(Headers, Responder, AuthConfig, Reason)
    end.

with_authenticated(Headers, Responder, Config, Fun) ->
    AuthConfig = maps:get(
        auth_config,
        Config,
        #{provider => barrel_mcp_auth_none}
    ),
    AuthRequest = #{headers => extract_headers(Headers, AuthConfig)},
    case authenticate(AuthConfig, AuthRequest) of
        {ok, _AuthInfo} ->
            Fun();
        {error, Reason} ->
            auth_error(Headers, Responder, AuthConfig, Reason)
    end.

auth_error(Headers, Responder, AuthConfig, Reason) ->
    {StatusCode, AuthHeaders, Body} =
        barrel_mcp_auth:challenge_response(AuthConfig, Reason),
    %% AuthHeaders is a map; merge with CORS and emit as a list.
    Merged = maps:merge(
        AuthHeaders,
        cors_headers(Headers, #{auth_config => AuthConfig}, #{})
    ),
    reply(Responder, StatusCode, Merged, Body).

extract_headers(Headers, AuthConfig) ->
    Names =
        case AuthConfig of
            undefined ->
                [<<"authorization">>, <<"x-api-key">>];
            _ ->
                case barrel_mcp_auth:auth_headers(AuthConfig) of
                    [] -> [<<"authorization">>, <<"x-api-key">>];
                    Decl -> Decl
                end
        end,
    lists:foldl(
        fun(Name, Acc) ->
            case header(Name, Headers, undefined) of
                undefined -> Acc;
                Value -> Acc#{Name => Value}
            end
        end,
        #{},
        Names
    ).

%% The user-facing `resource_metadata' option processing.
normalize_resource_metadata(undefined) ->
    undefined;
normalize_resource_metadata(#{resource := ResourceUrl} = M) ->
    Doc = maps:without([metadata_url], M),
    MetaUrl =
        case maps:get(metadata_url, M, undefined) of
            undefined -> derive_prm_url(ResourceUrl);
            Explicit when is_binary(Explicit) -> Explicit
        end,
    #{document => Doc, url => MetaUrl}.

derive_prm_url(Resource) when is_binary(Resource) ->
    case uri_string:parse(Resource) of
        #{scheme := Scheme, host := Host} = Parsed ->
            PortPart =
                case maps:get(port, Parsed, undefined) of
                    undefined -> <<>>;
                    P -> iolist_to_binary([<<":">>, integer_to_binary(P)])
                end,
            iolist_to_binary([
                Scheme,
                <<"://">>,
                Host,
                PortPart,
                <<"/.well-known/oauth-protected-resource">>
            ]);
        _ ->
            <<Resource/binary, "/.well-known/oauth-protected-resource">>
    end.

inject_resource_metadata_url(AuthConfig, undefined) ->
    AuthConfig;
inject_resource_metadata_url(#{provider_state := State} = AuthConfig, #{url := Url}) when
    is_map(State)
->
    AuthConfig#{provider_state => State#{resource_metadata_url => Url}};
inject_resource_metadata_url(AuthConfig, _) ->
    AuthConfig.

%%====================================================================
%% CORS
%%====================================================================

cors_headers(Headers, Config, Extra) ->
    BaseAllowHeaders =
        [
            <<"content-type">>,
            <<"accept">>,
            <<"mcp-session-id">>,
            <<"mcp-protocol-version">>,
            <<"last-event-id">>,
            <<"mcp-method">>,
            <<"mcp-name">>
        ] ++
            %% `Access-Control-Allow-Headers' has no prefix form, so
            %% every mirrored parameter has to be named. A browser
            %% client would otherwise fail preflight on any tool using
            %% `x-mcp-header'.
            barrel_mcp_registry:param_header_names(),
    AuthHeaders =
        case maps:get(auth_config, Config, undefined) of
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
    WithOrigin =
        case header(<<"origin">>, Headers, undefined) of
            undefined ->
                Base;
            Origin ->
                Base#{
                    <<"access-control-allow-origin">> => Origin,
                    <<"vary">> => <<"Origin">>
                }
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
    [
        #{scheme => <<"http">>, host => <<"localhost">>, port => any},
        #{scheme => <<"http">>, host => <<"127.0.0.1">>, port => any},
        #{scheme => <<"http">>, host => <<"[::1]">>, port => any}
    ].

parse_origin(<<"null">>) ->
    null;
parse_origin(Bin) when is_binary(Bin) ->
    case uri_string:parse(Bin) of
        #{scheme := Scheme, host := Host} = U ->
            #{
                scheme => to_bin(Scheme),
                host => to_bin(Host),
                port => maps:get(port, U, any)
            };
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

match_origin(_Origin, any) ->
    ok;
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

origin_matches(null, _) ->
    false;
origin_matches(#{scheme := S, host := H, port := P}, Parsed) ->
    SOk = (S =:= undefined) orelse (S =:= maps:get(scheme, Parsed)),
    HOk = (H =:= maps:get(host, Parsed)),
    POk = (P =:= any) orelse (P =:= maps:get(port, Parsed)),
    SOk andalso HOk andalso POk;
origin_matches(_, _) ->
    false.

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
add_session_header(Headers, SessionId) -> Headers#{<<"mcp-session-id">> => SessionId}.

%% Case-insensitive header lookup over a `[{binary(), binary()}]' list.
header(Name, Headers, Default) ->
    Lower = string:lowercase(Name),
    case
        lists:search(
            fun({K, _}) -> string:lowercase(to_bin(K)) =:= Lower end,
            Headers
        )
    of
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
