%%%-------------------------------------------------------------------
%%% @doc Tests for `barrel_mcp_client_auth_oauth' covering pure
%%% helpers and a refresh-token round-trip against a tiny mock
%%% authorization server (on the project's own `h1' server).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth_oauth_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PORT, 19494).
-define(BASE, <<"http://127.0.0.1:19494">>).

%%====================================================================
%% Pure helpers
%%====================================================================

parse_www_authenticate_with_quotes_test() ->
    H =
        <<"Bearer realm=\"x\", resource_metadata=\"https://srv/.well-known/oauth-protected-resource\", error=\"invalid_token\"">>,
    ?assertEqual(
        <<"https://srv/.well-known/oauth-protected-resource">>,
        barrel_mcp_client_auth_oauth:parse_www_authenticate(H)
    ).

parse_www_authenticate_no_quotes_test() ->
    H = <<"Bearer resource_metadata=https://srv/.well-known/oauth-protected-resource">>,
    ?assertEqual(
        <<"https://srv/.well-known/oauth-protected-resource">>,
        barrel_mcp_client_auth_oauth:parse_www_authenticate(H)
    ).

parse_www_authenticate_missing_test() ->
    ?assertEqual(
        undefined,
        barrel_mcp_client_auth_oauth:parse_www_authenticate(
            <<"Bearer realm=\"x\"">>
        )
    ).

parse_www_authenticate_undefined_test() ->
    ?assertEqual(
        undefined,
        barrel_mcp_client_auth_oauth:parse_www_authenticate(undefined)
    ).

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
        #{
            client_id => <<"cid">>,
            redirect_uri => <<"http://localhost:9999/cb">>,
            resource => <<"https://mcp/server">>,
            scopes => [<<"read">>, <<"write">>]
        }
    ),
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
    {setup, fun setup_mock/0, fun cleanup_mock/1,
        {timeout, 30, [
            {"discover PRM", fun test_discover_prm/0},
            {"discover AS metadata", fun test_discover_as/0},
            {"refresh_token grant", fun test_refresh_token/0},
            {"behaviour refresh path", fun test_behaviour_refresh/0},
            {"client_credentials grant", fun test_client_credentials/0},
            {"client_credentials via auth handle", fun test_client_credentials_handle/0},
            {"client_credentials with private_key_jwt", fun test_client_credentials_jwt/0},
            {"client_credentials re-acquires on 401", fun test_client_credentials_refresh/0},
            {"token_exchange grant returns the ID-JAG", fun test_token_exchange/0},
            {"jwt_bearer grant returns the access token", fun test_jwt_bearer/0},
            {"enterprise-managed chain via auth handle", fun test_enterprise_managed_handle/0},
            {"enterprise-managed re-acquires on 401", fun test_enterprise_managed_refresh/0},
            {"expired subject_token surfaces typed error",
                fun test_enterprise_managed_subject_token_expired/0},
            {"register_client returns just the client_id", fun test_register_client_public/0},
            {"register_client returns client_id + client_secret",
                fun test_register_client_confidential/0},
            {"register_client surfaces 4xx errors", fun test_register_client_error/0},
            {"register_client/3 sends initial access token", fun test_register_client_protected/0},
            {"register_client/2 rejected without initial access token",
                fun test_register_client_protected_unauth/0}
        ]}}.

setup_mock() ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = barrel_mcp_test_http:start(?MODULE, ?PORT, fun handle/1),
    ok.

cleanup_mock(_) ->
    try
        barrel_mcp_test_http:stop(?MODULE)
    catch
        _:_ -> ok
    end,
    ok.

%% Tiny mock authorization server.
handle(#{path := <<"/.well-known/oauth-protected-resource">>}) ->
    {200, json_ct(),
        json_encode(#{
            <<"resource">> => <<"http://127.0.0.1:19494/mcp">>,
            <<"authorization_servers">> => [?BASE]
        })};
handle(#{path := <<"/.well-known/oauth-authorization-server">>}) ->
    {200, json_ct(),
        json_encode(#{
            <<"issuer">> => ?BASE,
            <<"authorization_endpoint">> => <<?BASE/binary, "/oauth/authorize">>,
            <<"token_endpoint">> => <<?BASE/binary, "/oauth/token">>,
            <<"code_challenge_methods_supported">> => [<<"S256">>]
        })};
