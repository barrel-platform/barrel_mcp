%%%-------------------------------------------------------------------
%%% @doc Static bearer-token auth for `barrel_mcp_client'.
%%%
%%% Refresh is a no-op: a static token cannot be rotated by the
%%% library. A 401 with this handle returns `{error, unauthorized}' so
%%% the caller can supply a new token.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth_bearer).

-behaviour(barrel_mcp_client_auth).

-export([init/1, header/1, refresh/2]).

init(Token) when is_binary(Token), byte_size(Token) > 0 ->
    {ok, Token};
init(_) ->
    {error, invalid_token}.

header(Token) ->
    {ok, <<"Bearer ", Token/binary>>}.

refresh(_Token, _Www) ->
    {error, unauthorized}.
