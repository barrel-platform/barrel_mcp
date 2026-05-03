%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc API key authentication provider for barrel_mcp.
%%%
%%% Supports API key authentication via X-API-Key header, custom
%%% headers, or Authorization header with ApiKey scheme.
%%%
%%% == Configuration Options ==
%%%
%%% <ul>
%%%   <li>`keys' - Map of API key to auth info, or list of valid keys</li>
%%%   <li>`verifier' - Custom verification function</li>
%%%   <li>`header_name' - Custom header name (default: X-API-Key)</li>
%%%   <li>`hash_keys' - If true, stored keys are SHA256 hashes</li>
%%% </ul>
%%%
%%% @see barrel_mcp_auth
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_apikey).

-behaviour(barrel_mcp_auth).

%% barrel_mcp_auth callbacks
-export([
    init/1,
    authenticate/2,
    challenge/2
]).

%% Utilities
-export([
    hash_key/1,
    hash_key/2,
    verify_key/2,
    verify_key/3
]).

%%====================================================================
%% barrel_mcp_auth callbacks
%%====================================================================

%% @doc Initialize the API key provider.
-spec init(map()) -> {ok, map()}.
init(Opts) ->
    Keys = normalize_keys(maps:get(keys, Opts, #{})),
    State = #{
        keys => Keys,
        verifier => maps:get(verifier, Opts, undefined),
        header_name => maps:get(header_name, Opts, <<"x-api-key">>),
        hash_keys => maps:get(hash_keys, Opts, false),
        pepper => maps:get(pepper, Opts, undefined)
    },
    {ok, State}.

%% @doc Authenticate a request using API key.
-spec authenticate(map(), map()) ->
    {ok, barrel_mcp_auth:auth_info()} | {error, barrel_mcp_auth:auth_error()}.
authenticate(Request, State) ->
    Headers = maps:get(headers, Request, #{}),
    Opts = #{header_name => maps:get(header_name, State, <<"x-api-key">>)},
    case barrel_mcp_auth:extract_api_key(Headers, Opts) of
        {ok, Key} ->
            verify_against_state(Key, State);
        {error, no_key} ->
            {error, unauthorized}
    end.

%% @doc Generate authentication challenge.
-spec challenge(barrel_mcp_auth:auth_error(), map()) ->
    {integer(), map(), binary()}.
challenge(Reason, State) ->
    HeaderName = maps:get(header_name, State, <<"x-api-key">>),

    {StatusCode, ErrorCode, ErrorDesc} = case Reason of
        unauthorized ->
            {401, <<"invalid_request">>, <<"API key required">>};
        invalid_credentials ->
            {401, <<"invalid_key">>, <<"Invalid API key">>};
        _ ->
            {401, <<"invalid_key">>, <<"Authentication failed">>}
    end,

    Body = iolist_to_binary(json:encode(#{
        <<"error">> => ErrorCode,
        <<"error_description">> => ErrorDesc
    })),

    Headers = #{
        <<"www-authenticate">> => <<"ApiKey header=\"", HeaderName/binary, "\"">>,
        <<"content-type">> => <<"application/json">>
    },

    {StatusCode, Headers, Body}.

%%====================================================================
%% Key verification
%%====================================================================

