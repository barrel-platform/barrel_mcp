%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024 Benoit Chesneau
%%% @doc Bearer token authentication provider for barrel_mcp.
%%%
%%% Supports JWT validation (HS256 built-in, RS256/ES256 via custom verifier),
%%% opaque tokens, and standard claims validation (iss, aud, exp, nbf).
%%%
%%% == Configuration Options ==
%%%
%%% <ul>
%%%   <li>`verifier' - Custom verification function for tokens</li>
%%%   <li>`secret' - HMAC secret for HS256 JWT validation</li>
%%%   <li>`issuer' - Expected issuer (iss claim)</li>
%%%   <li>`audience' - Expected audience (aud claim)</li>
%%%   <li>`clock_skew' - Allowed clock skew in seconds (default: 60)</li>
%%%   <li>`scope_claim' - Claim name for scopes (default: scope)</li>
%%%   <li>`realm' - Realm for WWW-Authenticate header</li>
%%%   <li>`resource' - Resource identifier for RFC 8707</li>
%%% </ul>
%%%
%%% @see barrel_mcp_auth
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_bearer).

-behaviour(barrel_mcp_auth).

%% barrel_mcp_auth callbacks
-export([
    init/1,
    authenticate/2,
    challenge/2
]).

%% JWT utilities (exported for testing)
-export([
    decode_jwt/1,
    verify_hs256/2,
    validate_claims/2
]).

-define(DEFAULT_CLOCK_SKEW, 60).
-define(DEFAULT_SCOPE_CLAIM, <<"scope">>).

%%====================================================================
%% barrel_mcp_auth callbacks
%%====================================================================

%% @doc Initialize the Bearer token provider.
-spec init(map()) -> {ok, map()}.
init(Opts) ->
    State = #{
        verifier => maps:get(verifier, Opts, undefined),
        secret => maps:get(secret, Opts, undefined),
        issuer => maps:get(issuer, Opts, undefined),
        audience => maps:get(audience, Opts, undefined),
        clock_skew => maps:get(clock_skew, Opts, ?DEFAULT_CLOCK_SKEW),
        scope_claim => maps:get(scope_claim, Opts, ?DEFAULT_SCOPE_CLAIM),
        realm => maps:get(realm, Opts, <<"mcp">>),
        resource => maps:get(resource, Opts, undefined)
    },
    {ok, State}.

%% @doc Authenticate a request using Bearer token.
-spec authenticate(map(), map()) ->
    {ok, barrel_mcp_auth:auth_info()} | {error, barrel_mcp_auth:auth_error()}.
authenticate(Request, State) ->
    Headers = maps:get(headers, Request, #{}),
    case barrel_mcp_auth:extract_bearer_token(Headers) of
        {ok, Token} ->
            verify_token(Token, State);
        {error, no_token} ->
            {error, unauthorized}
    end.

%% @doc Generate a WWW-Authenticate challenge.
-spec challenge(barrel_mcp_auth:auth_error(), map()) ->
    {integer(), map(), binary()}.
challenge(Reason, State) ->
    Realm = maps:get(realm, State, <<"mcp">>),
    Resource = maps:get(resource, State, undefined),

    {StatusCode, ErrorCode, ErrorDesc} = error_details(Reason),

    %% Build WWW-Authenticate header per RFC 6750 and MCP spec
    Challenge = build_challenge(Realm, ErrorCode, ErrorDesc, Resource),

    Body = iolist_to_binary(json:encode(#{
        <<"error">> => ErrorCode,
        <<"error_description">> => ErrorDesc
    })),

    {StatusCode, #{
        <<"www-authenticate">> => Challenge,
        <<"content-type">> => <<"application/json">>
    }, Body}.

%%====================================================================
%% Token verification
%%====================================================================

