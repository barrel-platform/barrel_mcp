%%%-------------------------------------------------------------------
%%% @doc The little JOSE the OAuth client needs: signing a JWT with
%%% ES256, RS256 or HS256, a P-256 key as a JWK, and its RFC 7638
%%% thumbprint. Used for `private_key_jwt' client assertions
%%% (RFC 7523) and DPoP proofs (RFC 9449).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_jwt).

-include_lib("public_key/include/public_key.hrl").

-export([sign/3, sign/4, decode_pem/1, generate_key/0, jwk/1, thumbprint/1, b64url/1]).

-type key() :: public_key:ecdsa_private_key() | public_key:rsa_private_key() | {hmac, binary()}.
-type alg() :: binary().

-export_type([key/0, alg/0]).

%% @doc A signed JWT for `Claims' (binary-keyed map) with the header
%% `{"alg": Alg, "typ": "JWT"}'.
-spec sign(map(), key(), alg()) -> binary().
sign(Claims, Key, Alg) ->
    sign(#{<<"typ">> => <<"JWT">>}, Claims, Key, Alg).

%% @doc As {@link sign/3} with extra header members (`typ', `jwk', ...).
-spec sign(map(), map(), key(), alg()) -> binary().
sign(Header, Claims, Key, Alg) when is_map(Header), is_map(Claims) ->
    Head = b64url(iolist_to_binary(json:encode(Header#{<<"alg">> => Alg}))),
    Body = b64url(iolist_to_binary(json:encode(Claims))),
    Input = <<Head/binary, ".", Body/binary>>,
    <<Input/binary, ".", (b64url(signature(Input, Key, Alg)))/binary>>.

signature(Input, {hmac, Secret}, <<"HS256">>) ->
    crypto:mac(hmac, sha256, Secret, Input);
signature(Input, #'RSAPrivateKey'{} = Key, <<"RS256">>) ->
    public_key:sign(Input, sha256, Key);
signature(Input, #'ECPrivateKey'{} = Key, <<"ES256">>) ->
    %% JWS wants the raw R || S pair, not the DER sequence.
    #'ECDSA-Sig-Value'{r = R, s = S} =
        public_key:der_decode('ECDSA-Sig-Value', public_key:sign(Input, sha256, Key)),
    <<R:256, S:256>>;
signature(_Input, Key, Alg) ->
    error({unsupported_signature, Alg, element(1, Key)}).

%% @doc The private key in a PEM, PKCS#8 (`PRIVATE KEY') or the
%% type-specific encodings.
-spec decode_pem(binary()) -> key().
decode_pem(Pem) ->
    [Entry | _] = public_key:pem_decode(Pem),
    case public_key:pem_entry_decode(Entry) of
        #'PrivateKeyInfo'{} = Info -> unwrap_pkcs8(Info);
        Key -> Key
    end.

%% Older OTP releases hand back the PKCS#8 wrapper rather than the key.
unwrap_pkcs8(#'PrivateKeyInfo'{privateKeyAlgorithm = Algorithm, privateKey = Der}) ->
    #'PrivateKeyInfo_privateKeyAlgorithm'{algorithm = Oid, parameters = Params} = Algorithm,
    case Oid of
        ?'id-ecPublicKey' ->
            Key = public_key:der_decode('ECPrivateKey', iolist_to_binary(Der)),
            Curve =
                case Params of
                    {asn1_OPENTYPE, Bin} -> public_key:der_decode('EcpkParameters', Bin);
                    Other -> Other
                end,
            Key#'ECPrivateKey'{parameters = Curve};
        ?'rsaEncryption' ->
            public_key:der_decode('RSAPrivateKey', iolist_to_binary(Der))
    end.

%% @doc A fresh P-256 key, for DPoP.
-spec generate_key() -> public_key:ecdsa_private_key().
generate_key() ->
    public_key:generate_key({namedCurve, secp256r1}).

%% @doc The public half of a P-256 key as a JWK (RFC 7518 6.2.1).
-spec jwk(public_key:ecdsa_private_key()) -> map().
jwk(#'ECPrivateKey'{publicKey = <<4, X:32/binary, Y:32/binary>>}) ->
    #{
        <<"kty">> => <<"EC">>,
        <<"crv">> => <<"P-256">>,
        <<"x">> => b64url(X),
        <<"y">> => b64url(Y)
    }.

%% @doc RFC 7638: SHA-256 of the required members, lexically ordered,
%% serialised without whitespace.
-spec thumbprint(map()) -> binary().
thumbprint(#{<<"kty">> := <<"EC">>, <<"crv">> := Crv, <<"x">> := X, <<"y">> := Y}) ->
    Canonical =
        <<"{\"crv\":\"", Crv/binary, "\",\"kty\":\"EC\",\"x\":\"", X/binary, "\",\"y\":\"",
            Y/binary, "\"}">>,
    b64url(crypto:hash(sha256, Canonical)).

-spec b64url(binary()) -> binary().
b64url(Bin) ->
    base64:encode(Bin, #{mode => urlsafe, padding => false}).
