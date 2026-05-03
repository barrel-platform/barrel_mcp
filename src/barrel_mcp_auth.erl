%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Authentication behaviour and utilities for barrel_mcp.
%%%
%%% This module defines the `barrel_mcp_auth' behaviour for implementing
%%% pluggable authentication providers. It also provides utility functions
%%% for extracting credentials from HTTP headers.
%%%
%%% == Built-in Providers ==
%%%
%%% <ul>
%%%   <li>{@link barrel_mcp_auth_none} - No authentication (default)</li>
%%%   <li>{@link barrel_mcp_auth_bearer} - Bearer tokens (JWT/opaque)</li>
%%%   <li>{@link barrel_mcp_auth_apikey} - API key authentication</li>
%%%   <li>{@link barrel_mcp_auth_basic} - HTTP Basic authentication</li>
%%% </ul>
%%%
%%% == Implementing a Custom Provider ==
%%%
%%% To create a custom authentication provider, implement the
%%% `barrel_mcp_auth' behaviour:
%%%
%%% ```
%%% -module(my_auth_provider).
%%% -behaviour(barrel_mcp_auth).
%%%
%%% -export([init/1, authenticate/2, challenge/2]).
%%%
%%% init(Opts) ->
%%%     {ok, Opts}.
%%%
%%% authenticate(Request, State) ->
%%%     Headers = maps:get(headers, Request, #{}),
%%%     case barrel_mcp_auth:extract_bearer_token(Headers) of
%%%         {ok, Token} -> verify_token(Token);
%%%         {error, no_token} -> {error, unauthorized}
%%%     end.
%%%
%%% challenge(Reason, _State) ->
%%%     {401, #{<<"www-authenticate">> => <<"Bearer">>}, <<>>}.
%%% '''
%%%
%%% == Configuring Authentication ==
%%%
%%% Pass authentication configuration when starting the HTTP server:
%%%
%%% ```
%%% barrel_mcp:start_http(#{
%%%     port => 9090,
%%%     auth => #{
%%%         provider => barrel_mcp_auth_bearer,
%%%         provider_opts => #{secret => <<"my-secret">>},
%%%         required_scopes => [<<"read">>]
%%%     }
%%% }).
%%% '''
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth).

%% API
-export([
    authenticate/3,
    challenge_response/2,
    get_auth_info/1,
    extract_bearer_token/1,
    extract_api_key/2,
    extract_basic_auth/1,
    auth_headers/1
]).

%% Types
-export_type([
    auth_provider/0,
    auth_info/0,
    auth_error/0,
    auth_config/0
]).

%%====================================================================
%% Types
%%====================================================================

-type auth_provider() :: module().
%% Module implementing the barrel_mcp_auth behaviour.

-type auth_info() :: #{
    subject => binary(),
    issuer => binary(),
    audience => binary() | [binary()],
    scopes => [binary()],
    expires_at => integer(),
    claims => map(),
    metadata => map()
}.
%% Authentication information returned on successful auth.
%% Contains subject (user/client ID), issuer, audience, scopes,
%% expiration timestamp, token claims, and provider metadata.

-type auth_error() ::
    unauthorized |
    invalid_token |
    expired_token |
    insufficient_scope |
    invalid_credentials |
    {error, term()}.
%% Possible authentication error reasons.

-type auth_config() :: #{
    provider := module(),
    provider_opts => map(),
    provider_state => term(),
    realm => binary(),
    required_scopes => [binary()]
}.
%% Authentication configuration for the HTTP server.

%%====================================================================
%% Behaviour Callbacks
%%====================================================================

%% Initialize the authentication provider.
%% Called once when the HTTP server starts.
-callback init(Opts :: map()) ->
    {ok, State :: term()} | {error, term()}.

%% Authenticate an incoming request.
-callback authenticate(Request :: map(), State :: term()) ->
    {ok, auth_info()} | {error, auth_error()}.

%% Generate a challenge response for failed authentication.
-callback challenge(Reason :: auth_error(), State :: term()) ->
    {StatusCode :: integer(), Headers :: map(), Body :: binary()}.

%% Optional: declare which HTTP request headers carry credentials so
%% the HTTP transport can build the CORS `Access-Control-Allow-Headers'
%% list and read the right inputs in `extract_headers/1'. Returning
%% the empty list means "no auth header" (e.g. cookie-based, or none).
-callback auth_headers(State :: term()) -> [binary()].

-optional_callbacks([init/1, auth_headers/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Authenticate a request using the configured provider.
%%
%% Delegates authentication to the configured provider and optionally
%% checks for required scopes after successful authentication.
%%
%% @param Config Authentication configuration
%% @param Request Map containing `headers' key with HTTP headers
%% @param State Provider state (usually same as Config)
%% @returns `{ok, AuthInfo}' on success, `{error, Reason}' on failure
-spec authenticate(auth_config(), map(), term()) ->
    {ok, auth_info()} | {error, auth_error()}.
authenticate(#{provider := Provider} = Config, Request, State) ->
    ProviderState = maps:get(provider_state, State, undefined),
    case Provider:authenticate(Request, ProviderState) of
        {ok, AuthInfo} ->
            %% Check required scopes if configured
            case maps:get(required_scopes, Config, []) of
                [] ->
                    {ok, AuthInfo};
                RequiredScopes ->
                    check_scopes(RequiredScopes, AuthInfo)
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Generate a challenge response for failed authentication.
%%
%% Creates an HTTP response with appropriate status code, headers
%% (including WWW-Authenticate), and error body.
%%
%% @param Config Authentication configuration
%% @param Reason The authentication error reason
%% @returns Tuple of `{StatusCode, Headers, Body}'
-spec challenge_response(auth_config(), auth_error()) ->
    {integer(), map(), binary()}.
challenge_response(#{provider := Provider} = Config, Reason) ->
    ProviderState = maps:get(provider_state, Config, undefined),
    Provider:challenge(Reason, ProviderState).

%% @doc Return the list of HTTP request headers (lower-case) the
%% configured provider expects to read credentials from. Used by the
%% HTTP transport to build CORS `Access-Control-Allow-Headers' and to
%% extract inputs in the request handler. Falls back to a sensible
%% default per built-in provider when the provider does not export
%% `auth_headers/1'.
-spec auth_headers(auth_config()) -> [binary()].
auth_headers(#{provider := barrel_mcp_auth_none}) ->
    [];
auth_headers(#{provider := Provider} = Config) ->
    case erlang:function_exported(Provider, auth_headers, 1) of
        true ->
            ProviderState = maps:get(provider_state, Config, undefined),
            Provider:auth_headers(ProviderState);
        false ->
            default_auth_headers(Provider, Config)
    end.

default_auth_headers(barrel_mcp_auth_bearer, _) -> [<<"authorization">>];
default_auth_headers(barrel_mcp_auth_basic, _)  -> [<<"authorization">>];
default_auth_headers(barrel_mcp_auth_apikey, Config) ->
    Opts = maps:get(provider_opts, Config, #{}),
    Custom = maps:get(header_name, Opts, undefined),
    Base = [<<"x-api-key">>, <<"authorization">>],
    case Custom of
        undefined -> Base;
        H when is_binary(H) -> [string:lowercase(H) | Base]
    end;
default_auth_headers(barrel_mcp_auth_custom, _) ->
    [<<"authorization">>, <<"x-api-key">>];
default_auth_headers(_, _) ->
    [].

%% @doc Get authentication info from a context map.
%%
%% Extracts authentication information that was added to the context
%% after successful authentication.
%%
%% @param Context Map that may contain `auth_info' key
%% @returns The auth_info map if present, `undefined' otherwise
-spec get_auth_info(map()) -> auth_info() | undefined.
get_auth_info(#{auth_info := AuthInfo}) ->
    AuthInfo;
get_auth_info(_) ->
    undefined.

%% @doc Extract Bearer token from Authorization header.
%%
%% Parses the Authorization header and extracts the token value
%% from a Bearer authentication scheme.
%%
%% == Example ==
%%
%% ```
%% Headers = #{<<"authorization">> => <<"Bearer abc123">>},
%% {ok, <<"abc123">>} = barrel_mcp_auth:extract_bearer_token(Headers).
%% '''
%%
%% @param Headers Map of HTTP headers (case-insensitive lookup)
%% @returns `{ok, Token}' if Bearer token found, `{error, no_token}' otherwise
-spec extract_bearer_token(Headers :: map()) -> {ok, binary()} | {error, no_token}.
extract_bearer_token(Headers) ->
    case get_authorization_header(Headers) of
        {ok, <<"Bearer ", Token/binary>>} ->
            {ok, string:trim(Token)};
        {ok, <<"bearer ", Token/binary>>} ->
            {ok, string:trim(Token)};
        _ ->
            {error, no_token}
    end.