handle(#{path := <<"/oauth/token">>} = Req) ->
    Form = barrel_mcp_test_http:form(Req),
    Resp =
        case maps:get(<<"grant_type">>, Form, undefined) of
            <<"refresh_token">> ->
                <<"old-refresh">> = maps:get(<<"refresh_token">>, Form),
                <<"client-1">> = maps:get(<<"client_id">>, Form),
                <<"http://127.0.0.1:19494/mcp">> =
                    maps:get(<<"resource">>, Form),
                #{
                    <<"access_token">> => <<"new-access">>,
                    <<"refresh_token">> => <<"new-refresh">>,
                    <<"token_type">> => <<"Bearer">>,
                    <<"expires_in">> => 3600
                };
            <<"client_credentials">> ->
                %% Authentication is via HTTP Basic for the secret path;
                %% the secret-bearing variant strips client_id from body.
                %% The private_key_jwt variant carries client_assertion.
                case maps:get(<<"client_assertion">>, Form, undefined) of
                    undefined ->
                        %% client_secret_basic
                        AuthHdr = barrel_mcp_test_http:header(
                            <<"authorization">>, Req
                        ),
                        true = is_binary(AuthHdr),
                        <<"Basic ", _/binary>> = AuthHdr;
                    JWT when is_binary(JWT), JWT =/= <<>> ->
                        <<
                            "urn:ietf:params:oauth:client-assertion-type:"
                            "jwt-bearer"
                        >> =
                            maps:get(<<"client_assertion_type">>, Form),
                        %% client_id should still be present in the body
                        %% for private_key_jwt.
                        <<"client-1">> = maps:get(<<"client_id">>, Form)
                end,
                #{
                    <<"access_token">> => <<"cc-access">>,
                    <<"token_type">> => <<"Bearer">>,
                    <<"expires_in">> => 3600
                };
            <<"urn:ietf:params:oauth:grant-type:jwt-bearer">> ->
                %% AS-side step of the EMA chain. The body must
                %% carry the ID-JAG under `assertion'. With
                %% client_secret, http_post_form strips client_id
                %% and authenticates via HTTP Basic.
                AuthHdr = barrel_mcp_test_http:header(<<"authorization">>, Req),
                true = is_binary(AuthHdr),
                <<"Basic ", _/binary>> = AuthHdr,
                <<"id-jag.signed.jwt">> = maps:get(<<"assertion">>, Form),
                #{
                    <<"access_token">> => <<"ema-access">>,
                    <<"token_type">> => <<"Bearer">>,
                    <<"expires_in">> => 3600
                };
            _ ->
                #{<<"error">> => <<"unsupported_grant_type">>}
        end,
    {200, json_ct(), json_encode(Resp)};
%% Mock IdP token-exchange endpoint for the EMA chain.
handle(#{path := <<"/idp/token">>} = Req) ->
    Form = barrel_mcp_test_http:form(Req),
    <<"urn:ietf:params:oauth:grant-type:token-exchange">> =
        maps:get(<<"grant_type">>, Form),
    <<"urn:ietf:params:oauth:token-type:id-jag">> =
        maps:get(<<"requested_token_type">>, Form),
    %% subject_token chooses the response shape so tests can
    %% steer between happy path and `subject_token_expired'.
    case maps:get(<<"subject_token">>, Form, undefined) of
        <<"expired-id-token">> ->
            {400, json_ct(), json_encode(#{<<"error">> => <<"invalid_grant">>})};
        Subj when is_binary(Subj), Subj =/= <<>> ->
            %% client_secret_basic strips client_id from the body
            %% and authenticates via the Authorization header.
            AuthHdr = barrel_mcp_test_http:header(<<"authorization">>, Req),
            true = is_binary(AuthHdr),
            <<"Basic ", _/binary>> = AuthHdr,
            ?BASE = maps:get(<<"audience">>, Form),
            <<"http://127.0.0.1:19494/mcp">> =
                maps:get(<<"resource">>, Form),
            <<"urn:ietf:params:oauth:token-type:id_token">> =
                maps:get(<<"subject_token_type">>, Form),
            {200, json_ct(),
                json_encode(#{
                    <<"access_token">> => <<"id-jag.signed.jwt">>,
                    <<"issued_token_type">> =>
                        <<"urn:ietf:params:oauth:token-type:id-jag">>,
                    <<"token_type">> => <<"Bearer">>
                })}
    end;
%% Mock dynamic client registration endpoint (RFC 7591).
handle(#{path := <<"/oauth/register">>, body := Body} = Req) ->
    Metadata = json:decode(Body),
    Name = maps:get(<<"client_name">>, Metadata, <<"unnamed">>),
    %% Test marker: client_name="protected" requires the RFC 7591
    %% initial access token; reject without it.
    AuthHdr = barrel_mcp_test_http:header(<<"authorization">>, Req),
    case Name of
        <<"protected">> when AuthHdr =/= <<"Bearer init-tok">> ->
            {401, json_ct(), json_encode(#{<<"error">> => <<"invalid_token">>})};
        <<"protected">> ->
            {201, json_ct(),
                json_encode(#{
                    <<"client_id">> => <<"protected-client-id">>,
                    <<"client_id_issued_at">> => 1700000000,
                    <<"client_name">> => Name
                })};
        <<"bad">> ->
            {400, json_ct(), json_encode(#{<<"error">> => <<"invalid_redirect_uri">>})};
        <<"confidential">> ->
            {201, json_ct(),
                json_encode(#{
                    <<"client_id">> => <<"new-client-id">>,
                    <<"client_secret">> => <<"new-secret">>,
                    <<"client_id_issued_at">> => 1700000000,
                    <<"client_secret_expires_at">> => 0,
                    <<"client_name">> => Name
                })};
        _ ->
            {201, json_ct(),
                json_encode(#{
                    <<"client_id">> => <<"new-client-id">>,
                    <<"client_id_issued_at">> => 1700000000,
                    <<"client_name">> => Name
                })}
    end.

json_ct() -> #{<<"content-type">> => <<"application/json">>}.

json_encode(M) -> iolist_to_binary(json:encode(M)).

%%====================================================================
%% Tests
%%====================================================================

test_discover_prm() ->
    Url = <<?BASE/binary, "/.well-known/oauth-protected-resource">>,
    {ok, Doc} = barrel_mcp_client_auth_oauth:discover_protected_resource(Url, #{
        allow_insecure_oauth => true
    }),
    ?assertEqual(
        <<"http://127.0.0.1:19494/mcp">>,
        maps:get(<<"resource">>, Doc)
    ),
    ?assertEqual(
        [?BASE],
        maps:get(<<"authorization_servers">>, Doc)
    ).

test_discover_as() ->
    {ok, AS} = barrel_mcp_client_auth_oauth:discover_authorization_server(?BASE, #{
        allow_insecure_oauth => true
    }),
    ?assertEqual(
        <<?BASE/binary, "/oauth/token">>,
        maps:get(<<"token_endpoint">>, AS)
    ).

test_refresh_token() ->
    {ok, Resp} = barrel_mcp_client_auth_oauth:refresh_token(
        <<?BASE/binary, "/oauth/token">>,
        #{
            allow_insecure_oauth => true,
            refresh_token => <<"old-refresh">>,
            client_id => <<"client-1">>,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }
    ),
    ?assertEqual(<<"new-access">>, maps:get(<<"access_token">>, Resp)),
    ?assertEqual(<<"new-refresh">>, maps:get(<<"refresh_token">>, Resp)).

