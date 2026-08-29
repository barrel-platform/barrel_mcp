%%%-------------------------------------------------------------------
%%% @doc An auth provider that names its own users, for
%%% `barrel_mcp_principal_tests'. Exists as its own module because
%%% exporting `principal/2' is what selects the override path, so a
%%% provider cannot demonstrate both it and the default derivation.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_custom_principal_provider).

-behaviour(barrel_mcp_auth).

-export([init/1, authenticate/2, challenge/2, principal/2]).

init(Opts) -> {ok, Opts}.

authenticate(_Request, #{info := Info}) -> {ok, Info}.

challenge(_Reason, _State) -> {401, #{}, <<>>}.

principal(#{subject := Subject}, _State) -> {ok, {custom_scheme, Subject}};
principal(_Info, _State) -> {error, no_subject}.
