%%%-------------------------------------------------------------------
%%% @doc The identity that owns tasks, sealed request state and
%%% elicitations.
%%%
%%% It used to be the whole `auth_info()' map, which carries `exp',
%%% `iat' and `jti', so a refreshed token for the same user read as a
%%% different caller and orphaned whatever it had started. A bare
%%% subject is not enough either: providers, issuers and tenants each
%%% mint their own, and the stores keyed by this are node-wide.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_principal_tests).

-behaviour(barrel_mcp_auth).

-include_lib("eunit/include/eunit.hrl").

-export([init/1, authenticate/2, challenge/2]).

%%====================================================================
%% A provider that returns whatever the test planted
%%====================================================================

init(Opts) -> {ok, Opts}.

authenticate(_Request, #{info := Info}) -> {ok, Info};
authenticate(_Request, _State) -> {error, unauthorized}.

challenge(_Reason, _State) -> {401, #{}, <<>>}.

config(Info) -> config(Info, #{}).

config(Info, Extra) ->
    maps:merge(
        #{
            provider => ?MODULE,
            provider_state => #{info => Info}
        },
        Extra
    ).

auth(Config) -> barrel_mcp_auth:authenticate(Config, #{headers => #{}}, Config).

principal_of(Config) ->
    {ok, Info} = auth(Config),
    maps:get(principal, Info).

%%====================================================================
%% Cases
%%====================================================================

%% The reason this exists: refreshing a token must not change identity.
survives_token_refresh_test() ->
    Base = #{subject => <<"alice">>, issuer => <<"https://idp">>},
    First = principal_of(config(Base#{claims => #{<<"exp">> => 1, <<"jti">> => <<"a">>}})),
    Second = principal_of(config(Base#{claims => #{<<"exp">> => 2, <<"jti">> => <<"b">>}})),
    ?assertEqual(First, Second).

%% Same subject, different issuer, is a different person.
issuer_separates_subjects_test() ->
    A = principal_of(config(#{subject => <<"alice">>, issuer => <<"https://one">>})),
    B = principal_of(config(#{subject => <<"alice">>, issuer => <<"https://two">>})),
    ?assertNotEqual(A, B).

%% Providers without an issuer, such as basic and api key, would
%% otherwise collide on the subject alone.
namespace_separates_subjects_test() ->
    A = principal_of(config(#{subject => <<"alice">>}, #{namespace => <<"tenant-a">>})),
    B = principal_of(config(#{subject => <<"alice">>}, #{namespace => <<"tenant-b">>})),
    ?assertNotEqual(A, B).

%% A credential the provider accepted but cannot name is refused rather
%% than given a partial or anonymous identity.
missing_subject_is_unauthorized_test() ->
    ?assertEqual({error, unauthorized}, auth(config(#{scopes => []}))),
    ?assertEqual({error, unauthorized}, auth(config(#{subject => <<>>}))),
    ?assertEqual({error, unauthorized}, auth(config(#{subject => undefined}))).

%% A provider that names its own users overrides the derivation.
provider_override_test() ->
    Config = #{
        provider => barrel_mcp_custom_principal_provider,
        provider_state => #{info => #{subject => <<"alice">>}}
    },
    ?assertEqual({custom_scheme, <<"alice">>}, principal_of(Config)).

%% No credential at all is its own scope, never equal to an
%% authenticated one.
anonymous_is_distinct_test() ->
    Ctx = barrel_mcp_ctx:from_request(#{<<"method">> => <<"ping">>}, #{}),
    ?assertEqual(anonymous, barrel_mcp_ctx:principal(Ctx)),
    Authed = barrel_mcp_ctx:from_request(
        #{<<"method">> => <<"ping">>},
        #{auth_info => #{principal => {p, undefined, <<"alice">>}}}
    ),
    ?assertNotEqual(
        barrel_mcp_ctx:principal(Ctx),
        barrel_mcp_ctx:principal(Authed)
    ).
