%%%-------------------------------------------------------------------
%%% @doc The OAuth handle's authorization-code flow, driven from a
%%% challenge the way the transport drives it, against a scripted
%%% authorization server on the project's own h1.
%%%
%%% The host's redirect step is a fun that reads the authorization URL
%%% and answers with the callback URL the script prescribes, so no
%%% browser and no HTTP round trip stand between the test and the
%%% assertion.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth_flow_tests).

-behaviour(barrel_mcp_client_auth_store).

-include_lib("eunit/include/eunit.hrl").

%% The store behaviour, ETS-backed, so persistence is observable.
-export([get/2, put/3, delete/2]).

-define(PORT, 19496).
-define(BASE, <<"http://127.0.0.1:19496">>).
-define(PORT2, 19497).
-define(BASE2, <<"http://127.0.0.1:19497">>).
-define(TAB, oauth_flow_mock).
-define(SERVER, <<"http://127.0.0.1:19496/mcp">>).
-define(REDIRECT, <<"http://127.0.0.1/callback">>).

flow_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 60, [
            {"401 to bearer: PRM, AS, DCR, authorize, exchange", fun test_happy_path/0},
            {"pre-registered client, client_secret_basic", fun test_prereg_basic/0},
            {"pre-registered client, client_secret_post", fun test_prereg_post/0},
            {"pre-registered client, none", fun test_prereg_none/0},
            {"CIMD when the server supports it", fun test_cimd/0},
            {"PRM at the path-based well-known first", fun test_prm_path_based/0},
            {"PRM falls back to the root document", fun test_prm_root_fallback/0},
            {"a PRM resource that does not cover the server is refused",
                fun test_resource_mismatch/0},
            {"scope: challenge, then PRM, then config, then omitted", fun test_scope_selection/0},
            {"offline_access only when the AS lists it", fun test_offline_access/0},
            {"403 insufficient_scope steps up with the union", fun test_step_up/0},
            {"iss handling, six ways", fun test_iss/0},
            {"a callback on another location is refused before the code is read",
                fun test_callback_mismatch/0},
            {"a relative callback resolves against the authorization endpoint",
                fun test_relative_callback/0},
            {"the store keeps the client and the tokens", fun test_store_round_trip/0},
            {"a new issuer drops the stored client and tokens", fun test_migration/0},
            {"the registered auth method is used for refresh", fun test_refresh_uses_method/0},
            {"2025-03-26: metadata at the server origin, no PRM", fun test_legacy_metadata/0},
            {"2025-03-26: fixed endpoints when there is no metadata", fun test_legacy_fallbacks/0},
            {"2024-11-05 has no authorization", fun test_2024/0}
        ]}}.

%%====================================================================
%% Fixture
%%====================================================================

setup() ->
    {ok, _} = application:ensure_all_started(hackney),
    _ = ets:new(?TAB, [named_table, public, set]),
    {ok, _} = barrel_mcp_test_http:start(flow_as, ?PORT, fun(Req) -> handle(?BASE, Req) end),
    {ok, _} = barrel_mcp_test_http:start(flow_as2, ?PORT2, fun(Req) -> handle(?BASE2, Req) end),
    ok.

cleanup(_) ->
    [
        try
            barrel_mcp_test_http:stop(N)
        catch
            _:_ -> ok
        end
     || N <- [flow_as, flow_as2]
    ],
    _ =
        try
            ets:delete(?TAB)
        catch
            _:_ -> ok
        end,
    ok.

