%%%-------------------------------------------------------------------
%%% @doc HTTP transport for MCP using Cowboy.
%%%
%%% Implements a Cowboy handler for HTTP-based MCP communication.
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

    Routes = [
        {'_', [
            {"/mcp", ?MODULE, #{}},
            {"/", ?MODULE, #{}}
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
    {ok, Body, Req1} = cowboy_req:read_body(Req0),

    Response = case barrel_mcp_protocol:decode(Body) of
        {ok, Request} ->
            case barrel_mcp_protocol:handle(Request) of
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

handle_options(Req0, State) ->
    Req = cowboy_req:reply(204, cors_headers(), <<>>, Req0),
    {ok, Req, State}.

cors_headers() ->
    #{
        <<"access-control-allow-origin">> => <<"*">>,
        <<"access-control-allow-methods">> => <<"POST, OPTIONS">>,
        <<"access-control-allow-headers">> => <<"content-type">>
    }.
