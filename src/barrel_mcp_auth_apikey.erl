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
    hash_key/1
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
        hash_keys => maps:get(hash_keys, Opts, false)
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
            verify_key(Key, State);
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

verify_key(Key, #{verifier := Verifier}) when is_function(Verifier, 1) ->
    %% Custom verifier function
    case Verifier(Key) of
        {ok, AuthInfo} when is_map(AuthInfo) ->
            {ok, add_provider_metadata(AuthInfo)};
        {error, _} = Error ->
            Error
    end;
verify_key(Key, #{keys := Keys, hash_keys := HashKeys}) when map_size(Keys) > 0 ->
    %% Lookup in keys map
    LookupKey = case HashKeys of
        true -> hash_key(Key);
        false -> Key
    end,
    case maps:get(LookupKey, Keys, undefined) of
        undefined ->
            {error, invalid_credentials};
        AuthInfo when is_map(AuthInfo) ->
            {ok, add_provider_metadata(AuthInfo)};
        true ->
            %% Simple key list (converted to map with true values)
            {ok, add_provider_metadata(#{
                subject => LookupKey,
                scopes => [],
                claims => #{}
            })}
    end;
verify_key(_Key, _State) ->
    %% No keys or verifier configured
    {error, {error, no_keys_configured}}.

%%====================================================================
%% Utilities
%%====================================================================

%% @doc Hash an API key using SHA256.
%% Use this to create hashed keys for the keys configuration.
-spec hash_key(Key :: binary()) -> binary().
hash_key(Key) ->
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
