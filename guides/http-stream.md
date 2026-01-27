# Streamable HTTP Transport

MCP Streamable HTTP transport (protocol 2025-03-26) for Claude Code integration.

## Overview

The Streamable HTTP transport implements the MCP protocol version 2025-03-26, which is the transport expected by Claude Code's `--transport http` option.

This transport supports:
- **POST** for client requests with JSON or SSE streaming responses
- **GET** for server-to-client notification streams (SSE)
- **DELETE** for session termination
- **OPTIONS** for CORS preflight
- **Session management** via `Mcp-Session-Id` header

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
| `port` | `pos_integer()` | `9090` | Port number |
| `ip` | `inet:ip_address()` | `{0,0,0,0}` | IP address to bind |
| `auth` | `map()` | `#{}` | Authentication configuration |
| `session_enabled` | `boolean()` | `true` | Enable session management |
| `ssl` | `map()` | `undefined` | TLS configuration |

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

Then use HTTPS URL with Claude Code:

```bash
claude mcp add my-server --transport http https://my-server.example.com:9443/mcp
```

## CORS

The server includes CORS headers for browser-based clients:

- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: POST, GET, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: content-type, authorization, x-api-key, mcp-session-id, accept`
- `Access-Control-Expose-Headers: www-authenticate, mcp-session-id`

## Protocol Differences

### vs Legacy HTTP Transport

| Feature | Legacy (`start_http`) | Streamable (`start_http_stream`) |
|---------|----------------------|----------------------------------|
| Protocol Version | 2024-11-05 | 2025-03-26 |
| Claude Code | Not supported | Supported |
| Sessions | No | Yes |
| SSE Responses | No | Yes |
| GET for streams | No | Yes |
| DELETE for cleanup | No | Yes |

### When to Use

- **Use `start_http_stream`** for Claude Code integration
- **Use `start_http`** for simple JSON-RPC clients
- **Use `start_stdio`** for Claude Desktop integration

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
