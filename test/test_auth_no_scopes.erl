%%%-------------------------------------------------------------------
%%% @doc Test auth provider that authenticates any request without
%%% surfacing a `scopes' key. Used to assert that scope checks fail
%%% closed when a custom provider omits scope claims.
%%% @end
%%%-------------------------------------------------------------------
-module(test_auth_no_scopes).

-export([init/1, authenticate/2]).

init(_Opts) -> {ok, #{}}.

authenticate(_Request, _State) ->
    {ok, #{subject => <<"test-user">>}}.
