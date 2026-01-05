%%%-------------------------------------------------------------------
%%% @doc Authentication tests for barrel_mcp.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Fixtures
%%====================================================================

auth_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        %% Header extraction tests
        {"Extract Bearer token from headers", fun test_extract_bearer_token/0},
        {"Extract Bearer token case insensitive", fun test_extract_bearer_case/0},
        {"Extract Bearer token missing", fun test_extract_bearer_missing/0},
        {"Extract API key from X-API-Key header", fun test_extract_apikey_header/0},
        {"Extract API key from Authorization header", fun test_extract_apikey_auth/0},
        {"Extract Basic auth credentials", fun test_extract_basic_auth/0},
        {"Extract Basic auth with empty password", fun test_extract_basic_empty_pwd/0},

        %% No auth provider tests
        {"No auth always succeeds", fun test_auth_none/0},

        %% Bearer auth tests
        {"Bearer auth with valid HS256 JWT", fun test_bearer_hs256_valid/0},
        {"Bearer auth with expired JWT", fun test_bearer_expired/0},
        {"Bearer auth with wrong secret", fun test_bearer_wrong_secret/0},
        {"Bearer auth with custom verifier", fun test_bearer_custom_verifier/0},
        {"Bearer auth validates issuer", fun test_bearer_issuer/0},
        {"Bearer auth validates audience", fun test_bearer_audience/0},
        {"Bearer auth extracts scopes", fun test_bearer_scopes/0},

        %% API key auth tests
        {"API key auth with valid key", fun test_apikey_valid/0},
        {"API key auth with invalid key", fun test_apikey_invalid/0},
        {"API key auth with hashed keys", fun test_apikey_hashed/0},
        {"API key auth with custom verifier", fun test_apikey_custom_verifier/0},

        %% Basic auth tests
        {"Basic auth with valid credentials", fun test_basic_valid/0},
        {"Basic auth with invalid credentials", fun test_basic_invalid/0},
        {"Basic auth with hashed passwords", fun test_basic_hashed/0},

        %% Scope checking
        {"Scope check passes with required scopes", fun test_scope_check_pass/0},
        {"Scope check fails with missing scopes", fun test_scope_check_fail/0},

        %% Custom auth tests
        {"Custom auth init calls module init", fun test_custom_init/0},
        {"Custom auth with valid Bearer token", fun test_custom_bearer_valid/0},
        {"Custom auth with valid X-API-Key", fun test_custom_apikey_valid/0},
        {"Custom auth with invalid token", fun test_custom_invalid/0},
        {"Custom auth missing module fails init", fun test_custom_missing_module/0}
     ]
    }.

setup() ->
    ok.

cleanup(_) ->
    ok.

%%====================================================================
%% Header Extraction Tests
%%====================================================================

test_extract_bearer_token() ->
    Headers = #{<<"authorization">> => <<"Bearer abc123">>},
    ?assertEqual({ok, <<"abc123">>}, barrel_mcp_auth:extract_bearer_token(Headers)).

test_extract_bearer_case() ->
    %% Case insensitive "bearer"
    Headers = #{<<"Authorization">> => <<"bearer xyz789">>},
    ?assertEqual({ok, <<"xyz789">>}, barrel_mcp_auth:extract_bearer_token(Headers)).

test_extract_bearer_missing() ->
    Headers = #{},
    ?assertEqual({error, no_token}, barrel_mcp_auth:extract_bearer_token(Headers)).

