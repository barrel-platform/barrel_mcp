%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024 Benoit Chesneau
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
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Opts) ->
    Port = maps:get(port, Opts, 9090),
    Ip = maps:get(ip, Opts, {0, 0, 0, 0}),

    %% Initialize authentication
    AuthConfig = init_auth(maps:get(auth, Opts, #{})),

    %% Handler state includes auth config
    HandlerState = #{
        auth_config => AuthConfig
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
    }).

%% @doc Stop HTTP server.
-spec stop() -> ok | {error, not_found}.
stop() ->
    cowboy:stop_listener(?HTTP_LISTENER).

%%====================================================================
%% Cowboy Callbacks
%%====================================================================

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    case Method of
        <<"POST">> ->
            handle_post(Req0, State);
        <<"OPTIONS">> ->
            handle_options(Req0, State);
        _ ->
            Req = cowboy_req:reply(405, #{
                <<"content-type">> => <<"application/json">>,
                <<"allow">> => <<"POST, OPTIONS">>
            }, <<"{\"error\":\"Method not allowed\"}">>, Req0),
            {ok, Req, State}
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

handle_post(Req0, State) ->
    AuthConfig = maps:get(auth_config, State, #{provider => barrel_mcp_auth_none}),

    %% Extract headers for authentication
    Headers = extract_headers(Req0),
    AuthRequest = #{headers => Headers},

    %% Authenticate the request
    case authenticate(AuthConfig, AuthRequest) of
        {ok, AuthInfo} ->
            %% Authentication successful, process MCP request
            handle_mcp_request(Req0, State#{auth_info => AuthInfo});
        {error, Reason} ->
            %% Authentication failed, return challenge
            handle_auth_error(Req0, State, AuthConfig, Reason)
    end.

handle_mcp_request(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    Response = case barrel_mcp_protocol:decode(Body) of
        {ok, Request} ->
            %% Add auth_info to request context for handlers
            AuthInfo = maps:get(auth_info, State, undefined),
            RequestWithAuth = case AuthInfo of
                undefined -> Request;
                _ -> Request#{<<"_auth">> => AuthInfo}
            end,
            case barrel_mcp_protocol:handle(RequestWithAuth) of
                no_response ->
                    %% Notification - return 204 No Content
                    Req2 = cowboy_req:reply(204, cors_headers(), <<>>, Req1),
                    {ok, Req2, State};
                Result ->
                    ResponseJson = barrel_mcp_protocol:encode(Result),
                    Headers = maps:merge(#{<<"content-type">> => <<"application/json">>}, cors_headers()),
                    Req2 = cowboy_req:reply(200, Headers, ResponseJson, Req1),
                    {ok, Req2, State}
            end;
        {error, parse_error} ->
            ErrorResponse = barrel_mcp_protocol:error_response(
                null, -32700, <<"Parse error">>
            ),
            ResponseJson = barrel_mcp_protocol:encode(ErrorResponse),
            Headers = maps:merge(#{<<"content-type">> => <<"application/json">>}, cors_headers()),
            Req2 = cowboy_req:reply(400, Headers, ResponseJson, Req1),
            {ok, Req2, State}
    end,
    Response.

handle_auth_error(Req0, State, AuthConfig, Reason) ->
    {StatusCode, AuthHeaders, Body} = barrel_mcp_auth:challenge_response(AuthConfig, Reason),
    Headers = maps:merge(AuthHeaders, cors_headers()),
    Req = cowboy_req:reply(StatusCode, Headers, Body, Req0),
    {ok, Req, State}.

handle_options(Req0, State) ->
    Req = cowboy_req:reply(204, cors_headers(), <<>>, Req0),
    {ok, Req, State}.

cors_headers() ->
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-methods">> => <<"POST, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"content-type, authorization, x-api-key">>,
        <<"access-control-expose-headers">> => <<"www-authenticate">>
    }.

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

extract_headers(Req) ->
    %% Extract relevant headers for authentication
    HeaderNames = [<<"authorization">>, <<"x-api-key">>],
    lists:foldl(fun(Name, Acc) ->
        case cowboy_req:header(Name, Req) of
            undefined -> Acc;
            Value -> Acc#{Name => Value}
        end
    end, #{}, HeaderNames).
