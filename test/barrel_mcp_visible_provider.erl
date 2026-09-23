%%%-------------------------------------------------------------------
%%% @doc Test auth provider with `visible/4'. The bearer token is the
%%% subject: `a' sees the even `av_' entries, `b' the odd ones, `all'
%%% everything. `av_boom' makes the callback raise, `av_maybe' answer
%%% a non-boolean.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_visible_provider).

-behaviour(barrel_mcp_auth).

-export([init/1, authenticate/2, challenge/2, visible/4]).
-export([sees/2]).

init(Opts) -> {ok, Opts}.

authenticate(#{headers := Headers}, _State) ->
    case barrel_mcp_auth:extract_bearer_token(Headers) of
        {ok, Token} -> {ok, #{subject => Token}};
        {error, no_token} -> {error, unauthorized}
    end.

challenge(_Reason, _State) -> {401, #{}, <<>>}.

visible(_Kind, {Name, _Handler}, #{subject := Subject}, _State) ->
    sees(Subject, Name).

%% Shared with `barrel_mcp_visible_custom'.
sees(_Subject, <<"av_boom">>) ->
    error(boom);
sees(_Subject, <<"av_maybe">>) ->
    sometimes;
sees(<<"all">>, _Name) ->
    true;
sees(Subject, <<"av_", N/binary>>) ->
    case {Subject, binary_to_integer(N) rem 2} of
        {<<"a">>, 0} -> true;
        {<<"b">>, 1} -> true;
        _ -> false
    end;
sees(_Subject, _Name) ->
    true.