test_extract_apikey_header() ->
    Headers = #{<<"x-api-key">> => <<"my-api-key">>},
    ?assertEqual({ok, <<"my-api-key">>}, barrel_mcp_auth:extract_api_key(Headers, #{})).

test_extract_apikey_auth() ->
    Headers = #{<<"authorization">> => <<"ApiKey my-key-123">>},
    ?assertEqual({ok, <<"my-key-123">>}, barrel_mcp_auth:extract_api_key(Headers, #{})).

test_extract_basic_auth() ->
    %% "user:pass" base64 encoded
    Encoded = base64:encode(<<"user:pass">>),
    Headers = #{<<"authorization">> => <<"Basic ", Encoded/binary>>},
    ?assertEqual({ok, <<"user">>, <<"pass">>}, barrel_mcp_auth:extract_basic_auth(Headers)).

test_extract_basic_empty_pwd() ->
    Encoded = base64:encode(<<"user:">>),
    Headers = #{<<"authorization">> => <<"Basic ", Encoded/binary>>},
    ?assertEqual({ok, <<"user">>, <<>>}, barrel_mcp_auth:extract_basic_auth(Headers)).

%%====================================================================
%% No Auth Tests
%%====================================================================

test_auth_none() ->
    {ok, State} = barrel_mcp_auth_none:init(#{}),
    {ok, AuthInfo} = barrel_mcp_auth_none:authenticate(#{}, State),
    ?assertEqual(<<"anonymous">>, maps:get(subject, AuthInfo)).

%%====================================================================
%% Bearer Auth Tests
%%====================================================================

test_bearer_hs256_valid() ->
    Secret = <<"test-secret-key-12345">>,
    Token = create_hs256_jwt(#{
        <<"sub">> => <<"user123">>,
        <<"exp">> => erlang:system_time(second) + 3600
    }, Secret),

    {ok, State} = barrel_mcp_auth_bearer:init(#{secret => Secret}),
    Request = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
    {ok, AuthInfo} = barrel_mcp_auth_bearer:authenticate(Request, State),
    ?assertEqual(<<"user123">>, maps:get(subject, AuthInfo)).

test_bearer_expired() ->
    Secret = <<"test-secret-key-12345">>,
    Token = create_hs256_jwt(#{
        <<"sub">> => <<"user123">>,
        <<"exp">> => erlang:system_time(second) - 3600  % Expired 1 hour ago
    }, Secret),

    {ok, State} = barrel_mcp_auth_bearer:init(#{secret => Secret}),
    Request = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
    ?assertEqual({error, expired_token}, barrel_mcp_auth_bearer:authenticate(Request, State)).

test_bearer_wrong_secret() ->
    Token = create_hs256_jwt(#{<<"sub">> => <<"user123">>}, <<"secret1">>),

    {ok, State} = barrel_mcp_auth_bearer:init(#{secret => <<"different-secret">>}),
    Request = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
    ?assertEqual({error, invalid_token}, barrel_mcp_auth_bearer:authenticate(Request, State)).

test_bearer_custom_verifier() ->
    Verifier = fun(Token) ->
        case Token of
            <<"valid-token">> -> {ok, #{<<"sub">> => <<"custom-user">>}};
            _ -> {error, invalid_token}
        end
    end,

    {ok, State} = barrel_mcp_auth_bearer:init(#{verifier => Verifier}),

    %% Valid token
    Request1 = #{headers => #{<<"authorization">> => <<"Bearer valid-token">>}},
    {ok, AuthInfo} = barrel_mcp_auth_bearer:authenticate(Request1, State),
    ?assertEqual(<<"custom-user">>, maps:get(subject, AuthInfo)),

    %% Invalid token
    Request2 = #{headers => #{<<"authorization">> => <<"Bearer invalid-token">>}},
    ?assertEqual({error, invalid_token}, barrel_mcp_auth_bearer:authenticate(Request2, State)).

test_bearer_issuer() ->
    Secret = <<"test-secret">>,
    Token = create_hs256_jwt(#{
        <<"sub">> => <<"user123">>,
        <<"iss">> => <<"https://auth.example.com">>
    }, Secret),

    %% Correct issuer
    {ok, State1} = barrel_mcp_auth_bearer:init(#{
        secret => Secret,
        issuer => <<"https://auth.example.com">>
    }),
    Request = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
    {ok, _} = barrel_mcp_auth_bearer:authenticate(Request, State1),

    %% Wrong issuer
    {ok, State2} = barrel_mcp_auth_bearer:init(#{
        secret => Secret,
        issuer => <<"https://other.example.com">>
    }),
    ?assertEqual({error, invalid_token}, barrel_mcp_auth_bearer:authenticate(Request, State2)).

test_bearer_audience() ->
    Secret = <<"test-secret">>,
    Token = create_hs256_jwt(#{
        <<"sub">> => <<"user123">>,
        <<"aud">> => <<"https://api.example.com">>
    }, Secret),

    %% Correct audience
    {ok, State1} = barrel_mcp_auth_bearer:init(#{
        secret => Secret,
        audience => <<"https://api.example.com">>
    }),
    Request = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
    {ok, _} = barrel_mcp_auth_bearer:authenticate(Request, State1),

    %% Wrong audience
    {ok, State2} = barrel_mcp_auth_bearer:init(#{
        secret => Secret,
        audience => <<"https://other.example.com">>
    }),
    ?assertEqual({error, invalid_token}, barrel_mcp_auth_bearer:authenticate(Request, State2)).

test_bearer_scopes() ->
    Secret = <<"test-secret">>,
    Token = create_hs256_jwt(#{
        <<"sub">> => <<"user123">>,
        <<"scope">> => <<"read write admin">>
    }, Secret),

    {ok, State} = barrel_mcp_auth_bearer:init(#{secret => Secret}),
    Request = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
    {ok, AuthInfo} = barrel_mcp_auth_bearer:authenticate(Request, State),
    Scopes = maps:get(scopes, AuthInfo),
    ?assertEqual([<<"read">>, <<"write">>, <<"admin">>], Scopes).

%%====================================================================
%% API Key Tests
%%====================================================================

test_apikey_valid() ->
    Keys = #{<<"key-123">> => #{subject => <<"user1">>, scopes => [<<"read">>]}},
    {ok, State} = barrel_mcp_auth_apikey:init(#{keys => Keys}),

    Request = #{headers => #{<<"x-api-key">> => <<"key-123">>}},
    {ok, AuthInfo} = barrel_mcp_auth_apikey:authenticate(Request, State),
    ?assertEqual(<<"user1">>, maps:get(subject, AuthInfo)).

test_apikey_invalid() ->
    Keys = #{<<"key-123">> => #{subject => <<"user1">>}},
    {ok, State} = barrel_mcp_auth_apikey:init(#{keys => Keys}),

    Request = #{headers => #{<<"x-api-key">> => <<"wrong-key">>}},
    ?assertEqual({error, invalid_credentials}, barrel_mcp_auth_apikey:authenticate(Request, State)).

test_apikey_hashed() ->
    %% Store hashed key
    PlainKey = <<"my-secret-api-key">>,
    HashedKey = barrel_mcp_auth_apikey:hash_key(PlainKey),
    Keys = #{HashedKey => #{subject => <<"user1">>}},

    {ok, State} = barrel_mcp_auth_apikey:init(#{keys => Keys, hash_keys => true}),

    Request = #{headers => #{<<"x-api-key">> => PlainKey}},
    {ok, AuthInfo} = barrel_mcp_auth_apikey:authenticate(Request, State),
    ?assertEqual(<<"user1">>, maps:get(subject, AuthInfo)).

test_apikey_custom_verifier() ->
    Verifier = fun(Key) ->
        case Key of
            <<"special-key">> -> {ok, #{subject => <<"special-user">>}};
            _ -> {error, invalid_credentials}
        end
    end,

    {ok, State} = barrel_mcp_auth_apikey:init(#{verifier => Verifier}),

    Request = #{headers => #{<<"x-api-key">> => <<"special-key">>}},
    {ok, AuthInfo} = barrel_mcp_auth_apikey:authenticate(Request, State),
    ?assertEqual(<<"special-user">>, maps:get(subject, AuthInfo)).

%%====================================================================
%% Basic Auth Tests
%%====================================================================

test_basic_valid() ->
    Creds = #{<<"admin">> => <<"password123">>},
    {ok, State} = barrel_mcp_auth_basic:init(#{credentials => Creds}),

    Encoded = base64:encode(<<"admin:password123">>),
    Request = #{headers => #{<<"authorization">> => <<"Basic ", Encoded/binary>>}},
    {ok, AuthInfo} = barrel_mcp_auth_basic:authenticate(Request, State),
    ?assertEqual(<<"admin">>, maps:get(subject, AuthInfo)).

test_basic_invalid() ->
    Creds = #{<<"admin">> => <<"password123">>},
    {ok, State} = barrel_mcp_auth_basic:init(#{credentials => Creds}),

    Encoded = base64:encode(<<"admin:wrongpassword">>),
    Request = #{headers => #{<<"authorization">> => <<"Basic ", Encoded/binary>>}},
    ?assertEqual({error, invalid_credentials}, barrel_mcp_auth_basic:authenticate(Request, State)).

test_basic_hashed() ->
    PlainPassword = <<"mypassword">>,
    HashedPassword = barrel_mcp_auth_basic:hash_password(PlainPassword),
    Creds = #{<<"user">> => HashedPassword},

    {ok, State} = barrel_mcp_auth_basic:init(#{credentials => Creds, hash_passwords => true}),

    Encoded = base64:encode(<<"user:mypassword">>),
    Request = #{headers => #{<<"authorization">> => <<"Basic ", Encoded/binary>>}},
    {ok, AuthInfo} = barrel_mcp_auth_basic:authenticate(Request, State),
    ?assertEqual(<<"user">>, maps:get(subject, AuthInfo)).

%%====================================================================
%% Scope Check Tests
%%====================================================================

test_scope_check_pass() ->
    Secret = <<"test-secret">>,
    Token = create_hs256_jwt(#{
        <<"sub">> => <<"user123">>,
        <<"scope">> => <<"read write">>
    }, Secret),

    {ok, ProviderState} = barrel_mcp_auth_bearer:init(#{secret => Secret}),
    Config = #{
        provider => barrel_mcp_auth_bearer,
        provider_state => ProviderState,
        required_scopes => [<<"read">>]
    },

    Request = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
    {ok, _AuthInfo} = barrel_mcp_auth:authenticate(Config, Request, Config).

test_scope_check_fail() ->
    Secret = <<"test-secret">>,
    Token = create_hs256_jwt(#{
        <<"sub">> => <<"user123">>,
        <<"scope">> => <<"read">>
    }, Secret),

    {ok, ProviderState} = barrel_mcp_auth_bearer:init(#{secret => Secret}),
    Config = #{
        provider => barrel_mcp_auth_bearer,
        provider_state => ProviderState,
        required_scopes => [<<"write">>]  % User doesn't have write scope
    },

    Request = #{headers => #{<<"authorization">> => <<"Bearer ", Token/binary>>}},
    ?assertEqual({error, insufficient_scope}, barrel_mcp_auth:authenticate(Config, Request, Config)).

%%====================================================================
%% Helper Functions
%%====================================================================

create_hs256_jwt(Claims, Secret) ->
    Header = #{<<"alg">> => <<"HS256">>, <<"typ">> => <<"JWT">>},
    HeaderB64 = base64url_encode(iolist_to_binary(json:encode(Header))),
    ClaimsB64 = base64url_encode(iolist_to_binary(json:encode(Claims))),
    SigningInput = <<HeaderB64/binary, ".", ClaimsB64/binary>>,
    Signature = crypto:mac(hmac, sha256, Secret, SigningInput),
    SignatureB64 = base64url_encode(Signature),
    <<HeaderB64/binary, ".", ClaimsB64/binary, ".", SignatureB64/binary>>.

base64url_encode(Data) ->
    B64 = base64:encode(Data),
    %% Remove padding and convert to URL-safe
    NoPad = binary:replace(B64, <<"=">>, <<>>, [global]),
    Url1 = binary:replace(NoPad, <<"+">>, <<"-">>, [global]),
    binary:replace(Url1, <<"/">>, <<"_">>, [global]).

%%====================================================================
%% Custom Auth Tests
%%====================================================================

test_custom_init() ->
    {ok, State} = barrel_mcp_auth_custom:init(#{module => test_auth_module}),
    ?assertEqual(test_auth_module, maps:get(module, State)),
    ?assert(maps:is_key(module_state, State)).

test_custom_bearer_valid() ->
    {ok, State} = barrel_mcp_auth_custom:init(#{module => test_auth_module}),
    Request = #{headers => #{<<"authorization">> => <<"Bearer valid-token">>}},
    {ok, AuthInfo} = barrel_mcp_auth_custom:authenticate(Request, State),
    ?assertEqual(<<"test-user">>, maps:get(subject, AuthInfo)).

test_custom_apikey_valid() ->
    {ok, State} = barrel_mcp_auth_custom:init(#{module => test_auth_module}),
    Request = #{headers => #{<<"x-api-key">> => <<"valid-token">>}},
    {ok, AuthInfo} = barrel_mcp_auth_custom:authenticate(Request, State),
    ?assertEqual(<<"test-user">>, maps:get(subject, AuthInfo)).

test_custom_invalid() ->
    {ok, State} = barrel_mcp_auth_custom:init(#{module => test_auth_module}),
    Request = #{headers => #{<<"authorization">> => <<"Bearer invalid-token">>}},
    ?assertEqual({error, invalid_token}, barrel_mcp_auth_custom:authenticate(Request, State)).

test_custom_missing_module() ->
    ?assertEqual({error, missing_module}, barrel_mcp_auth_custom:init(#{})).