test_behaviour_refresh() ->
    %% Build the handle that barrel_mcp_client_auth would produce.
    Auth = barrel_mcp_client_auth:new(
        {oauth, #{
            allow_insecure_oauth => true,
            access_token => <<"old-access">>,
            refresh_token => <<"old-refresh">>,
            token_endpoint => <<?BASE/binary, "/oauth/token">>,
            client_id => <<"client-1">>,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }}
    ),
    ?assertNotMatch({error, _}, Auth),
    ?assertEqual(
        {ok, <<"Bearer old-access">>},
        barrel_mcp_client_auth:header(Auth)
    ),
    {ok, Auth1} = barrel_mcp_client_auth:refresh(Auth, <<"Bearer error=expired">>),
    ?assertEqual(
        {ok, <<"Bearer new-access">>},
        barrel_mcp_client_auth:header(Auth1)
    ).

test_client_credentials() ->
    {ok, Resp} = barrel_mcp_client_auth_oauth:client_credentials(
        <<?BASE/binary, "/oauth/token">>,
        #{
            allow_insecure_oauth => true,
            client_id => <<"client-1">>,
            client_secret => <<"top-secret">>,
            scopes => [<<"read">>, <<"write">>],
            resource => <<"http://127.0.0.1:19494/mcp">>
        }
    ),
    ?assertEqual(<<"cc-access">>, maps:get(<<"access_token">>, Resp)),
    ?assertEqual(<<"Bearer">>, maps:get(<<"token_type">>, Resp)).

test_client_credentials_handle() ->
    %% End-to-end via the connect-spec entry the user passes to
    %% barrel_mcp_client. init/1 must fetch the token eagerly.
    Auth = barrel_mcp_client_auth:new(
        {oauth_client_credentials, #{
            allow_insecure_oauth => true,
            token_endpoint => <<?BASE/binary, "/oauth/token">>,
            client_id => <<"client-1">>,
            client_secret => <<"top-secret">>,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }}
    ),
    ?assertNotMatch({error, _}, Auth),
    ?assertEqual(
        {ok, <<"Bearer cc-access">>},
        barrel_mcp_client_auth:header(Auth)
    ).

test_client_credentials_jwt() ->
    %% Private-key JWT (client_assertion) variant: secret omitted,
    %% assertion + assertion_type carried in the form body.
    {ok, Resp} = barrel_mcp_client_auth_oauth:client_credentials(
        <<?BASE/binary, "/oauth/token">>,
        #{
            allow_insecure_oauth => true,
            client_id => <<"client-1">>,
            client_assertion => <<"signed.jwt.token">>,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }
    ),
    ?assertEqual(<<"cc-access">>, maps:get(<<"access_token">>, Resp)).

test_client_credentials_refresh() ->
    %% A 401 in client_credentials mode should re-acquire via the
    %% same grant — no refresh_token involved.
    Auth = barrel_mcp_client_auth:new(
        {oauth_client_credentials, #{
            allow_insecure_oauth => true,
            token_endpoint => <<?BASE/binary, "/oauth/token">>,
            client_id => <<"client-1">>,
            client_secret => <<"top-secret">>
        }}
    ),
    ?assertEqual(
        {ok, <<"Bearer cc-access">>},
        barrel_mcp_client_auth:header(Auth)
    ),
    {ok, Auth1} = barrel_mcp_client_auth:refresh(
        Auth, <<"Bearer error=expired">>
    ),
    ?assertEqual(
        {ok, <<"Bearer cc-access">>},
        barrel_mcp_client_auth:header(Auth1)
    ).

%%====================================================================
%% Enterprise-Managed Authorization (RFC 8693 + RFC 7523)
%%====================================================================

