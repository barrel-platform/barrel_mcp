%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Simple HTTP transport for MCP (POST/OPTIONS, no sessions/SSE).
%%%
%%% A minimal JSON-RPC-over-HTTP transport on the built-in h1/h2
%%% server ({@link barrel_mcp_http_listener}). For the full
%%% Streamable HTTP transport (sessions, SSE, async tools) use
%%% {@link barrel_mcp_http_stream}.
%%%
%%% == Authentication Options ==
%%%
%%% The `auth' option is a map with `provider', `provider_opts' and
%%% `required_scopes'. See {@link barrel_mcp_auth}.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http).

-export([start/1, stop/0]).

-define(HTTP_LISTENER, barrel_mcp_http_simple_listener).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the simple HTTP server for MCP.
%%
%% Same security defaults as {@link barrel_mcp_http_stream}: binds to
%% `127.0.0.1' by default and requires explicit `allowed_origins' for
%% non-loopback binds.
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Opts) ->
    Port = maps:get(port, Opts, 9090),
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    Loopback = barrel_mcp_http_engine:is_loopback(Ip),
    case
        barrel_mcp_http_engine:resolve_allowed_origins(
            Loopback, maps:get(allowed_origins, Opts, undefined)
        )
    of
        {error, _} = Err ->
            Err;
        {ok, AllowedOrigins} ->
            AllowMissing = maps:get(allow_missing_origin, Opts, Loopback),
            ResourceMetadata = barrel_mcp_http_engine:normalize_resource_metadata(
                maps:get(resource_metadata, Opts, undefined)
            ),
            AuthConfig0 = barrel_mcp_http_engine:init_auth(
                maps:get(auth, Opts, #{})
            ),
            AuthConfig = barrel_mcp_http_engine:inject_resource_metadata_url(
                AuthConfig0, ResourceMetadata
            ),
            EngineConfig = #{
                mode => simple,
                auth_config => AuthConfig,
                allowed_origins => AllowedOrigins,
                allow_missing_origin => AllowMissing,
                resource_metadata => ResourceMetadata
            },
            ListenOpts = maps:merge(
                #{port => Port, ip => Ip, ssl => normalize_ssl(Opts)},
                maps:with([max_connections, acceptors], Opts)
            ),
            barrel_mcp_http_listener:start(?HTTP_LISTENER, ListenOpts, EngineConfig)
    end.

%% @doc Stop the simple HTTP server.
-spec stop() -> ok | {error, not_found}.
stop() ->
    barrel_mcp_http_listener:stop(?HTTP_LISTENER).

normalize_ssl(Opts) ->
    case maps:get(ssl, Opts, undefined) of
        #{certfile := _, keyfile := _} = Ssl -> Ssl;
        _ -> undefined
    end.