%% The script is a map the test installs; the log is every request the
%% mock answered, in order, as `{Base, Method, Path, Req}'.
script(Script) ->
    ets:match_delete(?TAB, {{log, '_'}, '_'}),
    ets:match_delete(?TAB, {{store, '_'}, '_'}),
    true = ets:insert(?TAB, {script, maps:merge(default_script(), Script)}).

default_script() ->
    #{
        prm => #{
            <<"resource">> => ?SERVER,
            <<"authorization_servers">> => [?BASE]
        },
        as => as_doc(?BASE),
        token => #{
            <<"access_token">> => <<"at-1">>,
            <<"token_type">> => <<"Bearer">>,
            <<"expires_in">> => 3600
        },
        register => #{<<"client_id">> => <<"dcr-client">>}
    }.

as_doc(Base) ->
    #{
        <<"issuer">> => Base,
        <<"authorization_endpoint">> => <<Base/binary, "/authorize">>,
        <<"token_endpoint">> => <<Base/binary, "/token">>,
        <<"registration_endpoint">> => <<Base/binary, "/register">>,
        <<"code_challenge_methods_supported">> => [<<"S256">>]
    }.

get_script() ->
    [{script, S}] = ets:lookup(?TAB, script),
    S.

log(Base, #{method := M, path := P} = Req) ->
    true = ets:insert(?TAB, {{log, erlang:unique_integer([monotonic])}, {Base, M, P, Req}}).

requests() ->
    [E || {_, E} <- lists:sort(ets:match_object(?TAB, {{log, '_'}, '_'}))].

paths() ->
    [P || {_, _, P, _} <- requests()].

token_requests() ->
    [Req || {_, _, <<"/token">>, Req} <- requests()].

handle(Base, #{path := Path} = Req) ->
    log(Base, Req),
    Script = get_script(),
    case Path of
        <<"/.well-known/oauth-protected-resource", _/binary>> ->
            prm_response(Path, Script);
        <<"/.well-known/oauth-authorization-server">> ->
            case maps:get(as, Script) of
                undefined -> {404, json_ct(), <<"{}">>};
                Doc when Base =:= ?BASE -> {200, json_ct(), json(Doc)};
                _ -> {200, json_ct(), json(as_doc(Base))}
            end;
        <<"/register">> ->
            Body = json_decode(maps:get(body, Req, <<>>)),
            true = ets:insert(?TAB, {last_registration, Body}),
            {201, json_ct(), json(maps:get(register, Script))};
        <<"/token">> ->
            {200, json_ct(), json(maps:get(token, Script))};
        _ ->
            {404, json_ct(), <<"{}">>}
    end.

prm_response(Path, Script) ->
    Where = maps:get(prm_at, Script, any),
    Prm = maps:get(prm, Script),
    case Where =:= any orelse Where =:= Path of
        true when Prm =/= undefined -> {200, json_ct(), json(Prm)};
        _ -> {404, json_ct(), <<"{}">>}
    end.

json_ct() -> #{<<"content-type">> => <<"application/json">>}.
json(M) -> iolist_to_binary(json:encode(M)).
json_decode(<<>>) -> #{};
json_decode(B) -> json:decode(B).

%%====================================================================
%% The host's redirect step
%%====================================================================

%% Records the authorization URL, then answers with the callback the
%% script prescribes: the redirect URI carrying a code and the state
%% the URL asked for, plus whatever `iss' the script names.
authorize(Script) ->
    fun(Url) ->
        true = ets:insert(?TAB, {last_authorization, Url}),
        Q = query_of(Url),
        State = maps:get(<<"state">>, Q),
        Redirect = maps:get(<<"redirect_uri">>, Q, ?REDIRECT),
        Iss =
            case maps:get(iss, Script, absent) of
                absent -> <<>>;
                I -> <<"&iss=", (uri_string:quote(I))/binary>>
            end,
        case maps:get(callback, Script, undefined) of
            undefined ->
                {ok, <<Redirect/binary, "?code=code-1&state=", State/binary, Iss/binary>>};
            Fun when is_function(Fun, 2) ->
                Fun(Redirect, State)
        end
    end.

query_of(Url) ->
    #{query := Q} = uri_string:parse(Url),
    maps:from_list(uri_string:dissect_query(Q)).

last_authorization() ->
    [{last_authorization, Url}] = ets:lookup(?TAB, last_authorization),
    Url.

authorization_query() ->
    query_of(last_authorization()).

%%====================================================================
%% Handles and challenges
%%====================================================================

handle_with(Extra, Script) ->
    Cfg = maps:merge(
        #{
            redirect_uri => ?REDIRECT,
            authorize => authorize(Script),
            allow_insecure_oauth => true
        },
        Extra
    ),
    {ok, H} = barrel_mcp_client_auth_oauth:init(Cfg),
    H.

challenge(Status, Www) ->
    challenge(Status, Www, <<"2026-07-28">>).

