%%%-------------------------------------------------------------------
%%% @doc Tests for `barrel_mcp_client_auth_oauth' covering pure
%%% helpers and a refresh-token round-trip against a tiny cowboy
%%% authorization server.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth_oauth_tests).

-include_lib("eunit/include/eunit.hrl").

-export([init/2]).

-define(PORT, 19494).
-define(BASE, <<"http://127.0.0.1:19494">>).

%%====================================================================
%% Pure helpers
%%====================================================================

parse_www_authenticate_with_quotes_test() ->
    H = <<"Bearer realm=\"x\", resource_metadata=\"https://srv/.well-known/oauth-protected-resource\", error=\"invalid_token\"">>,
    ?assertEqual(<<"https://srv/.well-known/oauth-protected-resource">>,
                 barrel_mcp_client_auth_oauth:parse_www_authenticate(H)).

parse_www_authenticate_no_quotes_test() ->
    H = <<"Bearer resource_metadata=https://srv/.well-known/oauth-protected-resource">>,
    ?assertEqual(<<"https://srv/.well-known/oauth-protected-resource">>,
                 barrel_mcp_client_auth_oauth:parse_www_authenticate(H)).

parse_www_authenticate_missing_test() ->
    ?assertEqual(undefined,
                 barrel_mcp_client_auth_oauth:parse_www_authenticate(
                   <<"Bearer realm=\"x\"">>)).

parse_www_authenticate_undefined_test() ->
    ?assertEqual(undefined,
                 barrel_mcp_client_auth_oauth:parse_www_authenticate(undefined)).

pkce_verifier_is_url_safe_test() ->
    V = barrel_mcp_client_auth_oauth:gen_code_verifier(),
    ?assert(byte_size(V) >= 43),
    ?assertEqual(nomatch, binary:match(V, [<<"+">>, <<"/">>, <<"=">>])).

pkce_challenge_is_deterministic_test() ->
    V = <<"static-verifier-for-determinism">>,
    C1 = barrel_mcp_client_auth_oauth:code_challenge(V),
    C2 = barrel_mcp_client_auth_oauth:code_challenge(V),
    ?assertEqual(C1, C2),
    ?assertEqual(nomatch, binary:match(C1, [<<"+">>, <<"/">>, <<"=">>])).

build_authorization_url_test() ->
    {Url, Verifier, State} = barrel_mcp_client_auth_oauth:build_authorization_url(
        <<"https://as/auth">>,
        #{client_id => <<"cid">>,
          redirect_uri => <<"http://localhost:9999/cb">>,
          resource => <<"https://mcp/server">>,
          scopes => [<<"read">>, <<"write">>]}),
    ?assert(byte_size(Verifier) > 0),
    ?assert(byte_size(State) > 0),
    ?assert(binary:match(Url, <<"response_type=code">>) =/= nomatch),
    ?assert(binary:match(Url, <<"code_challenge_method=S256">>) =/= nomatch),
    ?assert(binary:match(Url, <<"client_id=cid">>) =/= nomatch),
    ?assert(binary:match(Url, <<"resource=">>) =/= nomatch).

%%====================================================================
%% Refresh round-trip against a cowboy mock
%%====================================================================

refresh_round_trip_test_() ->
    {setup,
     fun setup_mock/0,
     fun cleanup_mock/1,
     {timeout, 30, [
         {"discover PRM",            fun test_discover_prm/0},
         {"discover AS metadata",    fun test_discover_as/0},
         {"refresh_token grant",     fun test_refresh_token/0},
         {"behaviour refresh path",  fun test_behaviour_refresh/0}
     ]}}.

setup_mock() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(hackney),
    Dispatch = cowboy_router:compile([{'_', [
        {"/.well-known/oauth-protected-resource", ?MODULE, prm},
        {"/.well-known/oauth-authorization-server", ?MODULE, as},
        {"/oauth/token", ?MODULE, token}
    ]}]),
    {ok, _} = cowboy:start_clear(?MODULE, [{port, ?PORT}],
                                 #{env => #{dispatch => Dispatch}}),
    timer:sleep(100),
    ok.

cleanup_mock(_) ->
    catch cowboy:stop_listener(?MODULE),
    ok.

%% Cowboy handler used as a tiny mock authorization server.
init(Req, prm) ->
    Body = json_encode(#{
        <<"resource">> => <<"http://127.0.0.1:19494/mcp">>,
        <<"authorization_servers">> => [?BASE]
    }),
    R = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, R, prm};
init(Req, as) ->
    Body = json_encode(#{
        <<"issuer">> => ?BASE,
        <<"authorization_endpoint">> => <<?BASE/binary, "/oauth/authorize">>,
        <<"token_endpoint">> => <<?BASE/binary, "/oauth/token">>,
        <<"code_challenge_methods_supported">> => [<<"S256">>]
    }),
    R = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>}, Body, Req),
    {ok, R, as};
init(Req0, token) ->
    {ok, Body, Req} = cowboy_req:read_urlencoded_body(Req0),
    Form = maps:from_list(Body),
    Resp = case maps:get(<<"grant_type">>, Form, undefined) of
        <<"refresh_token">> ->
            <<"old-refresh">> = maps:get(<<"refresh_token">>, Form),
            <<"client-1">> = maps:get(<<"client_id">>, Form),
            <<"http://127.0.0.1:19494/mcp">> =
                maps:get(<<"resource">>, Form),
            #{<<"access_token">> => <<"new-access">>,
              <<"refresh_token">> => <<"new-refresh">>,
              <<"token_type">> => <<"Bearer">>,
              <<"expires_in">> => 3600};
        _ ->
            #{<<"error">> => <<"unsupported_grant_type">>}
    end,
    R = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        json_encode(Resp), Req),
    {ok, R, token}.

json_encode(M) -> iolist_to_binary(json:encode(M)).

%%====================================================================
%% Tests
%%====================================================================

test_discover_prm() ->
    Url = <<?BASE/binary, "/.well-known/oauth-protected-resource">>,
    {ok, Doc} = barrel_mcp_client_auth_oauth:discover_protected_resource(Url),
    ?assertEqual(<<"http://127.0.0.1:19494/mcp">>,
                 maps:get(<<"resource">>, Doc)),
    ?assertEqual([?BASE],
                 maps:get(<<"authorization_servers">>, Doc)).

test_discover_as() ->
    {ok, AS} = barrel_mcp_client_auth_oauth:discover_authorization_server(?BASE),
    ?assertEqual(<<?BASE/binary, "/oauth/token">>,
                 maps:get(<<"token_endpoint">>, AS)).

test_refresh_token() ->
    {ok, Resp} = barrel_mcp_client_auth_oauth:refresh_token(
        <<?BASE/binary, "/oauth/token">>,
        #{refresh_token => <<"old-refresh">>,
          client_id => <<"client-1">>,
          resource => <<"http://127.0.0.1:19494/mcp">>}),
    ?assertEqual(<<"new-access">>, maps:get(<<"access_token">>, Resp)),
    ?assertEqual(<<"new-refresh">>, maps:get(<<"refresh_token">>, Resp)).

test_behaviour_refresh() ->
    %% Build the handle that barrel_mcp_client_auth would produce.
    Auth = barrel_mcp_client_auth:new({oauth, #{
        access_token => <<"old-access">>,
        refresh_token => <<"old-refresh">>,
        token_endpoint => <<?BASE/binary, "/oauth/token">>,
        client_id => <<"client-1">>,
        resource => <<"http://127.0.0.1:19494/mcp">>
    }}),
    ?assertNotMatch({error, _}, Auth),
    ?assertEqual({ok, <<"Bearer old-access">>},
                 barrel_mcp_client_auth:header(Auth)),
    {ok, Auth1} = barrel_mcp_client_auth:refresh(Auth, <<"Bearer error=expired">>),
    ?assertEqual({ok, <<"Bearer new-access">>},
                 barrel_mcp_client_auth:header(Auth1)).