test_token_exchange() ->
    %% Direct exchanger: present the ID Token, get back an
    %% ID-JAG (`access_token' field of the response).
    {ok, IdJag} = barrel_mcp_client_auth_oauth:token_exchange(
        <<?BASE/binary, "/idp/token">>,
        #{
            allow_insecure_oauth => true,
            client_id => <<"client-1">>,
            client_secret => <<"top-secret">>,
            subject_token => <<"oidc-id-token">>,
            subject_token_type =>
                <<"urn:ietf:params:oauth:token-type:id_token">>,
            audience => ?BASE,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }
    ),
    ?assertEqual(<<"id-jag.signed.jwt">>, IdJag).

test_jwt_bearer() ->
    %% Direct exchanger: present the ID-JAG to the AS token
    %% endpoint, get back the MCP access token.
    {ok, Resp} = barrel_mcp_client_auth_oauth:jwt_bearer(
        <<?BASE/binary, "/oauth/token">>,
        #{
            allow_insecure_oauth => true,
            client_id => <<"client-1">>,
            client_secret => <<"top-secret">>,
            assertion => <<"id-jag.signed.jwt">>,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }
    ),
    ?assertEqual(<<"ema-access">>, maps:get(<<"access_token">>, Resp)).

test_enterprise_managed_handle() ->
    %% End-to-end via the connect-spec entry the user passes to
    %% barrel_mcp_client. init/1 walks the EMA chain (token-exchange
    %% then jwt-bearer) and the Authorization header is ready.
    Auth = barrel_mcp_client_auth:new(
        {oauth_enterprise, #{
            allow_insecure_oauth => true,
            idp_token_endpoint => <<?BASE/binary, "/idp/token">>,
            as_token_endpoint => <<?BASE/binary, "/oauth/token">>,
            client_id => <<"client-1">>,
            client_secret => <<"top-secret">>,
            subject_token => <<"oidc-id-token">>,
            subject_token_type =>
                <<"urn:ietf:params:oauth:token-type:id_token">>,
            audience => ?BASE,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }}
    ),
    ?assertNotMatch({error, _}, Auth),
    ?assertEqual(
        {ok, <<"Bearer ema-access">>},
        barrel_mcp_client_auth:header(Auth)
    ).

test_enterprise_managed_refresh() ->
    %% A 401 in enterprise_managed mode re-walks the chain.
    Auth = barrel_mcp_client_auth:new(
        {oauth_enterprise, #{
            allow_insecure_oauth => true,
            idp_token_endpoint => <<?BASE/binary, "/idp/token">>,
            as_token_endpoint => <<?BASE/binary, "/oauth/token">>,
            client_id => <<"client-1">>,
            client_secret => <<"top-secret">>,
            subject_token => <<"oidc-id-token">>,
            subject_token_type =>
                <<"urn:ietf:params:oauth:token-type:id_token">>,
            audience => ?BASE,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }}
    ),
    {ok, Auth1} = barrel_mcp_client_auth:refresh(
        Auth, <<"Bearer error=expired">>
    ),
    ?assertEqual(
        {ok, <<"Bearer ema-access">>},
        barrel_mcp_client_auth:header(Auth1)
    ).

test_enterprise_managed_subject_token_expired() ->
    %% IdP returns invalid_grant — caller learns the typed
    %% subject_token_expired result so it can re-acquire the ID
    %% Token from the IdP.
    Result = barrel_mcp_client_auth:new(
        {oauth_enterprise, #{
            allow_insecure_oauth => true,
            idp_token_endpoint => <<?BASE/binary, "/idp/token">>,
            as_token_endpoint => <<?BASE/binary, "/oauth/token">>,
            client_id => <<"client-1">>,
            client_secret => <<"top-secret">>,
            subject_token => <<"expired-id-token">>,
            subject_token_type =>
                <<"urn:ietf:params:oauth:token-type:id_token">>,
            audience => ?BASE,
            resource => <<"http://127.0.0.1:19494/mcp">>
        }}
    ),
    ?assertEqual({error, subject_token_expired}, Result).

%%====================================================================
%% Dynamic Client Registration (RFC 7591)
%%====================================================================

test_register_client_public() ->
    %% Public client (token_endpoint_auth_method=none): AS issues
    %% just a client_id, no secret.
    {ok, Resp} = barrel_mcp_client_auth_oauth:register_client(
        <<?BASE/binary, "/oauth/register">>,
        #{
            <<"client_name">> => <<"my-mcp-host">>,
            <<"redirect_uris">> => [<<"http://localhost:5173/cb">>],
            <<"grant_types">> => [<<"authorization_code">>],
            <<"response_types">> => [<<"code">>],
            <<"token_endpoint_auth_method">> => <<"none">>
        },
        #{allow_insecure_oauth => true}
    ),
    ?assertEqual(<<"new-client-id">>, maps:get(<<"client_id">>, Resp)),
    ?assertNot(maps:is_key(<<"client_secret">>, Resp)).

test_register_client_confidential() ->
    %% Confidential client: AS issues both client_id and
    %% client_secret. Both flow back to the caller verbatim.
    {ok, Resp} = barrel_mcp_client_auth_oauth:register_client(
        <<?BASE/binary, "/oauth/register">>,
        #{
            <<"client_name">> => <<"confidential">>,
            <<"grant_types">> => [<<"client_credentials">>]
        },
        #{allow_insecure_oauth => true}
    ),
    ?assertEqual(<<"new-client-id">>, maps:get(<<"client_id">>, Resp)),
    ?assertEqual(<<"new-secret">>, maps:get(<<"client_secret">>, Resp)).

test_register_client_error() ->
    %% AS rejects the request with a 4xx; caller learns the
    %% status + body so it can react.
    Result = barrel_mcp_client_auth_oauth:register_client(
        <<?BASE/binary, "/oauth/register">>,
        #{<<"client_name">> => <<"bad">>},
        #{allow_insecure_oauth => true}
    ),
    ?assertMatch({error, {http_error, 400, _}}, Result).

test_register_client_protected() ->
    %% Protected registration endpoint: caller passes the
    %% RFC 7591 initial access token via the Opts map, library
    %% sets `Authorization: Bearer ...'.
    {ok, Resp} = barrel_mcp_client_auth_oauth:register_client(
        <<?BASE/binary, "/oauth/register">>,
        #{<<"client_name">> => <<"protected">>},
        #{initial_access_token => <<"init-tok">>, allow_insecure_oauth => true}
    ),
    ?assertEqual(
        <<"protected-client-id">>,
        maps:get(<<"client_id">>, Resp)
    ).

test_register_client_protected_unauth() ->
    %% Same endpoint but no initial access token: AS rejects
    %% with 401, surfaced as {error, {http_error, 401, _}}.
    Result = barrel_mcp_client_auth_oauth:register_client(
        <<?BASE/binary, "/oauth/register">>,
        #{<<"client_name">> => <<"protected">>},
        #{allow_insecure_oauth => true}
    ),
    ?assertMatch({error, {http_error, 401, _}}, Result).

%%====================================================================
%% Authorization response validation (RFC 9207)
%%====================================================================

expected() ->
    #{state => <<"st-1">>, issuer => <<"https://idp.example">>}.

callback_accepts_matching_iss_test() ->
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"st-1">>, <<"iss">> => <<"https://idp.example">>},
            expected()
        )
    ).

