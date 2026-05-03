%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc HTTP transport for MCP using Cowboy.
%%%
%%% Implements a Cowboy handler for HTTP-based MCP communication.
%%% Supports pluggable authentication via barrel_mcp_auth.
%%%
%%% == Authentication Options ==
%%%
%%% The `auth' option is a map with:
%%% <ul>
%%%   <li>`provider' - Auth provider module (default: barrel_mcp_auth_none)</li>
%%%   <li>`provider_opts' - Options passed to provider init</li>
%%%   <li>`required_scopes' - List of required scopes</li>
%%% </ul>
%%%
%%% @see barrel_mcp_auth
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http).

-behaviour(cowboy_handler).

%% API
-export([
    start/1,
    stop/0
]).

%% Cowboy callbacks
-export([init/2]).

-define(HTTP_LISTENER, barrel_mcp_http_listener).

%%====================================================================
%% API
%%====================================================================

%% @doc Start HTTP server for MCP.
%%
%% Same security defaults as `barrel_mcp_http_stream':
%% binds to `127.0.0.1' by default, requires explicit
%% `allowed_origins' for non-loopback binds.
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Opts) ->
    Port = maps:get(port, Opts, 9090),
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    Loopback = barrel_mcp_http_stream:is_loopback(Ip),
    case barrel_mcp_http_stream:resolve_allowed_origins(
           Loopback, maps:get(allowed_origins, Opts, undefined)) of
        {error, _} = Err -> Err;
        {ok, AllowedOrigins} ->
            AllowMissing = maps:get(allow_missing_origin, Opts, Loopback),
            AuthConfig = init_auth(maps:get(auth, Opts, #{})),
            HandlerState = #{
                auth_config => AuthConfig,
                allowed_origins => AllowedOrigins,
                allow_missing_origin => AllowMissing
            },
            Routes = [
                {'_', [
                    {"/mcp", ?MODULE, HandlerState},
                    {"/", ?MODULE, HandlerState}
                ]}
            ],
            Dispatch = cowboy_router:compile(Routes),
            cowboy:start_clear(?HTTP_LISTENER, [
                {port, Port},
                {ip, Ip}
            ], #{
                env => #{dispatch => Dispatch}
            })
    end.

%% @doc Stop HTTP server.
-spec stop() -> ok | {error, not_found}.
stop() ->
    cowboy:stop_listener(?HTTP_LISTENER).

%%====================================================================
%% Cowboy Callbacks
%%====================================================================

init(Req0, State) ->
    case barrel_mcp_http_stream:validate_origin(Req0, State) of
        ok ->
            dispatch_method(cowboy_req:method(Req0), Req0, State);
        {error, _} ->
            Req = cowboy_req:reply(403, #{}, <<>>, Req0),
            {ok, Req, State}
    end.

dispatch_method(<<"POST">>, Req0, State) ->
    handle_post(Req0, State);
dispatch_method(<<"OPTIONS">>, Req0, State) ->
    handle_options(Req0, State);
dispatch_method(_, Req0, State) ->
    Req = cowboy_req:reply(405, #{
        <<"content-type">> => <<"application/json">>,
        <<"allow">> => <<"POST, OPTIONS">>
    }, <<"{\"error\":\"Method not allowed\"}">>, Req0),
    {ok, Req, State}.

%%====================================================================
%% Internal Functions
%%====================================================================

handle_post(Req0, State) ->
    AuthConfig = maps:get(auth_config, State, #{provider => barrel_mcp_auth_none}),
    Headers = barrel_mcp_http_stream:extract_headers(Req0, AuthConfig),
    AuthRequest = #{headers => Headers},
    case authenticate(AuthConfig, AuthRequest) of
        {ok, AuthInfo} ->
            handle_mcp_request(Req0, State#{auth_info => AuthInfo});
        {error, Reason} ->
            handle_auth_error(Req0, State, AuthConfig, Reason)
    end.

handle_mcp_request(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case barrel_mcp_protocol:decode(Body) of
        {ok, Request} ->
            AuthInfo = maps:get(auth_info, State, undefined),
            RequestWithAuth = case AuthInfo of
                undefined -> Request;
                _ -> Request#{<<"_auth">> => AuthInfo}
            end,
            case barrel_mcp_protocol:handle(RequestWithAuth) of
                no_response ->
                    Req2 = cowboy_req:reply(204, cors(Req0, State), <<>>, Req1),
                    {ok, Req2, State};
                {async, Plan} ->
                    Result = barrel_mcp_protocol:drive_async_plan(Plan, 60000),
                    reply_json(Req0, Req1, State, 200, Result);
                Result ->
                    reply_json(Req0, Req1, State, 200, Result)
            end;
        {error, parse_error} ->
            ErrorResponse = barrel_mcp_protocol:error_response(
                null, -32700, <<"Parse error">>),
            reply_json(Req0, Req1, State, 400, ErrorResponse)
    end.

reply_json(Req0, ReqAfterRead, State, Status, Envelope) ->
    Json = barrel_mcp_protocol:encode(Envelope),
    Headers = barrel_mcp_http_stream:cors_response_headers(Req0, State, #{
        <<"content-type">> => <<"application/json">>
    }),
    Req2 = cowboy_req:reply(Status, Headers, Json, ReqAfterRead),
    {ok, Req2, State}.

handle_auth_error(Req0, State, AuthConfig, Reason) ->
    {StatusCode, AuthHeaders, Body} =
        barrel_mcp_auth:challenge_response(AuthConfig, Reason),
    Headers = maps:merge(AuthHeaders, cors(Req0, State)),
    Req = cowboy_req:reply(StatusCode, Headers, Body, Req0),
    {ok, Req, State}.

handle_options(Req0, State) ->
    Req = cowboy_req:reply(204, cors(Req0, State), <<>>, Req0),
    {ok, Req, State}.

cors(Req, State) ->
    barrel_mcp_http_stream:cors_response_headers(Req, State, #{}).

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
    %% Default to no authentication
    init_auth(AuthOpts#{provider => barrel_mcp_auth_none}).

authenticate(#{provider := barrel_mcp_auth_none}, _Request) ->
    %% No authentication - always succeed
    barrel_mcp_auth_none:authenticate(#{}, undefined);
authenticate(AuthConfig, Request) ->
    barrel_mcp_auth:authenticate(AuthConfig, Request, AuthConfig).
