%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc MCP Streamable HTTP Transport (Protocol Version 2025-03-26).
%%%
%%% Implements the MCP Streamable HTTP transport for Claude Code
%%% integration on the built-in h1/h2 server
%%% ({@link barrel_mcp_http_listener}). This transport uses:
%%% <ul>
%%%   <li>POST for client requests with JSON or SSE streaming responses.</li>
%%%   <li>GET for server-to-client notification streams (SSE).</li>
%%%   <li>DELETE for session termination.</li>
%%%   <li>OPTIONS for CORS preflight.</li>
%%% </ul>
%%%
%%% The protocol logic lives in {@link barrel_mcp_http_engine}; this
%%% module only wires the user options to the engine and starts the
%%% listener.
%%%
%%% @reference <a href="https://spec.modelcontextprotocol.io/specification/basic/transports/">MCP Transport Specification</a>
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_stream).

-export([start/1, stop/0]).

-define(STREAM_LISTENER, barrel_mcp_http_stream_listener).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the Streamable HTTP server.
%%
%% == Security defaults ==
%%
%% The server binds to `127.0.0.1' by default. Public binds (any
%% non-loopback IP) require an explicit `allowed_origins' to prevent
%% DNS-rebinding and CORS-style attacks. The `Origin' header is
%% validated on every request; mismatches get HTTP 403.
%%
%% == Options ==
%%
%% <ul>
%%   <li>`port' — TCP port (default 9090).</li>
%%   <li>`ip' — bind address (default `{127,0,0,1}').</li>
%%   <li>`auth' — authentication provider config.</li>
%%   <li>`session_enabled' — `true' (default) to use
%%       `Mcp-Session-Id' sessions.</li>
%%   <li>`ssl' — TLS options (`certfile', `keyfile',
%%       optional `cacertfile'). A TLS bind serves HTTP/1.1 and
%%       HTTP/2 on the same port via ALPN.</li>
%%   <li>`allowed_origins' — `[binary()] | any'.</li>
%%   <li>`allow_missing_origin' — accept requests with no `Origin'
%%       header. Defaults to `true' on loopback, `false' otherwise.</li>
%%   <li>`subscription_keepalive_ms' — how often a quiet
%%       `subscriptions/listen' stream emits an SSE comment so
%%       intermediaries do not drop it. Defaults to 15000.
%%
%%       It doubles as the upper bound on how long a subscriber that
%%       went away lingers: nothing reads the socket while a stream is
%%       held open, so a client's disconnect surfaces on the next
%%       write. Raise it and dropped subscribers are reaped later.</li>
%% </ul>
-spec start(Opts) -> {ok, pid()} | {error, term()} when
    Opts :: #{
        port => pos_integer(),
        ip => inet:ip_address(),
        auth => map(),
        session_enabled => boolean(),
        ssl => map(),
        allowed_origins => [binary()] | any,
        allow_missing_origin => boolean(),
        subscription_keepalive_ms => pos_integer(),
        max_connections => pos_integer()
    }.
start(Opts) ->
    Port = maps:get(port, Opts, 9090),
    Ip = maps:get(ip, Opts, {127, 0, 0, 1}),
    SessionEnabled = maps:get(session_enabled, Opts, true),
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
            _ =
                case SessionEnabled of
                    true -> barrel_mcp_http_engine:ensure_session_manager();
                    false -> ok
                end,
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
                mode => stream,
                auth_config => AuthConfig,
                session_enabled => SessionEnabled,
                allowed_origins => AllowedOrigins,
                allow_missing_origin => AllowMissing,
                sse_buffer_size => maps:get(sse_buffer_size, Opts, 256),
                resource_metadata => ResourceMetadata,
                subscription_keepalive_ms => maps:get(
                    subscription_keepalive_ms,
                    Opts,
                    application:get_env(barrel_mcp, subscription_keepalive_ms, 15000)
                )
            },
            ListenOpts = maps:merge(
                #{port => Port, ip => Ip, ssl => normalize_ssl(Opts)},
                maps:with([max_connections, acceptors], Opts)
            ),
            barrel_mcp_listener_sup:start_listener(
                ?STREAM_LISTENER, ListenOpts, EngineConfig
            )
    end.

%% @doc Stop the Streamable HTTP server.
-spec stop() -> ok | {error, not_found}.
stop() ->
    barrel_mcp_listener_sup:stop_listener(?STREAM_LISTENER).

normalize_ssl(Opts) ->
    case maps:get(ssl, Opts, undefined) of
        #{certfile := _, keyfile := _} = Ssl -> Ssl;
        _ -> undefined
    end.