%% A server that says nothing about iss is only asked to send it, so
%% its absence cannot be an error or half the servers in the world
%% become unusable.
callback_accepts_absent_iss_test() ->
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"st-1">>},
            expected()
        )
    ).

%% The attack this prevents: a client talking to two authorization
%% servers is handed a code minted by one at the other's endpoint.
callback_rejects_wrong_iss_test() ->
    ?assertMatch(
        {error, {issuer_mismatch, <<"https://evil.example">>, <<"https://idp.example">>}},
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"st-1">>, <<"iss">> => <<"https://evil.example">>},
            expected()
        )
    ).

callback_rejects_wrong_state_test() ->
    ?assertMatch(
        {error, {state_mismatch, <<"other">>, <<"st-1">>}},
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"other">>, <<"iss">> => <<"https://idp.example">>},
            expected()
        )
    ).

%% Nothing to compare against is a caller bug, not a pass.
callback_requires_expectations_test() ->
    ?assertEqual(
        {error, no_expected_state},
        barrel_mcp_client_auth_oauth:validate_callback(#{<<"state">> => <<"x">>}, #{})
    ),
    ?assertEqual(
        {error, no_expected_issuer},
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"st-1">>, <<"iss">> => <<"https://idp.example">>},
            #{state => <<"st-1">>}
        )
    ).

%% Hosts parse query strings into whichever key type they favour.
callback_accepts_atom_keys_test() ->
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:validate_callback(
            #{state => <<"st-1">>, iss => <<"https://idp.example">>},
            expected()
        )
    ).

promising() ->
    (expected())#{
        as_metadata => #{<<"authorization_response_iss_parameter_supported">> => true}
    }.

%% A server that advertises iss and then omits it is not an old server
%% we are tolerating: something stripped the parameter, and the whole
%% point of the check is gone.
callback_rejects_absent_iss_when_advertised_test() ->
    ?assertEqual(
        {error, missing_iss},
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"st-1">>},
            promising()
        )
    ).

callback_accepts_advertised_iss_test() ->
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"st-1">>, <<"iss">> => <<"https://idp.example">>},
            promising()
        )
    ).

%% Metadata that says false, or says nothing, leaves absence tolerated.
callback_tolerates_absent_iss_when_not_advertised_test() ->
    NotPromising = (expected())#{
        as_metadata => #{<<"authorization_response_iss_parameter_supported">> => false}
    },
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"st-1">>}, NotPromising
        )
    ),
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:validate_callback(
            #{<<"state">> => <<"st-1">>}, (expected())#{as_metadata => #{}}
        )
    ).

%% Each of these is a distinct issuer. Normalising any of them away
%% would let a code from one server be redeemed against another.
callback_compares_issuers_exactly_test() ->
    lists:foreach(
        fun(Iss) ->
            ?assertMatch(
                {error, {issuer_mismatch, _, _}},
                barrel_mcp_client_auth_oauth:validate_callback(
                    #{<<"state">> => <<"st-1">>, <<"iss">> => Iss},
                    expected()
                )
            )
        end,
        [
            %% Trailing slash.
            <<"https://idp.example/">>,
            %% Host case folding.
            <<"https://IDP.example">>,
            %% Default-port elision.
            <<"https://idp.example:443">>,
            %% Percent-encoding.
            <<"https://idp%2Eexample">>
        ]
    ).

%%====================================================================
%% Choosing a registration mechanism
%%====================================================================

cimd_as() ->
    #{
        <<"client_id_metadata_document_supported">> => true,
        <<"registration_endpoint">> => <<"https://idp.example/register">>
    }.

%% A relationship that already exists beats anything discoverable.
strategy_prefers_pre_registration_test() ->
    ?assertEqual(
        {pre_registered, <<"cid-1">>},
        barrel_mcp_client_auth_oauth:registration_strategy(
            cimd_as(),
            #{
                client_id => <<"cid-1">>,
                client_id_metadata_url => <<"https://app.example/c.json">>
            }
        )
    ).

