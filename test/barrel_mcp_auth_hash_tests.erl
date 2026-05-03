%%%-------------------------------------------------------------------
%%% @doc Tests for the modern hash formats added to
%%% `barrel_mcp_auth_basic' (PBKDF2-SHA256) and
%%% `barrel_mcp_auth_apikey' (HMAC-SHA256), plus backward
%%% compatibility with the legacy hex SHA-256 digests.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_hash_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% basic auth — pbkdf2-sha256
%%====================================================================

basic_default_uses_pbkdf2_test() ->
    H = barrel_mcp_auth_basic:hash_password(<<"hunter2">>),
    ?assertMatch(<<"pbkdf2-sha256$", _/binary>>, H).

basic_pbkdf2_round_trip_test() ->
    H = barrel_mcp_auth_basic:hash_password(<<"hunter2">>),
    ?assertEqual(ok, barrel_mcp_auth_basic:verify_password(<<"hunter2">>, H)),
    ?assertEqual({error, invalid_credentials},
                 barrel_mcp_auth_basic:verify_password(<<"nope">>, H)).

basic_pbkdf2_uses_random_salt_test() ->
    %% Two hashes of the same password must differ (random salt).
    H1 = barrel_mcp_auth_basic:hash_password(<<"hunter2">>),
    H2 = barrel_mcp_auth_basic:hash_password(<<"hunter2">>),
    ?assertNotEqual(H1, H2),
    ?assertEqual(ok, barrel_mcp_auth_basic:verify_password(<<"hunter2">>, H1)),
    ?assertEqual(ok, barrel_mcp_auth_basic:verify_password(<<"hunter2">>, H2)).

basic_legacy_sha256_still_verifies_test() ->
    %% Legacy stored format (hex SHA-256) still verifies (deprecated
    %% path, with a warning logged).
    Legacy = barrel_mcp_auth_basic:hash_password(<<"hunter2">>,
                                                  #{algorithm => 'sha256-hex'}),
    ?assertEqual(64, byte_size(Legacy)),
    ?assertEqual(ok, barrel_mcp_auth_basic:verify_password(<<"hunter2">>, Legacy)),
    ?assertEqual({error, invalid_credentials},
                 barrel_mcp_auth_basic:verify_password(<<"nope">>, Legacy)).

basic_iterations_are_overridable_test() ->
    H = barrel_mcp_auth_basic:hash_password(<<"x">>,
                                             #{iterations => 1000}),
    ?assertMatch(<<"pbkdf2-sha256$1000$", _/binary>>, H),
    ?assertEqual(ok, barrel_mcp_auth_basic:verify_password(<<"x">>, H)).

%%====================================================================
%% apikey auth — hmac-sha256
%%====================================================================

apikey_legacy_default_test() ->
    %% `hash_key/1' stays on the legacy hex SHA-256 form for one
    %% release.
    H = barrel_mcp_auth_apikey:hash_key(<<"my-key">>),
    ?assertEqual(64, byte_size(H)),
    ?assertEqual(ok, barrel_mcp_auth_apikey:verify_key(<<"my-key">>, H)),
    ?assertEqual({error, invalid_credentials},
                 barrel_mcp_auth_apikey:verify_key(<<"other">>, H)).

apikey_hmac_format_test() ->
    H = barrel_mcp_auth_apikey:hash_key(<<"my-key">>,
                                         #{pepper => <<"secret-pepper">>}),
    ?assertMatch(<<"hmac-sha256$", _/binary>>, H).

apikey_hmac_is_pepper_dependent_test() ->
    H1 = barrel_mcp_auth_apikey:hash_key(<<"my-key">>,
                                          #{pepper => <<"a">>}),
    H2 = barrel_mcp_auth_apikey:hash_key(<<"my-key">>,
                                          #{pepper => <<"b">>}),
    ?assertNotEqual(H1, H2).

%%====================================================================
%% verify_key/3 (correct HMAC verification with pepper)
%%====================================================================

apikey_verify_with_pepper_round_trip_test() ->
    Pepper = <<"the-actual-pepper">>,
    H = barrel_mcp_auth_apikey:hash_key(<<"k1">>, #{pepper => Pepper}),
    ?assertEqual(ok, barrel_mcp_auth_apikey:verify_key(<<"k1">>, H, Pepper)),
    ?assertEqual({error, invalid_credentials},
                 barrel_mcp_auth_apikey:verify_key(<<"wrong">>, H, Pepper)).

apikey_verify_with_wrong_pepper_fails_test() ->
    H = barrel_mcp_auth_apikey:hash_key(<<"k1">>, #{pepper => <<"good">>}),
    ?assertEqual({error, invalid_credentials},
                 barrel_mcp_auth_apikey:verify_key(<<"k1">>, H, <<"bad">>)).

apikey_verify_2arity_rejects_hmac_format_test() ->
    H = barrel_mcp_auth_apikey:hash_key(<<"k1">>, #{pepper => <<"p">>}),
    %% 2-arity helper has no pepper; it must NOT silently accept.
    ?assertEqual({error, pepper_required},
                 barrel_mcp_auth_apikey:verify_key(<<"k1">>, H)).

apikey_provider_init_keeps_pepper_test() ->
    {ok, State} = barrel_mcp_auth_apikey:init(#{
        keys => #{},
        hash_keys => true,
        pepper => <<"persistent">>
    }),
    ?assertEqual(<<"persistent">>, maps:get(pepper, State)).

apikey_provider_authenticate_with_hmac_test() ->
    Pepper = <<"shhh">>,
    Key = <<"client-1-key">>,
    Stored = barrel_mcp_auth_apikey:hash_key(Key, #{pepper => Pepper}),
    {ok, State} = barrel_mcp_auth_apikey:init(#{
        keys => #{Stored => #{subject => <<"client-1">>}},
        hash_keys => true,
        pepper => Pepper
    }),
    Req = #{headers => #{<<"x-api-key">> => Key}},
    ?assertMatch({ok, #{subject := <<"client-1">>}},
                 barrel_mcp_auth_apikey:authenticate(Req, State)),
    %% Wrong key must fail.
    BadReq = #{headers => #{<<"x-api-key">> => <<"nope">>}},
    ?assertMatch({error, _},
                 barrel_mcp_auth_apikey:authenticate(BadReq, State)).