challenge(Status, Www, Version) ->
    #{
        status => Status,
        www_authenticate => Www,
        server_url => ?SERVER,
        protocol_version => Version
    }.

www() ->
    <<"Bearer resource_metadata=\"", ?BASE/binary, "/.well-known/oauth-protected-resource\"">>.

bearer(H) ->
    {ok, <<"Bearer ", Token/binary>>} = barrel_mcp_client_auth_oauth:header(H),
    Token.

run(Extra, Script, Challenge) ->
    script(Script),
    H = handle_with(Extra, Script),
    barrel_mcp_client_auth_oauth:challenge(H, Challenge).

%%====================================================================
%% Cases
%%====================================================================

test_happy_path() ->
    {ok, H} = run(#{}, #{}, challenge(401, www())),
    ?assertEqual(<<"at-1">>, bearer(H)),
    ?assertEqual(
        [
            <<"/.well-known/oauth-protected-resource">>,
            <<"/.well-known/oauth-authorization-server">>,
            <<"/register">>,
            <<"/token">>
        ],
        paths()
    ),
    [TokenReq] = token_requests(),
    Form = barrel_mcp_test_http:form(TokenReq),
    ?assertEqual(<<"authorization_code">>, maps:get(<<"grant_type">>, Form)),
    ?assertEqual(<<"code-1">>, maps:get(<<"code">>, Form)),
    ?assertEqual(<<"dcr-client">>, maps:get(<<"client_id">>, Form)),
    ?assertEqual(?REDIRECT, maps:get(<<"redirect_uri">>, Form)),
    ?assertEqual(?SERVER, maps:get(<<"resource">>, Form)),
    ?assert(maps:is_key(<<"code_verifier">>, Form)),
    AuthQ = authorization_query(),
    ?assertEqual(<<"S256">>, maps:get(<<"code_challenge_method">>, AuthQ)),
    ?assertEqual(?SERVER, maps:get(<<"resource">>, AuthQ)).

test_prereg_basic() ->
    {ok, _} = run(
        #{
            client_id => <<"pre">>,
            client_secret => <<"s3">>,
            token_endpoint_auth_method => client_secret_basic
        },
        #{},
        challenge(401, www())
    ),
    ?assertNot(lists:member(<<"/register">>, paths())),
    [TokenReq] = token_requests(),
    Form = barrel_mcp_test_http:form(TokenReq),
    ?assertEqual(
        <<"Basic ", (base64:encode(<<"pre:s3">>))/binary>>,
        barrel_mcp_test_http:header(<<"authorization">>, TokenReq)
    ),
    ?assertNot(maps:is_key(<<"client_secret">>, Form)),
    ?assertNot(maps:is_key(<<"client_id">>, Form)).

test_prereg_post() ->
    {ok, _} = run(
        #{
            client_id => <<"pre">>,
            client_secret => <<"s3">>,
            token_endpoint_auth_method => client_secret_post
        },
        #{},
        challenge(401, www())
    ),
    [TokenReq] = token_requests(),
    Form = barrel_mcp_test_http:form(TokenReq),
    ?assertEqual(undefined, barrel_mcp_test_http:header(<<"authorization">>, TokenReq)),
    ?assertEqual(<<"s3">>, maps:get(<<"client_secret">>, Form)),
    ?assertEqual(<<"pre">>, maps:get(<<"client_id">>, Form)).

test_prereg_none() ->
    {ok, _} = run(
        #{client_id => <<"pre">>, client_secret => <<"s3">>, token_endpoint_auth_method => none},
        #{},
        challenge(401, www())
    ),
    [TokenReq] = token_requests(),
    Form = barrel_mcp_test_http:form(TokenReq),
    ?assertEqual(undefined, barrel_mcp_test_http:header(<<"authorization">>, TokenReq)),
    ?assertNot(maps:is_key(<<"client_secret">>, Form)),
    ?assertEqual(<<"pre">>, maps:get(<<"client_id">>, Form)).