strategy_prefers_cimd_over_registration_test() ->
    ?assertEqual(
        {client_id_metadata_document, <<"https://app.example/c.json">>},
        barrel_mcp_client_auth_oauth:registration_strategy(
            cimd_as(),
            #{client_id_metadata_url => <<"https://app.example/c.json">>}
        )
    ).

%% Hosting a document is no use against a server that will not fetch
%% one, so this has to fall through rather than fail.
strategy_falls_back_when_cimd_unsupported_test() ->
    ?assertEqual(
        {dynamic_registration, <<"https://idp.example/register">>},
        barrel_mcp_client_auth_oauth:registration_strategy(
            #{<<"registration_endpoint">> => <<"https://idp.example/register">>},
            #{client_id_metadata_url => <<"https://app.example/c.json">>}
        )
    ).

strategy_uses_registration_endpoint_test() ->
    ?assertEqual(
        {dynamic_registration, <<"https://idp.example/register">>},
        barrel_mcp_client_auth_oauth:registration_strategy(
            #{<<"registration_endpoint">> => <<"https://idp.example/register">>},
            #{}
        )
    ).

%% A client cannot invent an identity, so someone has to supply one.
strategy_prompts_when_nothing_available_test() ->
    ?assertEqual(
        prompt_user,
        barrel_mcp_client_auth_oauth:registration_strategy(#{}, #{})
    ),
    ?assertEqual(
        prompt_user,
        barrel_mcp_client_auth_oauth:registration_strategy(
            #{<<"client_id_metadata_document_supported">> => false}, #{}
        )
    ).

%% Empty is not a client id.
strategy_ignores_blank_values_test() ->
    ?assertEqual(
        prompt_user,
        barrel_mcp_client_auth_oauth:registration_strategy(
            (cimd_as())#{<<"registration_endpoint">> => <<>>},
            #{client_id => <<>>, client_id_metadata_url => <<>>}
        )
    ).

%%====================================================================
%% Client ID Metadata Documents
%%====================================================================

cimd_doc() ->
    #{
        <<"client_id">> => <<"https://app.example/oauth/client.json">>,
        <<"client_name">> => <<"Example MCP Client">>,
        <<"redirect_uris">> => [<<"http://127.0.0.1:3000/callback">>]
    }.

cimd_document_fills_public_client_defaults_test() ->
    {ok, Doc} = barrel_mcp_client_auth_oauth:client_id_metadata_document(cimd_doc()),
    ?assertEqual([<<"authorization_code">>], maps:get(<<"grant_types">>, Doc)),
    ?assertEqual([<<"code">>], maps:get(<<"response_types">>, Doc)),
    ?assertEqual(<<"none">>, maps:get(<<"token_endpoint_auth_method">>, Doc)),
    %% What the caller supplied survives.
    ?assertEqual(
        <<"https://app.example/oauth/client.json">>,
        maps:get(<<"client_id">>, Doc)
    ).

cimd_document_keeps_caller_values_test() ->
    Given = (cimd_doc())#{
        <<"grant_types">> => [<<"authorization_code">>, <<"refresh_token">>],
        <<"token_endpoint_auth_method">> => <<"private_key_jwt">>,
        <<"logo_uri">> => <<"https://app.example/logo.png">>
    },
    {ok, Doc} = barrel_mcp_client_auth_oauth:client_id_metadata_document(Given),
    ?assertEqual(
        [<<"authorization_code">>, <<"refresh_token">>],
        maps:get(<<"grant_types">>, Doc)
    ),
    ?assertEqual(<<"private_key_jwt">>, maps:get(<<"token_endpoint_auth_method">>, Doc)),
    ?assertEqual(<<"https://app.example/logo.png">>, maps:get(<<"logo_uri">>, Doc)).

%% The server rejects a document missing any of these, having already
%% sent the user to a consent page. Better to fail here.
cimd_document_requires_the_mandatory_fields_test() ->
    ?assertEqual(
        {error, {missing, <<"client_id">>}},
        barrel_mcp_client_auth_oauth:client_id_metadata_document(
            maps:remove(<<"client_id">>, cimd_doc())
        )
    ),
    ?assertEqual(
        {error, {missing, <<"client_name">>}},
        barrel_mcp_client_auth_oauth:client_id_metadata_document(
            maps:remove(<<"client_name">>, cimd_doc())
        )
    ),
    ?assertEqual(
        {error, {missing, <<"redirect_uris">>}},
        barrel_mcp_client_auth_oauth:client_id_metadata_document(
            maps:remove(<<"redirect_uris">>, cimd_doc())
        )
    ),
    ?assertEqual(
        {error, {missing, <<"redirect_uris">>}},
        barrel_mcp_client_auth_oauth:client_id_metadata_document(
            (cimd_doc())#{<<"redirect_uris">> => []}
        )
    ).

cimd_document_rejects_a_non_url_client_id_test() ->
    lists:foreach(
        fun(ClientId) ->
            ?assertEqual(
                {error, {invalid_client_id, ClientId}},
                barrel_mcp_client_auth_oauth:client_id_metadata_document(
                    (cimd_doc())#{<<"client_id">> => ClientId}
                )
            )
        end,
        [
            <<"cid-1">>,
            <<"http://app.example/c.json">>,
            <<"https://app.example">>,
            <<"https://app.example/">>
        ]
    ).