verify_token(Token, #{verifier := Verifier} = State) when is_function(Verifier, 1) ->
    %% Custom verifier function
    case Verifier(Token) of
        {ok, Claims} when is_map(Claims) ->
            validate_and_build_auth_info(Claims, State);
        {error, _} = Error ->
            Error
    end;
verify_token(Token, #{secret := Secret} = State) when Secret =/= undefined ->
    %% JWT with HS256
    case decode_jwt(Token) of
        {ok, Header, Claims, _Signature} ->
            case maps:get(<<"alg">>, Header, undefined) of
                <<"HS256">> ->
                    case verify_hs256(Token, Secret) of
                        true ->
                            validate_and_build_auth_info(Claims, State);
                        false ->
                            {error, invalid_token}
                    end;
                Alg ->
                    %% Unsupported algorithm without custom verifier
                    error_logger:warning_msg(
                        "Unsupported JWT algorithm ~p, use custom verifier~n", [Alg]),
                    {error, invalid_token}
            end;
        {error, _} = Error ->
            Error
    end;
verify_token(_Token, _State) ->
    %% No verifier or secret configured
    {error, {error, no_verifier_configured}}.

validate_and_build_auth_info(Claims, State) ->
    case validate_claims(Claims, State) of
        ok ->
            build_auth_info(Claims, State);
        {error, _} = Error ->
            Error
    end.

%%====================================================================
%% JWT decoding and verification
%%====================================================================

%% @doc Decode a JWT without verification.
%% Returns {ok, Header, Claims, Signature} or {error, Reason}.
-spec decode_jwt(binary()) ->
    {ok, map(), map(), binary()} | {error, term()}.
decode_jwt(Token) ->
    try
        case binary:split(Token, <<".">>, [global]) of
            [HeaderB64, ClaimsB64, SignatureB64] ->
                Header = json:decode(base64url_decode(HeaderB64)),
                Claims = json:decode(base64url_decode(ClaimsB64)),
                Signature = base64url_decode(SignatureB64),
                {ok, Header, Claims, Signature};
            _ ->
                {error, invalid_token}
        end
    catch
        _:_ ->
            {error, invalid_token}
    end.

%% @doc Verify HS256 signature.
-spec verify_hs256(binary(), binary()) -> boolean().
verify_hs256(Token, Secret) ->
    case binary:split(Token, <<".">>, [global]) of
        [HeaderB64, ClaimsB64, SignatureB64] ->
            SigningInput = <<HeaderB64/binary, ".", ClaimsB64/binary>>,
            ExpectedSig = crypto:mac(hmac, sha256, Secret, SigningInput),
            ActualSig = base64url_decode(SignatureB64),
            %% Constant-time comparison
            crypto:hash_equals(ExpectedSig, ActualSig);
        _ ->
            false
    end.

%% @doc Validate JWT claims.
-spec validate_claims(map(), map()) -> ok | {error, term()}.
validate_claims(Claims, State) ->
    Now = erlang:system_time(second),
    ClockSkew = maps:get(clock_skew, State, ?DEFAULT_CLOCK_SKEW),

    Checks = [
        fun() -> check_expiration(Claims, Now, ClockSkew) end,
        fun() -> check_not_before(Claims, Now, ClockSkew) end,
        fun() -> check_issuer(Claims, State) end,
        fun() -> check_audience_claim(Claims, State) end
    ],
    run_checks(Checks).

run_checks([]) ->
    ok;
run_checks([Check | Rest]) ->
    case Check() of
        ok -> run_checks(Rest);
        {error, _} = Error -> Error
    end.

check_expiration(Claims, Now, ClockSkew) ->
    case maps:get(<<"exp">>, Claims, undefined) of
        undefined -> ok;
        Exp when is_integer(Exp), Exp + ClockSkew < Now ->
            {error, expired_token};
        _ -> ok
    end.

check_not_before(Claims, Now, ClockSkew) ->
    case maps:get(<<"nbf">>, Claims, undefined) of
        undefined -> ok;
        Nbf when is_integer(Nbf), Nbf - ClockSkew > Now ->
            {error, invalid_token};
        _ -> ok
    end.

check_issuer(Claims, State) ->
    case maps:get(issuer, State, undefined) of
        undefined -> ok;
        ExpectedIssuer ->
            case maps:get(<<"iss">>, Claims, undefined) of
                ExpectedIssuer -> ok;
                _ -> {error, invalid_token}
            end
    end.

check_audience_claim(Claims, State) ->
    case maps:get(audience, State, undefined) of
        undefined -> ok;
        ExpectedAud ->
            check_audience(ExpectedAud, maps:get(<<"aud">>, Claims, undefined))
    end.

check_audience(Expected, Actual) when is_binary(Expected), is_binary(Actual) ->
    case Expected =:= Actual of
        true -> ok;
        false -> {error, invalid_token}
    end;
check_audience(Expected, Actual) when is_binary(Expected), is_list(Actual) ->
    case lists:member(Expected, Actual) of
        true -> ok;
        false -> {error, invalid_token}
    end;
check_audience(ExpectedList, Actual) when is_list(ExpectedList), is_binary(Actual) ->
    case lists:member(Actual, ExpectedList) of
        true -> ok;
        false -> {error, invalid_token}
    end;
check_audience(ExpectedList, ActualList) when is_list(ExpectedList), is_list(ActualList) ->
    case lists:any(fun(E) -> lists:member(E, ActualList) end, ExpectedList) of
        true -> ok;
        false -> {error, invalid_token}
    end;
check_audience(_, undefined) ->
    {error, invalid_token};
check_audience(_, _) ->
    {error, invalid_token}.

%%====================================================================
%% Auth info building
%%====================================================================

build_auth_info(Claims, State) ->
    ScopeClaim = maps:get(scope_claim, State, ?DEFAULT_SCOPE_CLAIM),
    Scopes = extract_scopes(maps:get(ScopeClaim, Claims, <<>>)),

    AuthInfo = #{
        subject => maps:get(<<"sub">>, Claims, undefined),
        issuer => maps:get(<<"iss">>, Claims, undefined),
        audience => maps:get(<<"aud">>, Claims, undefined),
        scopes => Scopes,
        expires_at => maps:get(<<"exp">>, Claims, undefined),
        claims => Claims,
        metadata => #{provider => barrel_mcp_auth_bearer}
    },
    {ok, AuthInfo}.

extract_scopes(ScopeStr) when is_binary(ScopeStr) ->
    %% Scopes as space-separated string
    [S || S <- binary:split(ScopeStr, <<" ">>, [global]), S =/= <<>>];
extract_scopes(Scopes) when is_list(Scopes) ->
    %% Scopes as list
    Scopes;
extract_scopes(_) ->
    [].

%%====================================================================
%% Challenge building
%%====================================================================

error_details(unauthorized) ->
    {401, <<"invalid_request">>, <<"Authorization required">>};
error_details(invalid_token) ->
    {401, <<"invalid_token">>, <<"The access token is invalid">>};
error_details(expired_token) ->
    {401, <<"invalid_token">>, <<"The access token has expired">>};
error_details(insufficient_scope) ->
    {403, <<"insufficient_scope">>, <<"The access token has insufficient scope">>};
error_details({error, Reason}) when is_binary(Reason) ->
    {401, <<"invalid_token">>, Reason};
error_details({error, _}) ->
    {401, <<"invalid_token">>, <<"Token verification failed">>};
error_details(_) ->
    {401, <<"invalid_token">>, <<"Authentication failed">>}.

build_challenge(Realm, ErrorCode, ErrorDesc, Resource) ->
    Parts = [<<"Bearer realm=\"", Realm/binary, "\"">>],
    Parts1 = case ErrorCode of
        <<"invalid_request">> -> Parts;
        _ -> Parts ++ [<<" error=\"", ErrorCode/binary, "\"">>]
    end,
    Parts2 = case ErrorDesc of
        <<>> -> Parts1;
        _ -> Parts1 ++ [<<" error_description=\"", ErrorDesc/binary, "\"">>]
    end,
    Parts3 = case Resource of
        undefined -> Parts2;
        R -> Parts2 ++ [<<" resource=\"", R/binary, "\"">>]
    end,
    iolist_to_binary(lists:join(<<",">>, Parts3)).

%%====================================================================
%% Base64URL utilities
%%====================================================================

base64url_decode(Data) ->
    %% Add padding if necessary
    Padded = case byte_size(Data) rem 4 of
        0 -> Data;
        2 -> <<Data/binary, "==">>;
        3 -> <<Data/binary, "=">>
    end,
    %% Convert URL-safe characters
    Std = binary:replace(
        binary:replace(Padded, <<"-">>, <<"+">>, [global]),
        <<"_">>, <<"/">>, [global]
    ),
    base64:decode(Std).
