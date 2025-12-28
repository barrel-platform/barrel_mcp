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

%% Tool handler - receives arguments as a map
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
{ok, _} = barrel_mcp:start_http(#{port => 9090}).
```

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

- [Tools, Resources & Prompts](tools-resources-prompts.md) - Learn about MCP primitives
- [Authentication](authentication.md) - Secure your MCP server
- [MCP Client](client.md) - Connect to external MCP servers
