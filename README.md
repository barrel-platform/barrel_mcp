# barrel_mcp

MCP (Model Context Protocol) library for Erlang. Implements the full MCP 2024-11-05 specification for both server and client modes.

## Features

- **Full MCP Protocol Support**: Tools, Resources, Prompts, and Sampling
- **Multiple Transports**: HTTP (Cowboy) and stdio (for Claude Desktop)
- **Supervised Registry**: gen_statem-based registry with atomic operations
- **Fast Reads**: ETS + persistent_term for O(1) handler lookups (no process call)
- **Ready/Not-Ready States**: Flexible initialization pattern
- **Client Library**: Connect to external MCP servers
- **Zero-dependency JSON**: Uses OTP 27+ built-in `json` module

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {barrel_mcp, {git, "https://github.com/your-org/barrel_mcp.git", {branch, "main"}}}
]}.
```

## Architecture

barrel_mcp uses a supervised gen_statem process to manage the handler registry:

- **Writes** (reg/unreg) go through the gen_statem for atomic operations
- **Reads** (find/all/run) use persistent_term directly for O(1) lookups
- **States**: `not_ready` → `ready` for flexible initialization
- **Postpone pattern**: Calls in `not_ready` state are postponed until ready

```
┌─────────────────────────────────────────────────────────────────┐
│                       barrel_mcp_sup                             │
│                      (supervisor)                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    barrel_mcp_registry                           │
│                      (gen_statem)                                │
│                                                                  │
│  States: not_ready ──────────────────► ready                    │
│              │         (self ! ready)                            │
│              │              or                                   │
│              └──── wait for external process ────►               │
│                                                                  │
│  ┌─────────────┐        ┌─────────────────────────────────────┐ │
│  │  ETS Table  │───────►│     persistent_term (read-only)     │ │
│  │ (authority) │  sync  │         O(1) lookups                │ │
│  └─────────────┘        └─────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
         ▲                              │
         │ reg/unreg                    │ find/all/run
         │ (atomic, postponed           │ (lock-free)
         │  if not ready)               │
```

### Configuration

To make the registry wait for an external process before becoming ready:

```erlang
%% In sys.config or application env
{barrel_mcp, [
    {wait_for_proc, my_init_process}  % Wait for this process to be registered
]}.
```

If `wait_for_proc` is not set, the registry becomes ready immediately after init.

## Quick Start

### Starting the Application

```erlang
%% Start barrel_mcp application
application:ensure_all_started(barrel_mcp).

%% Wait for registry to be ready (optional, for custom initialization)
ok = barrel_mcp_registry:wait_for_ready().
```

### Registering Tools

```erlang
%% Register a tool
barrel_mcp:reg_tool(<<"search">>, my_module, search, #{
    description => <<"Search for items">>,
    input_schema => #{
        type => <<"object">>,
        properties => #{
            query => #{type => <<"string">>, description => <<"Search query">>},
            limit => #{type => <<"integer">>, default => 10}
        },
        required => [<<"query">>]
    }
}).

%% Your handler function (must accept a map and be exported with arity 1)
-module(my_module).
-export([search/1]).

search(#{<<"query">> := Query} = Args) ->
    Limit = maps:get(<<"limit">>, Args, 10),
    %% Return binary, map, or list of content blocks
    <<"Found results for: ", Query/binary>>.
```

### Registering Resources

```erlang
barrel_mcp:reg_resource(<<"config">>, my_module, get_config, #{
    name => <<"Application Config">>,
    uri => <<"config://app/settings">>,
    description => <<"Application configuration">>,
    mime_type => <<"application/json">>
}).
```

### Registering Prompts

```erlang
barrel_mcp:reg_prompt(<<"summarize">>, my_module, summarize_prompt, #{
    description => <<"Summarize content">>,
    arguments => [
        #{name => <<"content">>, description => <<"Content to summarize">>, required => true},
        #{name => <<"style">>, description => <<"Summary style">>, required => false}
    ]
}).

%% Handler returns prompt messages
summarize_prompt(Args) ->
    Content = maps:get(<<"content">>, Args),
    #{
        description => <<"Summarize the following content">>,
        messages => [
            #{role => <<"user">>, content => #{type => <<"text">>, text => Content}}
        ]
    }.
