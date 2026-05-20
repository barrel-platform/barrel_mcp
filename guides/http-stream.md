# Streamable HTTP Transport

MCP Streamable HTTP transport for Claude Code (and any other MCP
client speaking the same protocol).

## Overview

The Streamable HTTP transport implements MCP `2025-11-25` and
negotiates downward to `2025-06-18`, `2025-03-26`, and
`2024-11-05` based on the client's `initialize` request. It is the
transport expected by Claude Code's `--transport http` option.

This transport supports:

- **POST** for client requests with JSON or SSE streaming responses.
- **GET** for server-to-client notification streams (SSE).
- **DELETE** for session termination.
- **OPTIONS** for CORS preflight.
- **Session management** via `Mcp-Session-Id` header.
- **Replay on reconnect** via `Last-Event-ID`.
- **Origin validation** with operator-controlled allow-list.

The built-in server is built on the `h1` and `h2` libraries, not
Cowboy. A cleartext bind speaks HTTP/1.1; a TLS bind serves both
HTTP/1.1 and HTTP/2 on the same port, chosen per connection by ALPN.
The protocol logic lives in a transport-neutral engine
(`barrel_mcp_http_engine`), so the same Streamable HTTP behaviour can
be driven by another HTTP stack (see
[Embedding in another HTTP server](#embedding-in-another-http-server)).

## Starting the Server

```erlang
%% Basic start
barrel_mcp:start_http_stream(#{port => 9090}).

%% With API key authentication
barrel_mcp:start_http_stream(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            keys => #{
                <<"my-api-key">> => #{subject => <<"user1">>}
            }
        }
    }
}).

%% With session management disabled
barrel_mcp:start_http_stream(#{
    port => 9090,
    session_enabled => false
}).

%% With HTTPS/TLS
barrel_mcp:start_http_stream(#{
    port => 9443,
    ssl => #{
        certfile => "/path/to/cert.pem",
        keyfile => "/path/to/key.pem"
    }
}).
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `port` | `pos_integer()` | `9090` | Port number. |
| `ip` | `inet:ip_address()` | `{127,0,0,1}` | Bind address. **Default is loopback.** Public binds require `allowed_origins` (see below). |
| `auth` | `map()` | `#{}` | Authentication configuration. |
| `session_enabled` | `boolean()` | `true` | Enable session management. |
| `ssl` | `map()` | `undefined` | TLS configuration. |
| `allowed_origins` | `[binary()] \| any` | loopback set on loopback bind; required on public bind | List of allowed `Origin` values, structurally matched (scheme + host + port). Use `any` to disable validation. The literal `<<"null">>` may be included to allow sandboxed-frame origins. |
| `allow_missing_origin` | `boolean()` | `true` on loopback, `false` otherwise | Whether to accept requests with no `Origin` header. Non-browser clients typically don't send one. |
| `sse_buffer_size` | `pos_integer()` | `256` | Per-session ring buffer of recent SSE events for `Last-Event-ID` replay. |

### Security defaults

The transport binds to `127.0.0.1` by default. Public binds (any
non-loopback IP) require an explicit `allowed_origins`; the start
function refuses with `{error, allowed_origins_required}`
otherwise. This avoids accidental exposure to DNS-rebinding and
CORS-style attacks.

```erlang
%% Public bind — must list allowed origins explicitly.
{ok, _} = barrel_mcp:start_http_stream(#{
    port => 9090,
    ip => {0, 0, 0, 0},
    allowed_origins => [<<"https://app.example.com">>]
}).
```

CORS responses echo the validated `Origin` (no wildcard) and add
`Vary: Origin`. The `Access-Control-Allow-Headers` list is
derived from the configured auth provider via the optional
`auth_headers/1` callback on `barrel_mcp_auth`, so a custom
`header_name` on `barrel_mcp_auth_apikey` flows through both the
preflight allow-list and the request handler's header extraction.

## Claude Code Integration

After starting the server, add it to Claude Code:

```bash
# Without authentication
claude mcp add my-server --transport http http://localhost:9090/mcp

# With API key authentication
claude mcp add my-server --transport http http://localhost:9090/mcp \
  --header "X-API-Key: my-api-key"

# With bearer token
claude mcp add my-server --transport http http://localhost:9090/mcp \
  --header "Authorization: Bearer my-token"
```

To verify the connection:

```bash
claude mcp list
```

## Authentication

All authentication providers from barrel_mcp are supported:

### No Authentication (Default)

```erlang
barrel_mcp:start_http_stream(#{port => 9090}).
```

### API Key

```erlang
barrel_mcp:start_http_stream(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            keys => #{<<"key-123">> => #{subject => <<"user">>}}
        }
    }
}).
```

### Bearer Token (JWT)

```erlang
barrel_mcp:start_http_stream(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_bearer,
        provider_opts => #{
            secret => <<"your-jwt-secret">>
        }
    }
}).
```

### Basic Auth

```erlang
barrel_mcp:start_http_stream(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_basic,
        provider_opts => #{
            credentials => #{<<"admin">> => <<"password">>}
        }
    }
}).
```

## Session Management

When `session_enabled` is `true` (default), the server tracks client sessions:

- Each client receives an `Mcp-Session-Id` header in responses
- Sessions expire after 30 minutes of inactivity (configurable via `session_ttl` env)
- GET requests open SSE streams for server notifications
- DELETE requests terminate sessions

### Session Lifecycle

1. **First Request**: Client sends POST without session ID
2. **Session Created**: Server responds with `Mcp-Session-Id: mcp_<hex>`
3. **Subsequent Requests**: Client includes `Mcp-Session-Id` header
4. **Termination**: Client sends DELETE with session ID

### Configuring Session TTL

```erlang
%% In sys.config
{barrel_mcp, [
    {session_ttl, 3600000}  %% 1 hour in milliseconds
]}.
```

## Server-Sent Events (SSE)

Clients that accept `text/event-stream` can receive streaming responses:

### Request Format

```
POST /mcp HTTP/1.1
Accept: text/event-stream, application/json
Content-Type: application/json
Mcp-Session-Id: mcp_abc123

{"jsonrpc": "2.0", "method": "tools/list", "id": 1}
```

### Response Format

```
HTTP/1.1 200 OK
Content-Type: text/event-stream
Mcp-Session-Id: mcp_abc123

id: 1706345678901234
data: {"jsonrpc": "2.0", "result": {...}, "id": 1}
```

## HTTPS/TLS

For production deployments, enable HTTPS:

```erlang
barrel_mcp:start_http_stream(#{
    port => 9443,
    ssl => #{
        certfile => "/path/to/fullchain.pem",
        keyfile => "/path/to/privkey.pem",
        cacertfile => "/path/to/chain.pem"  %% optional
    }
}).
```

A TLS bind advertises ALPN `h2` and `http/1.1`, so the one port
serves HTTP/2 clients and HTTP/1.1 clients alike; `certfile`/`keyfile`
(and optional `cacertfile`) are file paths. Then use the HTTPS URL
with Claude Code:

```bash
claude mcp add my-server --transport http https://my-server.example.com:9443/mcp
```

## CORS and request validation

The server validates `Origin` on every request method (POST, GET,
DELETE, OPTIONS) and replies with 403 on mismatch. When the
request's `Origin` validates, the response includes:

- `Access-Control-Allow-Origin: <validated origin>`
- `Vary: Origin`
- `Access-Control-Allow-Methods: POST, GET, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: content-type, accept,
  mcp-session-id, mcp-protocol-version, last-event-id` plus any
  auth headers declared by the configured provider.
- `Access-Control-Expose-Headers: www-authenticate,
  mcp-session-id, mcp-protocol-version`

When the request has no `Origin` header (typical of non-browser
clients) and `allow_missing_origin` is `true`, the response omits
`Access-Control-Allow-Origin` entirely rather than synthesising a
value.

## Wire-level conformance

The transport implements MCP `2025-11-25` conformance points
explicitly:

| Wire | Behaviour |
| --- | --- |
| `MCP-Protocol-Version` request header | Required after init. Unsupported value → 400; missing falls back to the session-stored negotiated version; pre-init missing assumes `2025-03-26`. |
| `Mcp-Session-Id` request header | Required on every non-`initialize` request when `session_enabled` is true. Missing → 400; unknown id → 404. `initialize` is the only request that creates a session. |
| Notifications and posted server-bound responses | HTTP 202 Accepted, empty body. |
| JSON-RPC ids | Must be string or integer. `null` or any other shape → -32600 Invalid Request. |
| JSON-RPC batches | Top-level JSON arrays explicitly rejected with -32600 (MCP removed batching). |
| `notifications/cancelled` | Cancels the in-flight tool call; the originating HTTP request closes with 200 and an empty body (no JSON-RPC envelope, per spec). |

The session, subscription, and pending-request ETS tables are
`protected`; mutators run in the session manager so a non-owning
process cannot tamper with the table.

## Protocol Differences

### vs Legacy HTTP Transport

| Feature | Legacy (`start_http`) | Streamable (`start_http_stream`) |
|---------|----------------------|----------------------------------|
| Protocol Version | 2024-11-05 | 2025-11-25 (negotiates downward) |
| Claude Code | Not supported | Supported |
| Sessions | No | Yes |
| SSE Responses | No | Yes |
| GET for streams | No | Yes |
| DELETE for cleanup | No | Yes |
| Origin validation | Yes | Yes |

### When to Use

- **Use `start_http_stream`** for Claude Code integration
- **Use `start_http`** for simple JSON-RPC clients
- **Use `start_stdio`** for Claude Desktop integration

## Embedding in another HTTP server

The built-in `h1`/`h2` server is one binding over a transport-neutral
engine, `barrel_mcp_http_engine`. If you already run an HTTP server
(for example the Livery web framework) you can serve MCP through it by
calling the engine directly, with no second listener.

For each request, read the method, path, headers and body, then call:

```erlang
barrel_mcp_http_engine:handle(Method, Path, Headers, Body, Responder, Config).
```

- `Method` is the request method binary (`<<"POST">>`, `<<"GET">>` …).
- `Path` is the request target (a query string is allowed; the engine
  strips it).
- `Headers` is a `[{binary(), binary()}]` proplist; lookups are
  case-insensitive.
- `Body` is the full request body (`<<>>` when there is none).

`Responder` is a map of closures the engine uses to send the response,
so it never touches a socket:

```erlang
#{reply        => fun(Status, Headers, Body) -> ok end,
  stream_start => fun(Status, Headers) -> ok end,
  stream_chunk => fun(Data) -> ok | {error, term()} end,
  stream_end   => fun() -> ok end}
```

`Headers` passed back to the closures is a `[{binary(), binary()}]`
proplist. A normal response is a single `reply`; a Server-Sent-Events
response is `stream_start`, then repeated `stream_chunk`, then
`stream_end`. `handle/6` runs in the calling process; for a long-lived
GET SSE stream it blocks until the session ends or the host signals a
disconnect by sending the calling process the message `mcp_disconnect`.

`Config` is the engine configuration. Build it the way the bindings do
(`barrel_mcp_http_stream:start/1` for `mode => stream`,
`barrel_mcp_http:start/1` for `mode => simple`) using the shared
helpers:

```erlang
Config = #{
    mode => stream,            %% or `simple'
    auth_config =>
        barrel_mcp_http_engine:init_auth(#{provider => barrel_mcp_auth_none}),
    session_enabled => true,
    allowed_origins => any,    %% or a resolved allow-list
    allow_missing_origin => true,
    sse_buffer_size => 256,
    resource_metadata => undefined
}.
```

The engine handles routing (`/mcp`, `/`, and
`/.well-known/oauth-protected-resource`), sessions, CORS, Origin
validation, authentication and async tool calls, identically to the
built-in server.

## Example: Complete Server

```erlang
-module(my_mcp_server).
-export([start/0]).

start() ->
    %% Start the application
    application:ensure_all_started(barrel_mcp),

    %% Register tools
    barrel_mcp:reg_tool(<<"greet">>, ?MODULE, greet, #{
        description => <<"Greet someone">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"name">> => #{<<"type">> => <<"string">>}
            }
        }
    }),

    %% Start streamable HTTP server
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => 9090,
        auth => #{
            provider => barrel_mcp_auth_apikey,
            provider_opts => #{
                keys => #{<<"test-key">> => #{subject => <<"tester">>}}
            }
        }
    }),

    io:format("MCP server running on http://localhost:9090/mcp~n"),
    io:format("Add to Claude Code:~n"),
    io:format("  claude mcp add my-server --transport http http://localhost:9090/mcp --header \"X-API-Key: test-key\"~n").

greet(Args) ->
    Name = maps:get(<<"name">>, Args, <<"World">>),
    <<"Hello, ", Name/binary, "!">>.
```

## See Also

- [Authentication Guide](authentication.md)
- [Tools, Resources & Prompts](tools-resources-prompts.md)
- [MCP Specification](https://spec.modelcontextprotocol.io/)
