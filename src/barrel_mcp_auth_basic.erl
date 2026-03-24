%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Basic HTTP authentication provider for barrel_mcp.
%%%
%%% Implements HTTP Basic Authentication (RFC 7617).
%%% Suitable for simple deployments, development, or when using TLS.
%%%
%%% == Configuration Options ==
%%%
%%% <ul>
%%%   <li>`credentials' - Map of username to password or auth info</li>
%%%   <li>`verifier' - Custom verification function</li>
%%%   <li>`realm' - Realm for WWW-Authenticate header</li>
%%%   <li>`hash_passwords' - If true, stored passwords are SHA256 hashes</li>
%%% </ul>
%%%
%%% @see barrel_mcp_auth
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_basic).

-behaviour(barrel_mcp_auth).

%% barrel_mcp_auth callbacks
-export([
    init/1,
    authenticate/2,
    challenge/2
]).

%% Utilities
-export([
    hash_password/1
]).

%%====================================================================
%% barrel_mcp_auth callbacks
%%====================================================================

%% @doc Initialize the Basic auth provider.
-spec init(map()) -> {ok, map()}.
init(Opts) ->
    State = #{
        credentials => maps:get(credentials, Opts, #{}),
        verifier => maps:get(verifier, Opts, undefined),
        realm => maps:get(realm, Opts, <<"mcp">>),
        hash_passwords => maps:get(hash_passwords, Opts, false)
    },
    {ok, State}.

%% @doc Authenticate a request using Basic auth.
-spec authenticate(map(), map()) ->
    {ok, barrel_mcp_auth:auth_info()} | {error, barrel_mcp_auth:auth_error()}.
authenticate(Request, State) ->
    Headers = maps:get(headers, Request, #{}),
    case barrel_mcp_auth:extract_basic_auth(Headers) of
        {ok, Username, Password} ->
            verify_credentials(Username, Password, State);
        {error, no_credentials} ->
            {error, unauthorized}
    end.

%% @doc Generate WWW-Authenticate challenge.
-spec challenge(barrel_mcp_auth:auth_error(), map()) ->
    {integer(), map(), binary()}.
challenge(Reason, State) ->
    Realm = maps:get(realm, State, <<"mcp">>),

    {StatusCode, ErrorDesc} = case Reason of
        unauthorized ->
            {401, <<"Authentication required">>};
        invalid_credentials ->
            {401, <<"Invalid username or password">>};
        _ ->
            {401, <<"Authentication failed">>}
    end,

    Body = iolist_to_binary(json:encode(#{
        <<"error">> => <<"unauthorized">>,
        <<"error_description">> => ErrorDesc
    })),

    Headers = #{
        <<"www-authenticate">> => <<"Basic realm=\"", Realm/binary, "\", charset=\"UTF-8\"">>,
        <<"content-type">> => <<"application/json">>
    },

    {StatusCode, Headers, Body}.

%%====================================================================
%% Credential verification
%%====================================================================

verify_credentials(Username, Password, #{verifier := Verifier})
  when is_function(Verifier, 2) ->
    %% Custom verifier function
    case Verifier(Username, Password) of
        {ok, AuthInfo} when is_map(AuthInfo) ->
            {ok, add_provider_metadata(AuthInfo)};
        {error, _} = Error ->
            Error
    end;
verify_credentials(Username, Password, #{credentials := Creds, hash_passwords := HashPwd})
  when map_size(Creds) > 0 ->
    %% Lookup in credentials map
    case maps:get(Username, Creds, undefined) of
        undefined ->
            %% Constant-time fake check to prevent timing attacks
            _ = hash_password(Password),
            {error, invalid_credentials};
        ExpectedPassword when is_binary(ExpectedPassword) ->
            verify_password(Username, Password, ExpectedPassword, HashPwd);
        #{password := ExpectedPassword} = Info ->
            case verify_password(Username, Password, ExpectedPassword, HashPwd) of
                {ok, _} ->
                    %% Build auth info from stored info
                    AuthInfo = #{
                        subject => Username,
                        scopes => maps:get(scopes, Info, []),
                        claims => maps:get(claims, Info, #{}),
                        metadata => maps:get(metadata, Info, #{})
                    },
                    {ok, add_provider_metadata(AuthInfo)};
                Error ->
                    Error
            end
    end;
verify_credentials(_Username, _Password, _State) ->
    %% No credentials or verifier configured
    {error, {error, no_credentials_configured}}.

verify_password(Username, Password, ExpectedPassword, true) ->
    %% Passwords are hashed - compare hashes (same length)
    HashedInput = hash_password(Password),
    case crypto:hash_equals(HashedInput, ExpectedPassword) of
        true ->
            {ok, #{subject => Username, scopes => [], claims => #{}}};
        false ->
            {error, invalid_credentials}
    end;
verify_password(Username, Password, ExpectedPassword, false) ->
    %% Plain text comparison - hash both for constant-time comparison
    %% crypto:hash_equals requires same length, so hash both
    HashedInput = hash_password(Password),
    HashedExpected = hash_password(ExpectedPassword),
    case crypto:hash_equals(HashedInput, HashedExpected) of
        true ->
            {ok, #{subject => Username, scopes => [], claims => #{}}};
        false ->
            {error, invalid_credentials}
    end.

%%====================================================================
%% Utilities
%%====================================================================

%% @doc Hash a password using SHA256.
%% Use this to create hashed passwords for the credentials configuration.
-spec hash_password(Password :: binary()) -> binary().
hash_password(Password) ->
    Digest = crypto:hash(sha256, Password),
    encode_hex(Digest).

encode_hex(Bin) ->
    << <<(hex_digit(N))>> || <<N:4>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + N - 10.

add_provider_metadata(AuthInfo) ->
    Metadata = maps:get(metadata, AuthInfo, #{}),
    AuthInfo#{metadata => Metadata#{provider => barrel_mcp_auth_basic}}.
