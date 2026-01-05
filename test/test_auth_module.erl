%%%-------------------------------------------------------------------
%%% @doc Test authentication module for barrel_mcp_auth_custom tests.
%%% @end
%%%-------------------------------------------------------------------
-module(test_auth_module).

-export([init/1, authenticate/2]).

init(_Opts) ->
    {ok, #{}}.

authenticate(<<"valid-token">>, State) ->
    {ok, #{subject => <<"test-user">>, scopes => []}, State};
authenticate(_, State) ->
    {error, invalid_token, State}.
