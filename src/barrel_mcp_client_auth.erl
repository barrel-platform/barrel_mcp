%%%-------------------------------------------------------------------
%%% @doc Authorization behaviour for `barrel_mcp_client'.
%%%
%%% The HTTP transport calls into this module to obtain the bearer
%%% token to attach to outgoing requests, and to refresh the token
%%% when the server returns 401.
%%%
%%% A handle is an opaque term passed back into every callback. Static
%%% bearer tokens use `barrel_mcp_client_auth_bearer'; OAuth 2.1 with
%%% PKCE will use `barrel_mcp_client_auth_oauth' (Phase D).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth).

-export([new/1, header/1, refresh/2, challenge/2, settled/1]).

-export_type([t/0, handle/0, challenge/0]).

-type handle() :: term().
-type t() :: {module(), handle()} | none.

%% What the transport knows when the server refuses a request:
%% the status (401, or 403 with `insufficient_scope'), the raw
%% `WWW-Authenticate' value, the MCP server URL the request went to, and
%% the negotiated protocol version if any. An OAuth handle discovers,
%% registers and authorizes from that.
-type challenge() :: #{
    status := 401 | 403,
    www_authenticate := binary() | undefined,
    server_url := binary(),
    protocol_version := binary() | undefined
}.

%% A handle that can run a whole authorization from a challenge
%% exports these two; one that only refreshes a token in hand does
%% not, and the transport falls back to `refresh/2' for it.
-callback challenge(handle(), challenge()) -> {ok, handle()} | {error, term()}.
%% The transport reports a request the server accepted.
-callback settled(handle()) -> handle().
-optional_callbacks([challenge/2, settled/1]).

%% Build the auth handle from a config term.
%%   `none' — no auth header sent.
%%   `{bearer, Token}' — static bearer token.
%%   `{oauth, Config}' — OAuth 2.1 + PKCE (authorization_code grant).
%%   `{oauth_client_credentials, Config}' — OAuth 2.1 client_credentials
%%       grant (RFC 6749, plus the MCP `ext-auth' OAuth Client
%%       Credentials extension). For unattended agent hosts. Config
%%       requires `token_endpoint' and `client_id'; supply either
%%       `client_secret' or `client_assertion' (private_key_jwt).
%%   `{oauth_enterprise, Config}' — Enterprise-Managed Authorization
%%       (MCP `ext-auth' EMA). Chains an IdP-issued ID Token through
%%       RFC 8693 token-exchange and RFC 7523 jwt-bearer to mint a
%%       short-lived MCP access token. For SSO-driven hosts. Config
%%       requires `idp_token_endpoint', `as_token_endpoint',
%%       `client_id', `subject_token', `subject_token_type',
%%       `audience', `resource'.
-callback init(Config :: term()) -> {ok, handle()} | {error, term()}.

%% Return the value to put in the `Authorization' header.
%% Returning `none' means do not attach an Authorization header.
-callback header(handle()) ->
    {ok, binary()} | none | {error, term()}.

%% Refresh the credential after a 401. `WwwAuthenticate' is the
%% raw header value returned by the server, used by OAuth flows for
%% protected-resource-metadata discovery.
-callback refresh(handle(), WwwAuthenticate :: binary() | undefined) ->
    {ok, handle()} | {error, term()}.

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Construct an auth handle from a user-facing config term.
-spec new(
    none
    | {bearer, binary()}
    | {oauth, map()}
    | {oauth_client_credentials, map()}
    | {oauth_enterprise, map()}
) ->
    t() | {error, term()}.
new(none) ->
    none;
new({bearer, Token}) when is_binary(Token) ->
    case barrel_mcp_client_auth_bearer:init(Token) of
        {ok, H} -> {barrel_mcp_client_auth_bearer, H};
        Err -> Err
    end;
new({oauth, Config}) when is_map(Config) ->
    case barrel_mcp_client_auth_oauth:init(Config) of
        {ok, H} -> {barrel_mcp_client_auth_oauth, H};
        Err -> Err
    end;
new({oauth_client_credentials, Config}) when is_map(Config) ->
    Cfg = Config#{grant_type => client_credentials},
    case barrel_mcp_client_auth_oauth:init(Cfg) of
        {ok, H} -> {barrel_mcp_client_auth_oauth, H};
        Err -> Err
    end;
new({oauth_enterprise, Config}) when is_map(Config) ->
    Cfg = Config#{grant_type => enterprise_managed},
    case barrel_mcp_client_auth_oauth:init(Cfg) of
        {ok, H} -> {barrel_mcp_client_auth_oauth, H};
        Err -> Err
    end.

%% @doc Lookup the Authorization header for the current state.
-spec header(t()) -> {ok, binary()} | none | {error, term()}.
header(none) -> none;
header({Mod, H}) -> Mod:header(H).

%% @doc Refresh after a 401, returning a new handle.
-spec refresh(t(), binary() | undefined) -> {ok, t()} | {error, term()}.
refresh(none, _) ->
    {error, no_auth_configured};
refresh({Mod, H}, Www) ->
    case Mod:refresh(H, Www) of
        {ok, H1} -> {ok, {Mod, H1}};
        Err -> Err
    end.

%% @doc Answer a server's refusal with a new handle. Runs the handle's
%% `challenge/2' when it has one, else its `refresh/2' with the header.
%% May take as long as a person takes to authorize; the transport
%% calls it from a worker, never inline.
-spec challenge(t(), challenge()) -> {ok, t()} | {error, term()}.
challenge(none, _Challenge) ->
    {error, no_auth_configured};
challenge({Mod, H}, Challenge) ->
    Result =
        case erlang:function_exported(Mod, challenge, 2) of
            true -> Mod:challenge(H, Challenge);
            false -> Mod:refresh(H, maps:get(www_authenticate, Challenge, undefined))
        end,
    case Result of
        {ok, H1} -> {ok, {Mod, H1}};
        Err -> Err
    end.

%% @doc Tell the handle a request was accepted.
-spec settled(t()) -> t().
settled(none) ->
    none;
settled({Mod, H}) ->
    case erlang:function_exported(Mod, settled, 1) of
        true -> {Mod, Mod:settled(H)};
        false -> {Mod, H}
    end.
