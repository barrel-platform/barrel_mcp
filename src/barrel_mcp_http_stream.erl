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

%% Cowboy loop handler callbacks
-export([init/2, info/3, terminate/3]).

-define(STREAM_LISTENER, barrel_mcp_http_stream_listener).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the Streamable HTTP server.
-spec start(Opts) -> {ok, pid()} | {error, term()} when
    Opts :: #{
        port => pos_integer(),
        ip => inet:ip_address(),
        auth => map(),
        session_enabled => boolean(),
        ssl => map()
    }.
start(Opts) ->
    Port = maps:get(port, Opts, 9090),
    Ip = maps:get(ip, Opts, {0, 0, 0, 0}),
    SessionEnabled = maps:get(session_enabled, Opts, true),

    %% Ensure session manager is started if sessions are enabled
    _ = case SessionEnabled of
        true ->
            ensure_session_manager();
        false ->
            ok
    end,

    %% Initialize authentication
    AuthConfig = init_auth(maps:get(auth, Opts, #{})),

    %% Handler state
    HandlerState = #{
        auth_config => AuthConfig,
        session_enabled => SessionEnabled
    },

    Routes = [
        {'_', [
            {"/mcp", ?MODULE, HandlerState},
            {"/", ?MODULE, HandlerState}
        ]}
    ],
    Dispatch = cowboy_router:compile(Routes),

    %% Start with TLS or clear depending on ssl option
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
    case Method of
        <<"POST">> ->
            handle_post(Req0, State);
        <<"GET">> ->
            handle_get_sse(Req0, State);
        <<"DELETE">> ->
            handle_delete(Req0, State);
        <<"OPTIONS">> ->
            handle_options(Req0, State);
        _ ->
            Req = cowboy_req:reply(405, #{
                <<"content-type">> => <<"application/json">>,
                <<"allow">> => <<"POST, GET, DELETE, OPTIONS">>
            }, <<"{\"error\":\"Method not allowed\"}">>, Req0),
            {ok, Req, State}
    end.

info(session_terminated, Req, State) ->
    %% Session was terminated, close the SSE stream
    {stop, Req, State};

info({sse_event, EventId, Data}, Req, State) ->
    %% Send SSE event
    send_sse_event(Req, EventId, Data),
    {ok, Req, State};