client_id_metadata_url_test() ->
    ?assert(
        barrel_mcp_client_auth_oauth:is_client_id_metadata_url(
            <<"https://app.example/c.json">>
        )
    ),
    ?assert(
        barrel_mcp_client_auth_oauth:is_client_id_metadata_url(
            <<"https://app.example/oauth/client-metadata.json">>
        )
    ),
    %% No path: an origin is not an identity.
    ?assertNot(
        barrel_mcp_client_auth_oauth:is_client_id_metadata_url(
            <<"https://app.example">>
        )
    ),
    %% Not https, so the document could be swapped in transit.
    ?assertNot(
        barrel_mcp_client_auth_oauth:is_client_id_metadata_url(
            <<"http://app.example/c.json">>
        )
    ),
    ?assertNot(barrel_mcp_client_auth_oauth:is_client_id_metadata_url(<<"cid-1">>)),
    ?assertNot(barrel_mcp_client_auth_oauth:is_client_id_metadata_url(<<>>)),
    ?assertNot(barrel_mcp_client_auth_oauth:is_client_id_metadata_url(not_a_binary)).

%%====================================================================
%% Authorization server binding
%%====================================================================

binding_accepts_the_issuing_server_test() ->
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:check_issuer_binding(
            #{client_id => <<"cid-1">>, issuer => <<"https://idp.example">>},
            <<"https://idp.example">>
        )
    ).

%% The credentials name a client at the old server. Sending them to
%% the new one hands it an identity it was never given, and fails in a
%% way that reads like a bad token.
binding_rejects_a_changed_server_test() ->
    ?assertEqual(
        {error, {issuer_changed, <<"https://old.example">>, <<"https://new.example">>}},
        barrel_mcp_client_auth_oauth:check_issuer_binding(
            #{client_id => <<"cid-1">>, issuer => <<"https://old.example">>},
            <<"https://new.example">>
        )
    ).

%% Credentials that never recorded where they came from cannot be
%% checked, which is itself the problem.
binding_rejects_unbound_credentials_test() ->
    ?assertEqual(
        {error, unbound_credentials},
        barrel_mcp_client_auth_oauth:check_issuer_binding(
            #{client_id => <<"cid-1">>}, <<"https://idp.example">>
        )
    ).

%% A CIMD client id is a URL any server resolves for itself, so it is
%% not bound to one and survives the server changing.
binding_accepts_a_cimd_client_id_anywhere_test() ->
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:check_issuer_binding(
            #{client_id => <<"https://app.example/c.json">>},
            <<"https://new.example">>
        )
    ),
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:check_issuer_binding(
            #{
                client_id => <<"https://app.example/c.json">>,
                issuer => <<"https://old.example">>
            },
            <<"https://new.example">>
        )
    ).

binding_accepts_binary_keys_test() ->
    ?assertEqual(
        ok,
        barrel_mcp_client_auth_oauth:check_issuer_binding(
            #{<<"client_id">> => <<"cid-1">>, <<"issuer">> => <<"https://idp.example">>},
            <<"https://idp.example">>
        )
    ).

%%====================================================================
%% Authorization server discovery (2026-07-28 rules)
%%====================================================================

-define(DPORT, 19495).
-define(DBASE, <<"http://127.0.0.1:19495">>).
-define(DTAB, oauth_discovery_mock).

discovery_test_() ->
    {setup, fun setup_discovery_mock/0, fun cleanup_discovery_mock/1,
        {timeout, 30, [
            {"path issuer tries the three well-known URLs in order",
                fun test_disc_path_issuer_order/0},
            {"root issuer tries the two root documents", fun test_disc_root_issuer_order/0},
            {"a 500 falls through to the next URL", fun test_disc_fallthrough_on_500/0},
            {"a 200 with malformed JSON falls through", fun test_disc_fallthrough_on_bad_json/0},
            {"an issuer mismatch is terminal", fun test_disc_issuer_mismatch/0},
            {"missing code_challenge_methods_supported is refused", fun test_disc_no_pkce/0},
            {"methods without S256 are refused", fun test_disc_no_s256/0},
            {"a plaintext issuer is refused before any fetch", fun test_disc_insecure_issuer/0},
            {"a plaintext configured token_endpoint is refused by init",
                fun test_insecure_token_endpoint/0},
            {"secure_url accepts https and only https", fun test_secure_url/0}
        ]}}.

setup_discovery_mock() ->
    {ok, _} = application:ensure_all_started(hackney),
    _ = ets:new(?DTAB, [named_table, public, set]),
    {ok, _} = barrel_mcp_test_http:start(discovery_mock, ?DPORT, fun handle_discovery/1),
    ok.

cleanup_discovery_mock(_) ->
    try
        barrel_mcp_test_http:stop(discovery_mock)
    catch
        _:_ -> ok
    end,
    _ =
        try
            ets:delete(?DTAB)
        catch
            _:_ -> ok
        end,
    ok.