%% @doc Extract API key from headers.
%%
%% Looks for API key in the following locations (in order):
%% <ol>
%%%   <li>Custom header specified by `header_name' option</li>
%%%   <li>X-API-Key header</li>
%%%   <li>Authorization header with ApiKey scheme</li>
%%% </ol>
%%
%% == Example ==
%%
%% ```
%% Headers = #{<<"x-api-key">> => <<"my-key">>},
%% {ok, <<"my-key">>} = barrel_mcp_auth:extract_api_key(Headers, #{}).
%% '''
%%
%% @param Headers Map of HTTP headers
%% @param Opts Options map, may contain `header_name' for custom header
%% @returns `{ok, Key}' if found, `{error, no_key}' otherwise
-spec extract_api_key(Headers :: map(), Opts :: map()) ->
    {ok, binary()} | {error, no_key}.
extract_api_key(Headers, #{header_name := HeaderName}) ->
    HeaderNameLower = string:lowercase(HeaderName),
    case find_header(HeaderNameLower, Headers) of
        {ok, Key} -> {ok, Key};
        error -> {error, no_key}
    end;
extract_api_key(Headers, _Opts) ->
    %% Default header names
    case find_header(<<"x-api-key">>, Headers) of
        {ok, Key} ->
            {ok, Key};
        error ->
            case find_header(<<"authorization">>, Headers) of
                {ok, <<"ApiKey ", Key/binary>>} -> {ok, string:trim(Key)};
                {ok, <<"apikey ", Key/binary>>} -> {ok, string:trim(Key)};
                _ -> {error, no_key}
            end
    end.

%% @doc Extract Basic authentication credentials.
%%
%% Parses the Authorization header for Basic authentication scheme
%% and decodes the base64-encoded credentials.
%%
%% == Example ==
%%
%% ```
%% Encoded = base64:encode(<<"user:pass">>),
%% Headers = #{<<"authorization">> => <<"Basic ", Encoded/binary>>},
%% {ok, <<"user">>, <<"pass">>} = barrel_mcp_auth:extract_basic_auth(Headers).
%% '''
%%
%% @param Headers Map of HTTP headers
%% @returns `{ok, Username, Password}' if found and valid,
%%          `{error, no_credentials}' otherwise
-spec extract_basic_auth(Headers :: map()) ->
    {ok, Username :: binary(), Password :: binary()} | {error, no_credentials}.
extract_basic_auth(Headers) ->
    case get_authorization_header(Headers) of
        {ok, <<"Basic ", Encoded/binary>>} ->
            decode_basic_auth(string:trim(Encoded));
        {ok, <<"basic ", Encoded/binary>>} ->
            decode_basic_auth(string:trim(Encoded));
        _ ->
            {error, no_credentials}
    end.

%%====================================================================
%% Internal functions
%%====================================================================

get_authorization_header(Headers) ->
    find_header(<<"authorization">>, Headers).

find_header(Name, Headers) when is_map(Headers) ->
    NameLower = string:lowercase(Name),
    %% Headers might have different case
    maps:fold(fun(K, V, Acc) ->
        case Acc of
            {ok, _} -> Acc;
            error ->
                case string:lowercase(K) of
                    NameLower -> {ok, V};
                    _ -> error
                end
        end
    end, error, Headers);
find_header(_, _) ->
    error.

decode_basic_auth(Encoded) ->
    try
        Decoded = base64:decode(Encoded),
        case binary:split(Decoded, <<":">>) of
            [Username, Password] ->
                {ok, Username, Password};
            [Username] ->
                %% Password might be empty
                {ok, Username, <<>>};
            _ ->
                {error, no_credentials}
        end
    catch
        _:_ ->
            {error, no_credentials}
    end.

check_scopes(RequiredScopes, #{scopes := TokenScopes} = AuthInfo) ->
    case lists:all(fun(S) -> lists:member(S, TokenScopes) end, RequiredScopes) of
        true -> {ok, AuthInfo};
        false -> {error, insufficient_scope}
    end;
check_scopes(_, AuthInfo) ->
    %% No scopes in token, check if any required
    {ok, AuthInfo}.