info(_Info, Req, State) ->
    {ok, Req, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%%====================================================================
%% HTTP Method Handlers
%%====================================================================

handle_post(Req0, State) ->
    %% Validate Accept header
    case validate_accept_header(Req0) of
        {error, Reason} ->
            Req = cowboy_req:reply(406, cors_headers(),
                json_encode(#{<<"error">> => Reason}), Req0),
            {ok, Req, State};
        ok ->
            %% Authenticate
            AuthConfig = maps:get(auth_config, State, #{provider => barrel_mcp_auth_none}),
            Headers = extract_headers(Req0),
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

    %% Get or create session
    {SessionId, State1} = case SessionEnabled of
        true ->
            get_or_create_session(Req0, State);
        false ->
            {undefined, State}
    end,

    %% Update session activity
    _ = case SessionId of
        undefined -> ok;
        _ -> barrel_mcp_session:update_activity(SessionId)
    end,

    %% Read and process request body
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    case barrel_mcp_protocol:decode(Body) of
        {ok, Request} ->
            %% Add auth info to request context
            AuthInfo = maps:get(auth_info, State1, undefined),
            RequestWithAuth = case AuthInfo of
                undefined -> Request;
                _ -> Request#{<<"_auth">> => AuthInfo}
            end,

            %% Handle the MCP request
            case barrel_mcp_protocol:handle(RequestWithAuth) of
                no_response ->
                    %% Notification - return 204 No Content
                    ResponseHeaders = add_session_header(cors_headers(), SessionId),
                    Req2 = cowboy_req:reply(204, ResponseHeaders, <<>>, Req1),
                    {ok, Req2, State1};
                Result ->
                    %% Check if client accepts SSE
                    case wants_sse_response(Req1) of
                        true ->
                            %% Stream response as SSE
                            stream_sse_response(Req1, State1, SessionId, Result);
                        false ->
                            %% Return JSON response
                            ResponseJson = barrel_mcp_protocol:encode(Result),
                            ResponseHeaders = add_session_header(
                                maps:merge(#{<<"content-type">> => <<"application/json">>}, cors_headers()),
                                SessionId
                            ),
                            Req2 = cowboy_req:reply(200, ResponseHeaders, ResponseJson, Req1),
                            {ok, Req2, State1}
                    end
            end;
        {error, parse_error} ->
            ErrorResponse = barrel_mcp_protocol:error_response(
                null, -32700, <<"Parse error">>
            ),
            ResponseJson = barrel_mcp_protocol:encode(ErrorResponse),
            ResponseHeaders = add_session_header(
                maps:merge(#{<<"content-type">> => <<"application/json">>}, cors_headers()),
                SessionId
            ),
            Req2 = cowboy_req:reply(400, ResponseHeaders, ResponseJson, Req1),
            {ok, Req2, State1}
    end.

handle_get_sse(Req0, State) ->
    %% GET requests open an SSE stream for server-to-client notifications
    %% This requires a valid session
    SessionEnabled = maps:get(session_enabled, State, true),

    case SessionEnabled of
        false ->
            Req = cowboy_req:reply(400, cors_headers(),
                json_encode(#{<<"error">> => <<"Sessions not enabled">>}), Req0),
            {ok, Req, State};
        true ->
            case get_session_from_request(Req0) of
                undefined ->
                    Req = cowboy_req:reply(400, cors_headers(),
                        json_encode(#{<<"error">> => <<"Mcp-Session-Id header required">>}), Req0),
                    {ok, Req, State};
                SessionId ->
                    case barrel_mcp_session:get(SessionId) of
                        {ok, _Session} ->
                            %% Open SSE stream
                            ResponseHeaders = add_session_header(#{
                                <<"content-type">> => <<"text/event-stream">>,
                                <<"cache-control">> => <<"no-cache">>,
                                <<"connection">> => <<"keep-alive">>
                            }, SessionId),
                            ResponseHeaders1 = maps:merge(ResponseHeaders, cors_headers()),
                            Req = cowboy_req:stream_reply(200, ResponseHeaders1, Req0),
                            %% Enter loop mode to handle SSE events
                            {cowboy_loop, Req, State#{sse_session => SessionId}};
                        {error, not_found} ->
                            Req = cowboy_req:reply(404, cors_headers(),
                                json_encode(#{<<"error">> => <<"Session not found">>}), Req0),
                            {ok, Req, State}
                    end
            end
    end.

handle_delete(Req0, State) ->
    %% DELETE terminates a session
    case get_session_from_request(Req0) of
        undefined ->
            Req = cowboy_req:reply(400, cors_headers(),
                json_encode(#{<<"error">> => <<"Mcp-Session-Id header required">>}), Req0),
            {ok, Req, State};
        SessionId ->
            barrel_mcp_session:delete(SessionId),
            Req = cowboy_req:reply(204, cors_headers(), <<>>, Req0),
            {ok, Req, State}
    end.

handle_options(Req0, State) ->
    Req = cowboy_req:reply(204, cors_headers(), <<>>, Req0),
    {ok, Req, State}.

%%====================================================================
%% SSE Helpers
%%====================================================================

stream_sse_response(Req0, State, SessionId, Result) ->
    %% Start SSE stream
    ResponseHeaders = add_session_header(#{
        <<"content-type">> => <<"text/event-stream">>,
        <<"cache-control">> => <<"no-cache">>
    }, SessionId),
    ResponseHeaders1 = maps:merge(ResponseHeaders, cors_headers()),
    Req = cowboy_req:stream_reply(200, ResponseHeaders1, Req0),

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

%%====================================================================
%% Session Helpers
%%====================================================================

get_or_create_session(Req, State) ->
    case get_session_from_request(Req) of
        undefined ->
            %% Create new session
            {ok, SessionId} = barrel_mcp_session:create(#{}),
            {SessionId, State#{session_id => SessionId}};
        SessionId ->
            case barrel_mcp_session:get(SessionId) of
                {ok, _} ->
                    {SessionId, State#{session_id => SessionId}};
                {error, not_found} ->
                    %% Session expired, create new one
                    {ok, NewSessionId} = barrel_mcp_session:create(#{}),
                    {NewSessionId, State#{session_id => NewSessionId}}
            end
    end.

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
    Headers = maps:merge(AuthHeaders, cors_headers()),
    Req = cowboy_req:reply(StatusCode, Headers, Body, Req0),
    {ok, Req, State}.

extract_headers(Req) ->
    HeaderNames = [<<"authorization">>, <<"x-api-key">>],
    lists:foldl(fun(Name, Acc) ->
        case cowboy_req:header(Name, Req) of
            undefined -> Acc;
            Value -> Acc#{Name => Value}
        end
    end, #{}, HeaderNames).

%%====================================================================
%% CORS
%%====================================================================

cors_headers() ->
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-methods">> => <<"POST, GET, DELETE, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"content-type, authorization, x-api-key, mcp-session-id, accept">>,
        <<"access-control-expose-headers">> => <<"www-authenticate, mcp-session-id">>
    }.

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
