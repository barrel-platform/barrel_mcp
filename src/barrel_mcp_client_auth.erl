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

-export([new/1, header/1, refresh/2]).

-export_type([t/0, handle/0]).

-type handle() :: term().
-type t() :: {module(), handle()} | none.

%% @doc Build the auth handle from a config term.
%%   `none' — no auth header sent.
%%   `{bearer, Token}' — static bearer token.
%%   `{oauth, Config}' — OAuth 2.1 + PKCE (Phase D).
-callback init(Config :: term()) -> {ok, handle()} | {error, term()}.

%% @doc Return the value to put in the `Authorization' header.
%% Returning `none' means do not attach an Authorization header.
-callback header(handle()) ->
    {ok, binary()} | none | {error, term()}.

%% @doc Refresh the credential after a 401. `WwwAuthenticate' is the
%% raw header value returned by the server, used by OAuth flows for
%% protected-resource-metadata discovery.
-callback refresh(handle(), WwwAuthenticate :: binary() | undefined) ->
    {ok, handle()} | {error, term()}.

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Construct an auth handle from a user-facing config term.
-spec new(none | {bearer, binary()} | {oauth, map()}) ->
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
    end.

%% @doc Lookup the Authorization header for the current state.
-spec header(t()) -> {ok, binary()} | none | {error, term()}.
header(none) -> none;
header({Mod, H}) -> Mod:header(H).

%% @doc Refresh after a 401, returning a new handle.
-spec refresh(t(), binary() | undefined) -> {ok, t()} | {error, term()}.
refresh(none, _) -> {error, no_auth_configured};
refresh({Mod, H}, Www) ->
    case Mod:refresh(H, Www) of
        {ok, H1} -> {ok, {Mod, H1}};
        Err -> Err
    end.
