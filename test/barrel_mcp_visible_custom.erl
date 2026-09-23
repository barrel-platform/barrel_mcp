%%%-------------------------------------------------------------------
%%% @doc Test module for `barrel_mcp_auth_custom' exporting `visible/4'.
%%% The token is the subject; visibility as in
%%% `barrel_mcp_visible_provider'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_visible_custom).

-export([init/1, authenticate/2, visible/4]).

init(_Opts) -> {ok, #{}}.

authenticate(Token, State) -> {ok, #{subject => Token}, State}.

visible(_Kind, {Name, _Handler}, #{subject := Subject}, _State) ->
    barrel_mcp_visible_provider:sees(Subject, Name).
