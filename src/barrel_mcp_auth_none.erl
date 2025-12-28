%%%-------------------------------------------------------------------
%%% @doc No authentication provider for barrel_mcp.
%%%
%%% This is the default authentication provider that allows all requests.
%%% Use this for development, testing, or when authentication is handled
%%% at a different layer (e.g., API gateway, reverse proxy).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_none).

-behaviour(barrel_mcp_auth).

%% barrel_mcp_auth callbacks
-export([
    init/1,
    authenticate/2,
    challenge/2
]).

%%====================================================================
%% barrel_mcp_auth callbacks
%%====================================================================

%% @doc Initialize the no-auth provider.
-spec init(map()) -> {ok, undefined}.
init(_Opts) ->
    {ok, undefined}.

%% @doc Always authenticate successfully.
%% Returns an anonymous auth_info with no claims.
-spec authenticate(map(), term()) -> {ok, barrel_mcp_auth:auth_info()}.
authenticate(_Request, _State) ->
    {ok, #{
        subject => <<"anonymous">>,
        scopes => [],
        claims => #{},
        metadata => #{provider => barrel_mcp_auth_none}
    }}.

%% @doc Return a challenge response.
%% This should never be called since authenticate always succeeds,
%% but we implement it for completeness.
-spec challenge(barrel_mcp_auth:auth_error(), term()) ->
    {integer(), map(), binary()}.
challenge(_Reason, _State) ->
    {401, #{<<"www-authenticate">> => <<"None">>}, <<>>}.
