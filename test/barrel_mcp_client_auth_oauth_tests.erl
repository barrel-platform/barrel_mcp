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
         {"behaviour refresh path",  fun test_behaviour_refresh/0},
         {"client_credentials grant",
          fun test_client_credentials/0},
         {"client_credentials via auth handle",
          fun test_client_credentials_handle/0},
         {"client_credentials with private_key_jwt",
          fun test_client_credentials_jwt/0},
         {"client_credentials re-acquires on 401",
          fun test_client_credentials_refresh/0},
         {"token_exchange grant returns the ID-JAG",
          fun test_token_exchange/0},
         {"jwt_bearer grant returns the access token",
          fun test_jwt_bearer/0},
         {"enterprise-managed chain via auth handle",
          fun test_enterprise_managed_handle/0},
         {"enterprise-managed re-acquires on 401",
          fun test_enterprise_managed_refresh/0},
         {"expired subject_token surfaces typed error",
          fun test_enterprise_managed_subject_token_expired/0},
         {"register_client returns just the client_id",
          fun test_register_client_public/0},
         {"register_client returns client_id + client_secret",
          fun test_register_client_confidential/0},
         {"register_client surfaces 4xx errors",
          fun test_register_client_error/0}
     ]}}.

setup_mock() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(hackney),
    Dispatch = cowboy_router:compile([{'_', [
        {"/.well-known/oauth-protected-resource", ?MODULE, prm},
        {"/.well-known/oauth-authorization-server", ?MODULE, as},
        {"/oauth/token", ?MODULE, token},
        %% IdP token endpoint for the EMA token-exchange step.
        {"/idp/token", ?MODULE, idp_token},
        {"/oauth/register", ?MODULE, register}
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
        <<"client_credentials">> ->
            %% Authentication is via HTTP Basic for the secret path;
            %% the secret-bearing variant strips client_id from body.
            %% The private_key_jwt variant carries client_assertion.
            case maps:get(<<"client_assertion">>, Form, undefined) of
                undefined ->
                    %% client_secret_basic
                    AuthHdr = cowboy_req:header(<<"authorization">>, Req0),
                    true = is_binary(AuthHdr),
                    <<"Basic ", _/binary>> = AuthHdr;
                JWT when is_binary(JWT), JWT =/= <<>> ->
                    <<"urn:ietf:params:oauth:client-assertion-type:"
                      "jwt-bearer">> =
                        maps:get(<<"client_assertion_type">>, Form),
                    %% client_id should still be present in the body
                    %% for private_key_jwt.
                    <<"client-1">> = maps:get(<<"client_id">>, Form)
            end,
            #{<<"access_token">> => <<"cc-access">>,
              <<"token_type">> => <<"Bearer">>,
              <<"expires_in">> => 3600};
        <<"urn:ietf:params:oauth:grant-type:jwt-bearer">> ->
            %% AS-side step of the EMA chain. The body must
            %% carry the ID-JAG under `assertion'. With
            %% client_secret, http_post_form strips client_id
            %% and authenticates via HTTP Basic.
            AuthHdr = cowboy_req:header(<<"authorization">>, Req0),
            true = is_binary(AuthHdr),
            <<"Basic ", _/binary>> = AuthHdr,
            <<"id-jag.signed.jwt">> = maps:get(<<"assertion">>, Form),
            #{<<"access_token">> => <<"ema-access">>,
              <<"token_type">> => <<"Bearer">>,
              <<"expires_in">> => 3600};
        _ ->
            #{<<"error">> => <<"unsupported_grant_type">>}
    end,
    R = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        json_encode(Resp), Req),
    {ok, R, token};
%% Mock IdP token-exchange endpoint for the EMA chain.
init(Req0, idp_token) ->
    {ok, Body, Req} = cowboy_req:read_urlencoded_body(Req0),
    Form = maps:from_list(Body),
    <<"urn:ietf:params:oauth:grant-type:token-exchange">> =
        maps:get(<<"grant_type">>, Form),
    <<"urn:ietf:params:oauth:token-type:id-jag">> =
        maps:get(<<"requested_token_type">>, Form),
    %% subject_token chooses the response shape so tests can
    %% steer between happy path and `subject_token_expired'.
    case maps:get(<<"subject_token">>, Form, undefined) of
        <<"expired-id-token">> ->
            R = cowboy_req:reply(400,
                #{<<"content-type">> => <<"application/json">>},
                json_encode(#{<<"error">> => <<"invalid_grant">>}), Req),
            {ok, R, idp_token};
        Subj when is_binary(Subj), Subj =/= <<>> ->
            %% client_secret_basic strips client_id from the body
            %% and authenticates via the Authorization header.
            AuthHdr = cowboy_req:header(<<"authorization">>, Req0),
            true = is_binary(AuthHdr),
            <<"Basic ", _/binary>> = AuthHdr,
            ?BASE = maps:get(<<"audience">>, Form),
            <<"http://127.0.0.1:19494/mcp">> =
                maps:get(<<"resource">>, Form),
            <<"urn:ietf:params:oauth:token-type:id_token">> =
                maps:get(<<"subject_token_type">>, Form),
            R = cowboy_req:reply(200,
                #{<<"content-type">> => <<"application/json">>},
                json_encode(#{<<"access_token">> => <<"id-jag.signed.jwt">>,
                              <<"issued_token_type">> =>
                                  <<"urn:ietf:params:oauth:token-type:id-jag">>,
                              <<"token_type">> => <<"Bearer">>}), Req),
            {ok, R, idp_token}
    end;
%% Mock dynamic client registration endpoint (RFC 7591).
init(Req0, register) ->
    {ok, Body, Req} = cowboy_req:read_body(Req0),
    Metadata = json:decode(Body),
    Name = maps:get(<<"client_name">>, Metadata, <<"unnamed">>),
    %% Test marker: client_name="confidential" provokes a
    %% client_secret in the response; "bad" provokes a 400.
    case Name of
        <<"bad">> ->
            R = cowboy_req:reply(400,
                #{<<"content-type">> => <<"application/json">>},
                json_encode(#{<<"error">> => <<"invalid_redirect_uri">>}),
                Req),
            {ok, R, register};
        <<"confidential">> ->
            R = cowboy_req:reply(201,
                #{<<"content-type">> => <<"application/json">>},
                json_encode(#{
                    <<"client_id">> => <<"new-client-id">>,
                    <<"client_secret">> => <<"new-secret">>,
                    <<"client_id_issued_at">> => 1700000000,
                    <<"client_secret_expires_at">> => 0,
                    <<"client_name">> => Name
                }), Req),
            {ok, R, register};
        _ ->
            R = cowboy_req:reply(201,
                #{<<"content-type">> => <<"application/json">>},
                json_encode(#{
                    <<"client_id">> => <<"new-client-id">>,
                    <<"client_id_issued_at">> => 1700000000,
                    <<"client_name">> => Name
                }), Req),
            {ok, R, register}
    end.

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

test_client_credentials() ->
    {ok, Resp} = barrel_mcp_client_auth_oauth:client_credentials(
        <<?BASE/binary, "/oauth/token">>,
        #{client_id => <<"client-1">>,
          client_secret => <<"top-secret">>,
          scopes => [<<"read">>, <<"write">>],
          resource => <<"http://127.0.0.1:19494/mcp">>}),
    ?assertEqual(<<"cc-access">>, maps:get(<<"access_token">>, Resp)),
    ?assertEqual(<<"Bearer">>, maps:get(<<"token_type">>, Resp)).

test_client_credentials_handle() ->
    %% End-to-end via the connect-spec entry the user passes to
    %% barrel_mcp_client. init/1 must fetch the token eagerly.
    Auth = barrel_mcp_client_auth:new({oauth_client_credentials, #{
        token_endpoint => <<?BASE/binary, "/oauth/token">>,
        client_id => <<"client-1">>,
        client_secret => <<"top-secret">>,
        resource => <<"http://127.0.0.1:19494/mcp">>
    }}),
    ?assertNotMatch({error, _}, Auth),
    ?assertEqual({ok, <<"Bearer cc-access">>},
                 barrel_mcp_client_auth:header(Auth)).

test_client_credentials_jwt() ->
    %% Private-key JWT (client_assertion) variant: secret omitted,
    %% assertion + assertion_type carried in the form body.
    {ok, Resp} = barrel_mcp_client_auth_oauth:client_credentials(
        <<?BASE/binary, "/oauth/token">>,
        #{client_id => <<"client-1">>,
          client_assertion => <<"signed.jwt.token">>,
          resource => <<"http://127.0.0.1:19494/mcp">>}),
    ?assertEqual(<<"cc-access">>, maps:get(<<"access_token">>, Resp)).

