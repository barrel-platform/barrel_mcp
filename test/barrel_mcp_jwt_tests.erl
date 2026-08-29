-module(barrel_mcp_jwt_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

es256_round_trip_test() ->
    Key = barrel_mcp_jwt:generate_key(),
    Jwt = barrel_mcp_jwt:sign(#{<<"sub">> => <<"me">>}, Key, <<"ES256">>),
    [H, P, S] = binary:split(Jwt, <<".">>, [global]),
    ?assertEqual(#{<<"alg">> => <<"ES256">>, <<"typ">> => <<"JWT">>}, json:decode(b64d(H))),
    ?assertEqual(#{<<"sub">> => <<"me">>}, json:decode(b64d(P))),
    <<R:256, Sg:256>> = b64d(S),
    Der = public_key:der_encode('ECDSA-Sig-Value', #'ECDSA-Sig-Value'{r = R, s = Sg}),
    Public = {#'ECPoint'{point = Key#'ECPrivateKey'.publicKey}, Key#'ECPrivateKey'.parameters},
    ?assert(public_key:verify(<<H/binary, ".", P/binary>>, sha256, Der, Public)).

hs256_test() ->
    Jwt = barrel_mcp_jwt:sign(#{<<"a">> => 1}, {hmac, <<"secret">>}, <<"HS256">>),
    [H, P, S] = binary:split(Jwt, <<".">>, [global]),
    ?assertEqual(
        crypto:mac(hmac, sha256, <<"secret">>, <<H/binary, ".", P/binary>>), b64d(S)
    ).

pem_round_trip_test() ->
    Key = barrel_mcp_jwt:generate_key(),
    Pem = public_key:pem_encode([public_key:pem_entry_encode('ECPrivateKey', Key)]),
    Decoded = barrel_mcp_jwt:decode_pem(Pem),
    ?assertEqual(Key#'ECPrivateKey'.publicKey, Decoded#'ECPrivateKey'.publicKey),
    %% PKCS#8, the shape the conformance runner hands out.
    Pkcs8 = public_key:pem_encode([public_key:pem_entry_encode('PrivateKeyInfo', Key)]),
    Decoded8 = barrel_mcp_jwt:decode_pem(Pkcs8),
    ?assertEqual(Key#'ECPrivateKey'.publicKey, Decoded8#'ECPrivateKey'.publicKey).

jwk_and_thumbprint_test() ->
    Key = barrel_mcp_jwt:generate_key(),
    #{<<"kty">> := <<"EC">>, <<"crv">> := <<"P-256">>, <<"x">> := X, <<"y">> := Y} =
        barrel_mcp_jwt:jwk(Key),
    ?assertEqual(32, byte_size(b64d(X))),
    ?assertEqual(32, byte_size(b64d(Y))),
    %% RFC 7638 3.1: the members in lexical order, no whitespace.
    Expected = barrel_mcp_jwt:b64url(
        crypto:hash(
            sha256,
            <<"{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"", X/binary, "\",\"y\":\"", Y/binary,
                "\"}">>
        )
    ),
    ?assertEqual(Expected, barrel_mcp_jwt:thumbprint(barrel_mcp_jwt:jwk(Key))).

b64d(B) ->
    base64:decode(B, #{mode => urlsafe, padding => false}).
