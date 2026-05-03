# Getting Started

This guide will help you get started with barrel_mcp, an Erlang library implementing
the Model Context Protocol (MCP) specification.

## Installation

Add barrel_mcp to your `rebar.config` dependencies:

```erlang
{deps, [
    {barrel_mcp, "1.0.0"}
]}.
```

Or from git:

```erlang
{deps, [
    {barrel_mcp, {git, "https://github.com/barrel-db/barrel_mcp.git", {tag, "v1.0.0"}}}
]}.
```

## Starting the Application

```erlang
%% Start the barrel_mcp application
application:ensure_all_started(barrel_mcp).

%% Wait for registry to be ready (recommended)
ok = barrel_mcp_registry:wait_for_ready().
```

## Your First MCP Server

### 1. Register a Tool

Tools are functions that can be called by MCP clients (like Claude):

```erlang
-module(my_tools).
-export([greet/1]).

%% Arity-1 handler — gets only the call arguments. The simplest
%% shape; pick this when you don't need progress, cancellation, or
%% session context. For arity-2 handlers (with a Ctx parameter),
%% see the Tools guide.
greet(Args) ->
    Name = maps:get(<<"name">>, Args, <<"World">>),
    <<"Hello, ", Name/binary, "!">>.
```

Register it:

```erlang
barrel_mcp:reg_tool(<<"greet">>, my_tools, greet, #{
    description => <<"Greet someone by name">>,
    input_schema => #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"name">> => #{
                <<"type">> => <<"string">>,
                <<"description">> => <<"Name to greet">>
            }
        }
    }
}).
```

### 2. Start the HTTP Server

```erlang
{ok, _} = barrel_mcp:start_http_stream(#{port => 9090}).
```

The Streamable HTTP server binds to `127.0.0.1` by default and
validates the `Origin` header on every request. Public binds (any
non-loopback IP) require an explicit `allowed_origins` — see the
[Streamable HTTP guide](http-stream.md) for the security defaults.

The legacy plain-HTTP transport (`start_http/1`, JSON-RPC only,
protocol `2024-11-05`) is still available for clients that don't
speak the Streamable HTTP transport.

### 3. Test Your Server

Using curl:

```bash
# Initialize
curl -X POST http://localhost:9090/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

# List tools
curl -X POST http://localhost:9090/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# Call your tool
curl -X POST http://localhost:9090/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"greet","arguments":{"name":"Erlang"}}}'
```

## Using with Claude Desktop

For Claude Desktop integration, use the stdio transport:

1. Create an escript or release that calls `barrel_mcp:start_stdio()`
2. Configure Claude Desktop's `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/my_app",
      "args": ["mcp"]
    }
  }
}
```

## Next Steps

- [Tools, Resources & Prompts](tools-resources-prompts.md) — handler shapes (arity 1 / arity 2 with `Ctx`), tool errors, structured output, long-running tasks, completions, resource templates, server notifications.
- [Streamable HTTP transport](http-stream.md) — security defaults, CORS, `Origin` validation, response codes, replay.
- [Authentication](authentication.md) — bearer / API key / basic, modern hash formats.
- [Features matrix](features.md) — what's supported on the wire.
- [Building a client](building-a-client.md) — task-oriented walkthrough for hosting MCP clients.
- [Client internals](internals.md) — architecture and behaviour contracts.
- [MCP Client (reference)](client.md) - Older API reference, kept for cross-linking