```

### Starting HTTP Server

```erlang
%% Start HTTP server on port 9090
{ok, _} = barrel_mcp:start_http(#{port => 9090}).

%% Or with custom IP binding
{ok, _} = barrel_mcp:start_http(#{port => 9090, ip => {127, 0, 0, 1}}).
```

### Starting stdio Server (for Claude Desktop)

```erlang
%% This blocks and handles MCP over stdin/stdout
barrel_mcp:start_stdio().
```

### Using as Client

```erlang
%% Connect to an MCP server
{ok, Client} = barrel_mcp_client:connect(#{
    transport => {http, <<"http://localhost:9090/mcp">>}
}).

%% Initialize connection
{ok, ServerInfo, Client1} = barrel_mcp_client:initialize(Client).

%% List available tools
{ok, Tools, Client2} = barrel_mcp_client:list_tools(Client1).

%% Call a tool
{ok, Result, Client3} = barrel_mcp_client:call_tool(Client2, <<"search">>, #{
    <<"query">> => <<"hello world">>
}).

%% Close connection
ok = barrel_mcp_client:close(Client3).
```

## Claude Desktop Configuration

When using barrel_mcp with stdio transport for Claude Desktop:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/my_app/bin/my_app",
      "args": ["mcp"]
    }
  }
}
```

Your application's entry point should call `barrel_mcp:start_stdio()`.

## API Reference

### Tools

| Function | Description |
|----------|-------------|
| `barrel_mcp:reg_tool(Name, Module, Function, Opts)` | Register a tool |
| `barrel_mcp:unreg_tool(Name)` | Unregister a tool |
| `barrel_mcp:call_tool(Name, Args)` | Call a tool locally |
| `barrel_mcp:list_tools()` | List all registered tools |

### Resources

| Function | Description |
|----------|-------------|
| `barrel_mcp:reg_resource(Name, Module, Function, Opts)` | Register a resource |
| `barrel_mcp:unreg_resource(Name)` | Unregister a resource |
| `barrel_mcp:read_resource(Name)` | Read a resource locally |
| `barrel_mcp:list_resources()` | List all registered resources |

### Prompts

| Function | Description |
|----------|-------------|
| `barrel_mcp:reg_prompt(Name, Module, Function, Opts)` | Register a prompt |
| `barrel_mcp:unreg_prompt(Name)` | Unregister a prompt |
| `barrel_mcp:get_prompt(Name, Args)` | Get a prompt locally |
| `barrel_mcp:list_prompts()` | List all registered prompts |

### Registry

| Function | Description |
|----------|-------------|
| `barrel_mcp_registry:start_link()` | Start the registry (called by supervisor) |
| `barrel_mcp_registry:wait_for_ready()` | Wait for registry to be ready |
| `barrel_mcp_registry:wait_for_ready(Timeout)` | Wait with custom timeout |

### Server

| Function | Description |
|----------|-------------|
| `barrel_mcp:start_http(Opts)` | Start HTTP server |
| `barrel_mcp:stop_http()` | Stop HTTP server |
| `barrel_mcp:start_stdio()` | Start stdio server (blocking) |

### Client

| Function | Description |
|----------|-------------|
| `barrel_mcp_client:connect(Opts)` | Connect to MCP server |
| `barrel_mcp_client:initialize(Client)` | Initialize connection |
| `barrel_mcp_client:list_tools(Client)` | List available tools |
| `barrel_mcp_client:call_tool(Client, Name, Args)` | Call a tool |
| `barrel_mcp_client:list_resources(Client)` | List available resources |
| `barrel_mcp_client:read_resource(Client, Uri)` | Read a resource |
| `barrel_mcp_client:list_prompts(Client)` | List available prompts |
| `barrel_mcp_client:get_prompt(Client, Name, Args)` | Get a prompt |
| `barrel_mcp_client:close(Client)` | Close connection |

## MCP Protocol Support

### Supported Methods

**Lifecycle:**
- `initialize` / `initialized`
- `ping`

**Tools:**
- `tools/list`
- `tools/call`

**Resources:**
- `resources/list`
- `resources/read`
- `resources/templates/list`
- `resources/subscribe` / `resources/unsubscribe`

**Prompts:**
- `prompts/list`
- `prompts/get`

**Sampling:**
- `sampling/createMessage`

**Logging:**
- `logging/setLevel`

## Development

```bash
# Compile
rebar3 compile

# Run tests
rebar3 eunit

# Dialyzer
rebar3 dialyzer

# Shell
rebar3 shell
```

## License

Apache-2.0
