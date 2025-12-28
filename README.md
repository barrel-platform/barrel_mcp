# barrel_mcp

MCP (Model Context Protocol) library for Erlang. Implements the full MCP 2024-11-05 specification for both server and client modes.

## Features

- **Full MCP Protocol Support**: Tools, Resources, Prompts, and Sampling
- **Multiple Transports**: HTTP (Cowboy) and stdio (for Claude Desktop)
- **Pluggable Authentication**: Bearer JWT, API keys, Basic auth, or custom providers
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

## Authentication

barrel_mcp provides pluggable authentication following OAuth 2.1 patterns as recommended by the MCP specification. Authentication is optional and configurable per HTTP server.

### Built-in Providers

| Provider | Description |
|----------|-------------|
| `barrel_mcp_auth_none` | No authentication (default) |
| `barrel_mcp_auth_bearer` | Bearer token (JWT or opaque) |
| `barrel_mcp_auth_apikey` | API key authentication |
| `barrel_mcp_auth_basic` | HTTP Basic authentication |

### Bearer Token (JWT) Authentication

```erlang
%% Start HTTP server with JWT authentication
{ok, _} = barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_bearer,
        provider_opts => #{
            secret => <<"your-jwt-secret-key">>,
            issuer => <<"https://auth.example.com">>,
            audience => <<"https://mcp.example.com">>,
            clock_skew => 60  % seconds
        },
        required_scopes => [<<"mcp:read">>, <<"mcp:write">>]
    }
}).
```

For RS256/ES256 or opaque tokens, use a custom verifier:

```erlang
%% Custom token verifier (e.g., for token introspection)
Verifier = fun(Token) ->
    case my_auth_service:validate(Token) of
        {ok, Claims} -> {ok, Claims};
        error -> {error, invalid_token}
    end
end,

{ok, _} = barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_bearer,
        provider_opts => #{verifier => Verifier}
    }
}).
```

### API Key Authentication

```erlang
%% Simple API key list
{ok, _} = barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            keys => #{
                <<"key-abc123">> => #{subject => <<"user1">>, scopes => [<<"read">>]},
                <<"key-xyz789">> => #{subject => <<"user2">>, scopes => [<<"read">>, <<"write">>]}
            }
        }
    }
}).

%% With hashed keys for security (recommended for production)
HashedKey = barrel_mcp_auth_apikey:hash_key(<<"my-secret-key">>),
{ok, _} = barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            keys => #{HashedKey => #{subject => <<"user1">>}},
            hash_keys => true
        }
    }
}).
```

### Basic Authentication

```erlang
%% Simple username/password
{ok, _} = barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_basic,
        provider_opts => #{
            credentials => #{
                <<"admin">> => <<"password123">>,
                <<"user">> => <<"secret">>
            },
            realm => <<"MCP Server">>
        }
    }
}).

%% With hashed passwords (recommended)
HashedPwd = barrel_mcp_auth_basic:hash_password(<<"my-password">>),
{ok, _} = barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_basic,
        provider_opts => #{
            credentials => #{<<"admin">> => HashedPwd},
            hash_passwords => true
        }
    }
}).
```

### Custom Authentication Provider

Implement the `barrel_mcp_auth` behaviour:

```erlang
-module(my_auth_provider).
-behaviour(barrel_mcp_auth).

-export([init/1, authenticate/2, challenge/2]).

init(Opts) ->
    {ok, Opts}.

authenticate(Request, State) ->
    Headers = maps:get(headers, Request, #{}),
    case barrel_mcp_auth:extract_bearer_token(Headers) of
        {ok, Token} ->
            %% Your validation logic
            case validate_with_my_service(Token) of
                {ok, User} ->
                    {ok, #{
                        subject => User,
                        scopes => [<<"read">>],
                        claims => #{}
                    }};
                error ->
                    {error, invalid_token}
            end;
        {error, no_token} ->
            {error, unauthorized}
    end.

challenge(Reason, _State) ->
    {401, #{<<"www-authenticate">> => <<"Bearer realm=\"mcp\"">>}, <<>>}.
```

### Accessing Auth Info in Handlers

Authentication info is available in the request context:

```erlang
my_tool_handler(Args) ->
    %% Auth info is passed in the _auth key
    case maps:get(<<"_auth">>, Args, undefined) of
        undefined ->
            <<"No auth info">>;
        AuthInfo ->
            Subject = maps:get(subject, AuthInfo),
            <<"Hello ", Subject/binary>>
    end.
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

### Authentication

| Function | Description |
|----------|-------------|
| `barrel_mcp_auth:extract_bearer_token(Headers)` | Extract Bearer token from headers |
| `barrel_mcp_auth:extract_api_key(Headers, Opts)` | Extract API key from headers |
| `barrel_mcp_auth:extract_basic_auth(Headers)` | Extract Basic auth credentials |
| `barrel_mcp_auth_apikey:hash_key(Key)` | Hash an API key (SHA256) |
| `barrel_mcp_auth_basic:hash_password(Password)` | Hash a password (SHA256) |

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