test_client_credentials_refresh() ->
    %% A 401 in client_credentials mode should re-acquire via the
    %% same grant — no refresh_token involved.
    Auth = barrel_mcp_client_auth:new({oauth_client_credentials, #{
        token_endpoint => <<?BASE/binary, "/oauth/token">>,
        client_id => <<"client-1">>,
        client_secret => <<"top-secret">>
    }}),
    ?assertEqual({ok, <<"Bearer cc-access">>},
                 barrel_mcp_client_auth:header(Auth)),
    {ok, Auth1} = barrel_mcp_client_auth:refresh(
                     Auth, <<"Bearer error=expired">>),
    ?assertEqual({ok, <<"Bearer cc-access">>},
                 barrel_mcp_client_auth:header(Auth1)).

%%====================================================================
%% Enterprise-Managed Authorization (RFC 8693 + RFC 7523)
%%====================================================================

test_token_exchange() ->
    %% Direct exchanger: present the ID Token, get back an
    %% ID-JAG (`access_token' field of the response).
    {ok, IdJag} = barrel_mcp_client_auth_oauth:token_exchange(
        <<?BASE/binary, "/idp/token">>,
        #{client_id => <<"client-1">>,
          client_secret => <<"top-secret">>,
          subject_token => <<"oidc-id-token">>,
          subject_token_type =>
              <<"urn:ietf:params:oauth:token-type:id_token">>,
          audience => ?BASE,
          resource => <<"http://127.0.0.1:19494/mcp">>}),
    ?assertEqual(<<"id-jag.signed.jwt">>, IdJag).

test_jwt_bearer() ->
    %% Direct exchanger: present the ID-JAG to the AS token
    %% endpoint, get back the MCP access token.
    {ok, Resp} = barrel_mcp_client_auth_oauth:jwt_bearer(
        <<?BASE/binary, "/oauth/token">>,
        #{client_id => <<"client-1">>,
          client_secret => <<"top-secret">>,
          assertion => <<"id-jag.signed.jwt">>,
          resource => <<"http://127.0.0.1:19494/mcp">>}),
    ?assertEqual(<<"ema-access">>, maps:get(<<"access_token">>, Resp)).

test_enterprise_managed_handle() ->
    %% End-to-end via the connect-spec entry the user passes to
    %% barrel_mcp_client. init/1 walks the EMA chain (token-exchange
    %% then jwt-bearer) and the Authorization header is ready.
    Auth = barrel_mcp_client_auth:new({oauth_enterprise, #{
        idp_token_endpoint => <<?BASE/binary, "/idp/token">>,
        as_token_endpoint => <<?BASE/binary, "/oauth/token">>,
        client_id => <<"client-1">>,
        client_secret => <<"top-secret">>,
        subject_token => <<"oidc-id-token">>,
        subject_token_type =>
            <<"urn:ietf:params:oauth:token-type:id_token">>,
        audience => ?BASE,
        resource => <<"http://127.0.0.1:19494/mcp">>
    }}),
    ?assertNotMatch({error, _}, Auth),
    ?assertEqual({ok, <<"Bearer ema-access">>},
                 barrel_mcp_client_auth:header(Auth)).

test_enterprise_managed_refresh() ->
    %% A 401 in enterprise_managed mode re-walks the chain.
    Auth = barrel_mcp_client_auth:new({oauth_enterprise, #{
        idp_token_endpoint => <<?BASE/binary, "/idp/token">>,
        as_token_endpoint => <<?BASE/binary, "/oauth/token">>,
        client_id => <<"client-1">>,
        client_secret => <<"top-secret">>,
        subject_token => <<"oidc-id-token">>,
        subject_token_type =>
            <<"urn:ietf:params:oauth:token-type:id_token">>,
        audience => ?BASE,
        resource => <<"http://127.0.0.1:19494/mcp">>
    }}),
    {ok, Auth1} = barrel_mcp_client_auth:refresh(
                     Auth, <<"Bearer error=expired">>),
    ?assertEqual({ok, <<"Bearer ema-access">>},
                 barrel_mcp_client_auth:header(Auth1)).

test_enterprise_managed_subject_token_expired() ->
    %% IdP returns invalid_grant — caller learns the typed
    %% subject_token_expired result so it can re-acquire the ID
    %% Token from the IdP.
    Result = barrel_mcp_client_auth:new({oauth_enterprise, #{
        idp_token_endpoint => <<?BASE/binary, "/idp/token">>,
        as_token_endpoint => <<?BASE/binary, "/oauth/token">>,
        client_id => <<"client-1">>,
        client_secret => <<"top-secret">>,
        subject_token => <<"expired-id-token">>,
        subject_token_type =>
            <<"urn:ietf:params:oauth:token-type:id_token">>,
        audience => ?BASE,
        resource => <<"http://127.0.0.1:19494/mcp">>
    }}),
    ?assertEqual({error, subject_token_expired}, Result).

%%====================================================================
%% Dynamic Client Registration (RFC 7591)
%%====================================================================

test_register_client_public() ->
    %% Public client (token_endpoint_auth_method=none): AS issues
    %% just a client_id, no secret.
    {ok, Resp} = barrel_mcp_client_auth_oauth:register_client(
        <<?BASE/binary, "/oauth/register">>,
        #{<<"client_name">> => <<"my-mcp-host">>,
          <<"redirect_uris">> => [<<"http://localhost:5173/cb">>],
          <<"grant_types">> => [<<"authorization_code">>],
          <<"response_types">> => [<<"code">>],
          <<"token_endpoint_auth_method">> => <<"none">>}),
    ?assertEqual(<<"new-client-id">>, maps:get(<<"client_id">>, Resp)),
    ?assertNot(maps:is_key(<<"client_secret">>, Resp)).

test_register_client_confidential() ->
    %% Confidential client: AS issues both client_id and
    %% client_secret. Both flow back to the caller verbatim.
    {ok, Resp} = barrel_mcp_client_auth_oauth:register_client(
        <<?BASE/binary, "/oauth/register">>,
        #{<<"client_name">> => <<"confidential">>,
          <<"grant_types">> => [<<"client_credentials">>]}),
    ?assertEqual(<<"new-client-id">>, maps:get(<<"client_id">>, Resp)),
    ?assertEqual(<<"new-secret">>, maps:get(<<"client_secret">>, Resp)).

test_register_client_error() ->
    %% AS rejects the request with a 4xx; caller learns the
    %% status + body so it can react.
    Result = barrel_mcp_client_auth_oauth:register_client(
        <<?BASE/binary, "/oauth/register">>,
        #{<<"client_name">> => <<"bad">>}),
    ?assertMatch({error, {http_error, 400, _}}, Result).