test_cimd() ->
    Cimd = <<"https://app.example/oauth/client.json">>,
    As = (as_doc(?BASE))#{<<"client_id_metadata_document_supported">> => true},
    {ok, _} = run(#{client_id_metadata_url => Cimd}, #{as => As}, challenge(401, www())),
    ?assertNot(lists:member(<<"/register">>, paths())),
    ?assertEqual(Cimd, maps:get(<<"client_id">>, authorization_query())).

test_prm_path_based() ->
    Www = <<"Bearer realm=\"mcp\"">>,
    script(#{prm_at => <<"/.well-known/oauth-protected-resource/mcp">>}),
    H = handle_with(#{}, #{}),
    {ok, _} = barrel_mcp_client_auth_oauth:challenge(H, challenge(401, Www)),
    ?assertEqual(<<"/.well-known/oauth-protected-resource/mcp">>, hd(paths())).

test_prm_root_fallback() ->
    Www = <<"Bearer realm=\"mcp\"">>,
    script(#{prm_at => <<"/.well-known/oauth-protected-resource">>}),
    H = handle_with(#{}, #{}),
    {ok, _} = barrel_mcp_client_auth_oauth:challenge(H, challenge(401, Www)),
    ?assertEqual(
        [
            <<"/.well-known/oauth-protected-resource/mcp">>,
            <<"/.well-known/oauth-protected-resource">>
        ],
        lists:sublist(paths(), 2)
    ).

test_resource_mismatch() ->
    Prm = #{
        <<"resource">> => <<"http://127.0.0.1:1/elsewhere">>, <<"authorization_servers">> => [?BASE]
    },
    ?assertMatch(
        {error, {resource_mismatch, <<"http://127.0.0.1:1/elsewhere">>, ?SERVER}},
        run(#{}, #{prm => Prm}, challenge(401, www()))
    ),
    ?assertNot(lists:member(<<"/.well-known/oauth-authorization-server">>, paths())).

test_scope_selection() ->
    Prm = #{
        <<"resource">> => ?SERVER,
        <<"authorization_servers">> => [?BASE],
        <<"scopes_supported">> => [<<"files:read">>]
    },
    %% The challenge's scope wins.
    {ok, _} = run(
        #{scopes => [<<"cfg">>]},
        #{prm => Prm},
        challenge(401, <<(www())/binary, ", scope=\"a b\"">>)
    ),
    ?assertEqual(<<"a b">>, maps:get(<<"scope">>, authorization_query())),
    %% Then the PRM's.
    {ok, _} = run(#{scopes => [<<"cfg">>]}, #{prm => Prm}, challenge(401, www())),
    ?assertEqual(<<"files:read">>, maps:get(<<"scope">>, authorization_query())),
    %% Then the config's.
    {ok, _} = run(#{scopes => [<<"cfg">>]}, #{}, challenge(401, www())),
    ?assertEqual(<<"cfg">>, maps:get(<<"scope">>, authorization_query())),
    %% Then none at all.
    {ok, _} = run(#{}, #{}, challenge(401, www())),
    ?assertNot(maps:is_key(<<"scope">>, authorization_query())).

test_offline_access() ->
    Listed = (as_doc(?BASE))#{<<"scopes_supported">> => [<<"files:read">>, <<"offline_access">>]},
    {ok, _} = run(#{scopes => [<<"files:read">>]}, #{as => Listed}, challenge(401, www())),
    Q = authorization_query(),
    ?assertEqual(<<"files:read offline_access">>, maps:get(<<"scope">>, Q)),
    ?assertEqual(<<"consent">>, maps:get(<<"prompt">>, Q)),
    NotListed = (as_doc(?BASE))#{<<"scopes_supported">> => [<<"files:read">>]},
    {ok, _} = run(#{scopes => [<<"files:read">>]}, #{as => NotListed}, challenge(401, www())),
    Q2 = authorization_query(),
    ?assertEqual(<<"files:read">>, maps:get(<<"scope">>, Q2)),
    ?assertNot(maps:is_key(<<"prompt">>, Q2)).

test_step_up() ->
    Token = #{<<"access_token">> => <<"at-1">>, <<"scope">> => <<"files:read">>},
    {ok, H} = run(#{scopes => [<<"files:read">>]}, #{token => Token}, challenge(401, www())),
    Before = length(paths()),
    {ok, H2} = barrel_mcp_client_auth_oauth:challenge(
        H, challenge(403, <<"Bearer error=\"insufficient_scope\", scope=\"files:write\"">>)
    ),
    ?assertEqual(<<"at-1">>, bearer(H2)),
    ?assertEqual(<<"files:read files:write">>, maps:get(<<"scope">>, authorization_query())),
    %% No rediscovery, no re-registration: only the token exchange.
    ?assertEqual([<<"/token">>], lists:nthtail(Before, paths())).

test_iss() ->
    Advertised = (as_doc(?BASE))#{<<"authorization_response_iss_parameter_supported">> => true},
    %% Advertised, present and equal: accepted.
    ?assertMatch({ok, _}, run(#{}, #{as => Advertised, iss => ?BASE}, challenge(401, www()))),
    %% Advertised but missing: refused.
    ?assertEqual({error, missing_iss}, run(#{}, #{as => Advertised}, challenge(401, www()))),
    %% Advertised and wrong: refused.
    ?assertMatch(
        {error, {issuer_mismatch, _, _}},
        run(#{}, #{as => Advertised, iss => <<"https://evil.example">>}, challenge(401, www()))
    ),
    %% Not advertised, present and equal: accepted.
    ?assertMatch({ok, _}, run(#{}, #{iss => ?BASE}, challenge(401, www()))),
    %% Not advertised, present and wrong: still compared, refused.
    ?assertMatch(
        {error, {issuer_mismatch, _, _}},
        run(#{}, #{iss => <<"https://evil.example">>}, challenge(401, www()))
    ),
    %% Byte comparison, no normalisation: a trailing slash is a mismatch.
    ?assertMatch(
        {error, {issuer_mismatch, _, _}},
        run(#{}, #{iss => <<?BASE/binary, "/">>}, challenge(401, www()))
    ).

test_callback_mismatch() ->
    Callback = fun(_Redirect, State) ->
        {ok, <<"http://elsewhere.example/callback?code=code-1&state=", State/binary>>}
    end,
    ?assertMatch(
        {error, {callback_mismatch, _}},
        run(#{}, #{callback => Callback}, challenge(401, www()))
    ),
    ?assertNot(lists:member(<<"/token">>, paths())).

test_relative_callback() ->
    %% The redirect URI lives on the authorization server's own origin,
    %% so a relative callback resolves to it.
    Redirect = <<?BASE/binary, "/callback">>,
    Callback = fun(_Redirect, State) -> {ok, <<"/callback?code=code-1&state=", State/binary>>} end,
    ?assertMatch(
        {ok, _},
        run(#{redirect_uri => Redirect}, #{callback => Callback}, challenge(401, www()))
    ),
    ?assert(lists:member(<<"/token">>, paths())).

test_store_round_trip() ->
    Store = {?MODULE, store1},
    Token = #{<<"access_token">> => <<"at-1">>, <<"refresh_token">> => <<"rt-1">>},
    {ok, _} = run(#{store => Store}, #{token => Token}, challenge(401, www())),
    ?assertMatch({ok, #{client_id := <<"dcr-client">>, issuer := ?BASE}}, get(client, store1)),
    ?assertMatch(
        {ok, #{access_token := <<"at-1">>, refresh_token := <<"rt-1">>}}, get(tokens, store1)
    ),
    %% A fresh handle on the same store starts authenticated and, on a
    %% 401 from the same issuer, refreshes instead of registering.
    ets:match_delete(?TAB, {{log, '_'}, '_'}),
    H = handle_with(#{store => Store}, #{}),
    ?assertEqual(<<"at-1">>, bearer(H)),
    {ok, _} = barrel_mcp_client_auth_oauth:challenge(H, challenge(401, www())),
    ?assertNot(lists:member(<<"/register">>, paths())),
    [TokenReq] = token_requests(),
    ?assertEqual(
        <<"refresh_token">>, maps:get(<<"grant_type">>, barrel_mcp_test_http:form(TokenReq))
    ).

test_migration() ->
    Store = {?MODULE, store2},
    Token = #{<<"access_token">> => <<"at-1">>, <<"refresh_token">> => <<"rt-1">>},
    {ok, H} = run(#{store => Store}, #{token => Token}, challenge(401, www())),
    %% The resource moves to another authorization server.
    Prm2 = #{<<"resource">> => ?SERVER, <<"authorization_servers">> => [?BASE2]},
    script(#{prm => Prm2, register => #{<<"client_id">> => <<"dcr-client-2">>}}),
    {ok, H2} = barrel_mcp_client_auth_oauth:challenge(H, challenge(401, www())),
    ?assertEqual(<<"at-1">>, bearer(H2)),
    ?assert(
        lists:member({?BASE2, <<"POST">>, <<"/register">>}, [
            {B, M, P}
         || {B, M, P, _} <- requests()
        ])
    ),
    ?assertNot(
        lists:member({?BASE, <<"POST">>, <<"/token">>}, [{B, M, P} || {B, M, P, _} <- requests()])
    ),
    ?assertMatch({ok, #{client_id := <<"dcr-client-2">>, issuer := ?BASE2}}, get(client, store2)),
    ?assert(lists:member({deleted, client}, deletions(store2))),
    ?assert(lists:member({deleted, tokens}, deletions(store2))).

test_refresh_uses_method() ->
    Register = #{
        <<"client_id">> => <<"dcr-client">>,
        <<"client_secret">> => <<"dcr-secret">>,
        <<"token_endpoint_auth_method">> => <<"client_secret_post">>
    },
    Token = #{<<"access_token">> => <<"at-1">>, <<"refresh_token">> => <<"rt-1">>},
    {ok, H} = run(#{}, #{register => Register, token => Token}, challenge(401, www())),
    ets:match_delete(?TAB, {{log, '_'}, '_'}),
    {ok, _} = barrel_mcp_client_auth_oauth:challenge(H, challenge(401, www())),
    [TokenReq] = token_requests(),
    Form = barrel_mcp_test_http:form(TokenReq),
    ?assertEqual(<<"refresh_token">>, maps:get(<<"grant_type">>, Form)),
    ?assertEqual(<<"dcr-secret">>, maps:get(<<"client_secret">>, Form)),
    ?assertEqual(undefined, barrel_mcp_test_http:header(<<"authorization">>, TokenReq)).

test_legacy_metadata() ->
    {ok, H} = run(#{scopes => [<<"cfg">>]}, #{}, challenge(401, undefined, <<"2025-03-26">>)),
    ?assertEqual(<<"at-1">>, bearer(H)),
    ?assertNot(
        lists:any(fun(P) -> binary:match(P, <<"protected-resource">>) =/= nomatch end, paths())
    ),
    ?assertEqual(<<"/.well-known/oauth-authorization-server">>, hd(paths())),
    Q = authorization_query(),
    ?assertNot(maps:is_key(<<"resource">>, Q)),
    ?assertEqual(<<"cfg">>, maps:get(<<"scope">>, Q)).

test_legacy_fallbacks() ->
    {ok, H} = run(#{}, #{as => undefined}, challenge(401, undefined, <<"2025-03-26">>)),
    ?assertEqual(<<"at-1">>, bearer(H)),
    ?assertEqual(
        [<<"/.well-known/oauth-authorization-server">>, <<"/register">>, <<"/token">>],
        paths()
    ),
    ?assertNotEqual(nomatch, string:prefix(last_authorization(), <<?BASE/binary, "/authorize?">>)).

test_2024() ->
    ?assertEqual({error, unauthorized}, run(#{}, #{}, challenge(401, www(), <<"2024-11-05">>))),
    ?assertEqual([], paths()).

%%====================================================================
%% The store behaviour, ETS-backed
%%====================================================================

get(Key, Arg) ->
    case ets:lookup(?TAB, {store, {Arg, Key}}) of
        [{_, Value}] -> {ok, Value};
        [] -> undefined
    end.

put(Key, Value, Arg) ->
    true = ets:insert(?TAB, {{store, {Arg, Key}}, Value}),
    ok.

delete(Key, Arg) ->
    true = ets:delete(?TAB, {store, {Arg, Key}}),
    true = ets:insert(?TAB, {{store, {Arg, {deleted, Key}}}, true}),
    ok.

deletions(Arg) ->
    [D || {{store, {A, {deleted, _} = D}}, true} <- ets:tab2list(?TAB), A =:= Arg].