%% The mock answers from a script the test installs, `#{Path =>
%% Response}', and logs every path it is asked for.
handle_discovery(#{path := Path}) ->
    true = ets:insert(?DTAB, {{log, erlang:unique_integer([monotonic])}, Path}),
    [{script, Script}] = ets:lookup(?DTAB, script),
    case maps:get(Path, Script, undefined) of
        undefined -> {404, json_ct(), <<"{}">>};
        {Status, Body} when is_binary(Body) -> {Status, json_ct(), Body};
        Doc when is_map(Doc) -> {200, json_ct(), json_encode(Doc)}
    end.

script(Script) ->
    ets:match_delete(?DTAB, {{log, '_'}, '_'}),
    true = ets:insert(?DTAB, {script, Script}).

requested() ->
    [P || {_, P} <- lists:sort(ets:match_object(?DTAB, {{log, '_'}, '_'}))].

good_as(Issuer) ->
    #{
        <<"issuer">> => Issuer,
        <<"authorization_endpoint">> => <<Issuer/binary, "/authorize">>,
        <<"token_endpoint">> => <<Issuer/binary, "/token">>,
        <<"code_challenge_methods_supported">> => [<<"S256">>]
    }.

insecure() -> #{allow_insecure_oauth => true}.

test_disc_path_issuer_order() ->
    Issuer = <<?DBASE/binary, "/tenant1">>,
    script(#{<<"/tenant1/.well-known/openid-configuration">> => good_as(Issuer)}),
    {ok, Doc} = barrel_mcp_client_auth_oauth:discover_authorization_server(Issuer, insecure()),
    ?assertEqual(<<Issuer/binary, "/token">>, maps:get(<<"token_endpoint">>, Doc)),
    ?assertEqual(
        [
            <<"/.well-known/oauth-authorization-server/tenant1">>,
            <<"/.well-known/openid-configuration/tenant1">>,
            <<"/tenant1/.well-known/openid-configuration">>
        ],
        requested()
    ).

test_disc_root_issuer_order() ->
    script(#{<<"/.well-known/openid-configuration">> => good_as(?DBASE)}),
    {ok, _} = barrel_mcp_client_auth_oauth:discover_authorization_server(?DBASE, insecure()),
    ?assertEqual(
        [
            <<"/.well-known/oauth-authorization-server">>,
            <<"/.well-known/openid-configuration">>
        ],
        requested()
    ).

test_disc_fallthrough_on_500() ->
    script(#{
        <<"/.well-known/oauth-authorization-server">> => {500, <<"boom">>},
        <<"/.well-known/openid-configuration">> => good_as(?DBASE)
    }),
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_auth_oauth:discover_authorization_server(?DBASE, insecure())
    ).

test_disc_fallthrough_on_bad_json() ->
    script(#{
        <<"/.well-known/oauth-authorization-server">> => {200, <<"{not json">>},
        <<"/.well-known/openid-configuration">> => good_as(?DBASE)
    }),
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_auth_oauth:discover_authorization_server(?DBASE, insecure())
    ).

test_disc_issuer_mismatch() ->
    script(#{
        <<"/.well-known/oauth-authorization-server">> => good_as(<<"https://honest.example">>),
        <<"/.well-known/openid-configuration">> => good_as(?DBASE)
    }),
    ?assertEqual(
        {error, {issuer_mismatch, <<"https://honest.example">>, ?DBASE}},
        barrel_mcp_client_auth_oauth:discover_authorization_server(?DBASE, insecure())
    ),
    ?assertEqual([<<"/.well-known/oauth-authorization-server">>], requested()).

test_disc_no_pkce() ->
    Doc = maps:remove(<<"code_challenge_methods_supported">>, good_as(?DBASE)),
    script(#{<<"/.well-known/oauth-authorization-server">> => Doc}),
    ?assertEqual(
        {error, no_pkce},
        barrel_mcp_client_auth_oauth:discover_authorization_server(?DBASE, insecure())
    ).

test_disc_no_s256() ->
    Doc = (good_as(?DBASE))#{<<"code_challenge_methods_supported">> => [<<"plain">>]},
    script(#{<<"/.well-known/oauth-authorization-server">> => Doc}),
    ?assertEqual(
        {error, {no_s256, [<<"plain">>]}},
        barrel_mcp_client_auth_oauth:discover_authorization_server(?DBASE, insecure())
    ).

test_disc_insecure_issuer() ->
    script(#{<<"/.well-known/oauth-authorization-server">> => good_as(?DBASE)}),
    ?assertEqual(
        {error, {insecure_url, ?DBASE}},
        barrel_mcp_client_auth_oauth:discover_authorization_server(?DBASE)
    ),
    ?assertEqual([], requested()).

test_insecure_token_endpoint() ->
    Cfg = #{
        access_token => <<"tok">>,
        refresh_token => <<"r">>,
        client_id => <<"c">>,
        token_endpoint => <<?DBASE/binary, "/token">>
    },
    ?assertEqual(
        {error, {insecure_url, <<?DBASE/binary, "/token">>}},
        barrel_mcp_client_auth:new({oauth, Cfg})
    ),
    ?assertNotMatch(
        {error, _}, barrel_mcp_client_auth:new({oauth, Cfg#{allow_insecure_oauth => true}})
    ).

test_secure_url() ->
    ?assertEqual(ok, barrel_mcp_client_auth_oauth:secure_url(<<"https://as.example/x">>, #{})),
    ?assertEqual(
        {error, {insecure_url, <<"http://as.example/x">>}},
        barrel_mcp_client_auth_oauth:secure_url(<<"http://as.example/x">>, #{})
    ),
    ?assertEqual(
        {error, {insecure_url, <<"http://localhost/x">>}},
        barrel_mcp_client_auth_oauth:secure_url(<<"http://localhost/x">>, #{})
    ),
    ?assertEqual(ok, barrel_mcp_client_auth_oauth:secure_url(<<"http://localhost/x">>, insecure())),
    ?assertEqual(
        {error, {insecure_url, undefined}}, barrel_mcp_client_auth_oauth:secure_url(undefined, #{})
    ).
