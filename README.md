# barrel_mcp

MCP (Model Context Protocol) library for Erlang. Implements the
MCP specification (protocol `2025-11-25` with downward negotiation
through `2024-11-05`) for both server and client modes, including
the Streamable HTTP transport for Claude Code and any other MCP
client.

## Features

- **Full MCP Protocol**: tools, resources, resource templates,
  prompts, completions, sampling, **tasks** (long-running
  operations), notifications (`*/list_changed`, `progress`,
  `cancelled`, `resources/updated`, `tasks/changed`,
  `replay_truncated`).
- **Tool handlers**: arity 1 or arity 2 (`(Args, Ctx)`) with
  `Ctx`-driven progress and cancel hooks. Return shapes:
  plain content, `{tool_error, ...}` (→ `isError: true`), or
  `{structured, Data, ...}` (→ `structuredContent`).
- **Schema validation**: opt-in `validate_input` /
  `validate_output` against registered JSON Schemas
  (`barrel_mcp_schema`).
- **Transports**: Streamable HTTP (Claude Code), legacy HTTP
  (Cowboy), stdio (Claude Desktop). Streamable HTTP defaults to
  `127.0.0.1`, validates `Origin`, and replays SSE events via
  `Last-Event-ID`.
- **Authentication**: bearer (JWT/opaque), API keys (peppered
  HMAC-SHA-256), basic (PBKDF2-SHA256), custom providers.
  Constant-time hash comparison; legacy SHA-256 hex digests still
  verify for one release.
- **Client library** (`barrel_mcp_client`): supervised
  `gen_statem` with stdio + Streamable HTTP transports, OAuth 2.1
  + PKCE, federation registry (one connection per server id),
  pagination, schema pre-flight.
- **Zero JSON dependency**: uses OTP 27+ built-in `json` module.

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

## Usage by role

barrel_mcp covers the three MCP roles in one library:

- **server** — exposes tools, resources, prompts to MCP clients.
- **client** — connects to one MCP server, calls tools, reads
  resources, handles server-initiated requests.
- **host (agent)** — drives one or more clients on behalf of an
  LLM; collects each server's tool catalog, hands it to the
  model, routes the model's tool call back through the right
  client.

The three short examples below cover the typical wiring; deeper
guides live under `guides/` (`getting-started.md`,
`tools-resources-prompts.md`, `building-a-client.md`).

### Server — expose a tool over Streamable HTTP

```erlang
-module(my_server).
-export([start/0, search/1]).

start() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp:reg_tool(<<"search">>, ?MODULE, search, #{
        description => <<"Search the index">>,
        input_schema => #{<<"type">> => <<"object">>,
                           <<"required">> => [<<"q">>]}
    }),
    {ok, _} = barrel_mcp:start_http_stream(#{port => 8080,
                                              session_enabled => true}),
    ok.

search(#{<<"q">> := Q}) ->
    iolist_to_binary([<<"results for ">>, Q]).
```

That's a complete MCP server. Point any MCP client (Claude Code,
Claude Desktop via stdio, the `barrel_mcp_client` below, …) at
`http://127.0.0.1:8080/mcp`.

### Client — connect and call a tool

```erlang
client_demo() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport => {http, <<"http://127.0.0.1:8080/mcp">>}
    }),
    {ok, Result} = barrel_mcp_client:call_tool(
                     Pid, <<"search">>, #{<<"q">> => <<"hello">>}),
    barrel_mcp_client:close(Pid),
    Result.
```

The transport tuple selects the wire (`{http, Url}`,
`{stdio, [Cmd | Args]}`). Auth and OAuth options live on the same
spec — see `guides/building-a-client.md`.

### Host (agent) — hand many MCP servers to an LLM

```erlang
agent_loop() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = barrel_mcp:start_client(<<"github">>, #{
        transport => {http, <<"https://mcp.github.example/mcp">>},
        auth => {bearer, GhToken}
    }),
    {ok, _} = barrel_mcp:start_client(<<"shell">>, #{
        transport => {stdio, ["mcp-shell-server"]}
    }),
    %% Hand every connected server's tools to the model:
    AnthropicTools = barrel_mcp_agent:to_anthropic(),
    %% ... call the LLM with AnthropicTools and capture the
    %%     tool_use block it returned ...
    Block = ask_llm(AnthropicTools),
    {NsName, Args} = barrel_mcp_tool_format:from_anthropic_call(Block),
    %% Routes "github:..." to the github client, "shell:..." to
    %% the shell client.
    barrel_mcp_agent:call_tool(NsName, Args).
```

`barrel_mcp_agent` namespaces tool names as
`<<"ServerId:ToolName">>` across the federation.
`barrel_mcp_tool_format` translates between MCP tool maps and the
provider shapes (Anthropic Messages API, OpenAI Chat Completions);
swap `to_anthropic/0` and `from_anthropic_call/1` for the OpenAI
counterparts to use a different model. `ask_llm/1` is your own
LLM HTTP call — barrel_mcp does not bundle an LLM SDK.

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

### Starting Streamable HTTP Server (Claude Code)

For Claude Code integration, use the Streamable HTTP transport:

```erlang
%% Start Streamable HTTP server on port 9090
{ok, _} = barrel_mcp:start_http_stream(#{port => 9090}).

%% With API key authentication
{ok, _} = barrel_mcp:start_http_stream(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            keys => #{<<"my-key">> => #{subject => <<"user">>}}
        }
    }
}).
```

Then add to Claude Code:

```bash
claude mcp add my-server --transport http http://localhost:9090/mcp \
  --header "X-API-Key: my-key"
```

See `guides/http-stream.md` for full documentation.

### Starting HTTP Server (Legacy)

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
| `barrel_mcp_auth_custom` | Custom auth module (simple interface) |

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

### Custom Authentication (Simple Interface)

For integrating with existing auth systems, use `barrel_mcp_auth_custom` with a simple two-function module:

```erlang
-module(my_auth).
-export([init/1, authenticate/2]).

init(_Opts) ->
    {ok, #{}}.

authenticate(Token, State) ->
    case my_key_store:validate(Token) of
        {ok, Info} ->
            {ok, #{subject => Info}, State};
        error ->
            {error, invalid_token, State}
    end.
```

Configure it:

```erlang
{ok, _} = barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_custom,
        provider_opts => #{
            module => my_auth
        }
    }
}).
```

See `guides/custom-authentication.md` for full documentation.

### Custom Authentication Provider (Full Behaviour)

For more control, implement the full `barrel_mcp_auth` behaviour:

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

`barrel_mcp_client` is a `gen_statem`. Start it, wait for the
handshake to complete, call tools.

```erl
{ok, Pid} = barrel_mcp_client:start_link(#{
    transport => {http, <<"http://localhost:9090/mcp">>}
}),
{ok, Tools}  = barrel_mcp_client:list_tools(Pid),
{ok, Result} = barrel_mcp_client:call_tool(Pid, <<"search">>,
                                           #{<<"query">> => <<"hello">>}),
ok = barrel_mcp_client:close(Pid).
```

For the full task-oriented walkthrough — transport choice, auth,
OAuth, server-to-client handlers, federation, schema validation —
see [Building a client](guides/building-a-client.md). For
architecture and behaviour contracts, see
[Internals](guides/internals.md). Two runnable examples live under
[`examples/`](examples/).

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
| `barrel_mcp:start_http_stream(Opts)` | Start Streamable HTTP server (Claude Code) |
| `barrel_mcp:stop_http_stream()` | Stop Streamable HTTP server |
| `barrel_mcp:start_http(Opts)` | Start HTTP server (legacy) |
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