verify_against_state(Key, #{verifier := Verifier}) when is_function(Verifier, 1) ->
    case Verifier(Key) of
        {ok, AuthInfo} when is_map(AuthInfo) ->
            {ok, add_provider_metadata(AuthInfo)};
        {error, _} = Error ->
            Error
    end;
verify_against_state(Key, #{keys := Keys, hash_keys := HashKeys} = State)
  when map_size(Keys) > 0 ->
    %% Lookup. With `hash_keys' = true the map keys are stored as
    %% legacy hex SHA-256 digests (or, going forward, the new
    %% `hmac-sha256$...' format).
    Pepper = maps:get(pepper, State, undefined),
    LookupKey = case HashKeys of
        true ->
            case Pepper of
                undefined -> legacy_sha256_hex(Key);
                _ -> hmac_format(Key, Pepper)
            end;
        false -> Key
    end,
    case maps:get(LookupKey, Keys, undefined) of
        undefined ->
            %% Try the alternate stored form for backward compat.
            case HashKeys andalso Pepper =/= undefined of
                true ->
                    LegacyKey = legacy_sha256_hex(Key),
                    case maps:get(LegacyKey, Keys, undefined) of
                        undefined -> {error, invalid_credentials};
                        Info -> info_to_reply(Info, LegacyKey)
                    end;
                false ->
                    {error, invalid_credentials}
            end;
        Info ->
            info_to_reply(Info, LookupKey)
    end;
verify_against_state(_Key, _State) ->
    {error, {error, no_keys_configured}}.

info_to_reply(true, LookupKey) ->
    {ok, add_provider_metadata(#{
        subject => LookupKey,
        scopes => [],
        claims => #{}
    })};
info_to_reply(AuthInfo, _LookupKey) when is_map(AuthInfo) ->
    {ok, add_provider_metadata(AuthInfo)}.

%%====================================================================
%% Utilities
%%====================================================================

%% @doc Hash an API key using the legacy SHA-256 hex format. Kept
%% for migration; use {@link hash_key/2} with a pepper for new
%% deployments.
-spec hash_key(Key :: binary()) -> binary().
hash_key(Key) ->
    legacy_sha256_hex(Key).

%% @doc Hash an API key with the chosen format.
%%
%% `Opts' may include:
%% <ul>
%%   <li>`pepper' (binary, required for the new format) — server-side
%%       secret mixed into the HMAC. Stored format becomes
%%       `hmac-sha256$<base64(hash)>'.</li>
%% </ul>
-spec hash_key(Key :: binary(), Opts :: map()) -> binary().
hash_key(Key, #{pepper := Pepper}) when is_binary(Pepper) ->
    hmac_format(Key, Pepper);
hash_key(Key, _) ->
    legacy_sha256_hex(Key).

%% @doc Constant-time comparison of a presented `Key' against a
%% `Stored' digest. Accepts only the legacy hex SHA-256 format —
%% the modern `hmac-sha256$...' format requires the server-side
%% pepper, which {@link verify_key/3} takes explicitly. This shim
%% rejects HMAC-format inputs so callers don't accidentally treat
%% them as verified.
-spec verify_key(Key :: binary(), Stored :: binary()) ->
    ok | {error, invalid_credentials} | {error, pepper_required}.
verify_key(_Key, <<"hmac-sha256$", _/binary>>) ->
    {error, pepper_required};
verify_key(Key, Stored) when byte_size(Stored) =:= 64 ->
    case crypto:hash_equals(legacy_sha256_hex(Key), Stored) of
        true -> ok;
        false -> {error, invalid_credentials}
    end;
verify_key(_Key, _Stored) ->
    {error, invalid_credentials}.

%% @doc Constant-time comparison of a presented `Key' against a
%% `Stored' digest, with the server-side `Pepper' used for the
%% `hmac-sha256$...' format. The `Pepper' is ignored for legacy
%% hex SHA-256 digests (they were produced without a pepper). Use
%% this from any code that owns the pepper (config tooling,
%% tests) — the auth provider's internal authenticate path goes
%% through `verify_against_state/2' which already has the pepper
%% in state.
-spec verify_key(Key :: binary(), Stored :: binary(),
                 Pepper :: binary() | undefined) ->
    ok | {error, invalid_credentials}.
verify_key(Key, <<"hmac-sha256$", _/binary>> = Stored, Pepper)
  when is_binary(Pepper) ->
    Computed = hmac_format(Key, Pepper),
    case crypto:hash_equals(Computed, Stored) of
        true -> ok;
        false -> {error, invalid_credentials}
    end;
verify_key(_Key, <<"hmac-sha256$", _/binary>>, undefined) ->
    {error, invalid_credentials};
verify_key(Key, Stored, _Pepper) when byte_size(Stored) =:= 64 ->
    case crypto:hash_equals(legacy_sha256_hex(Key), Stored) of
        true -> ok;
        false -> {error, invalid_credentials}
    end;
verify_key(_Key, _Stored, _Pepper) ->
    {error, invalid_credentials}.

%% Internal: build the new stored format `hmac-sha256$<b64(hash)>'.
hmac_format(Key, Pepper) ->
    Hash = crypto:mac(hmac, sha256, Pepper, Key),
    iolist_to_binary([<<"hmac-sha256$">>, base64:encode(Hash)]).

legacy_sha256_hex(Key) ->
    Digest = crypto:hash(sha256, Key),
    encode_hex(Digest).

encode_hex(Bin) ->
    << <<(hex_digit(N))>> || <<N:4>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

normalize_keys(Keys) when is_map(Keys) ->
    Keys;
normalize_keys(Keys) when is_list(Keys) ->
    %% Convert list of keys to map with true values
    maps:from_list([{K, true} || K <- Keys]);
normalize_keys(_) ->
    #{}.

add_provider_metadata(AuthInfo) ->
    Metadata = maps:get(metadata, AuthInfo, #{}),
    AuthInfo#{metadata => Metadata#{provider => barrel_mcp_auth_apikey}}.
