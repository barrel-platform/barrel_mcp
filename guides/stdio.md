# stdio Transport

The stdio transport enables MCP communication over stdin/stdout, which is the
transport used by Claude Desktop and other MCP clients that spawn server processes.

## Overview

Unlike HTTP transport, stdio transport:

- Uses newline-delimited JSON-RPC messages
- Runs as a child process spawned by the MCP client
- Is ideal for local integrations (no network overhead)
- Is the primary transport for Claude Desktop

## Quick Start

### 1. Create an Escript

```erlang
#!/usr/bin/env escript
%%! -pa _build/default/lib/*/ebin

-module(my_mcp_server).
-mode(compile).

main(_Args) ->
    %% Start the application
    application:ensure_all_started(barrel_mcp),
    barrel_mcp_registry:wait_for_ready(),

    %% Register your tools
    barrel_mcp:reg_tool(<<"hello">>, my_mcp_server, hello, #{
        description => <<"Say hello">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"name">> => #{
                    <<"type">> => <<"string">>,
                    <<"description">> => <<"Name to greet">>
                }
            }
        }
    }),

    %% Start stdio server (blocks until stdin closes)
    barrel_mcp:start_stdio().

hello(Args) ->
    Name = maps:get(<<"name">>, Args, <<"World">>),
    <<"Hello, ", Name/binary, "!">>.
```

### 2. Make it Executable

```bash
chmod +x my_mcp_server
```

### 3. Configure Claude Desktop

Edit your `claude_desktop_config.json`:

**macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`
**Windows**: `%APPDATA%\Claude\claude_desktop_config.json`
**Linux**: `~/.config/claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "my-erlang-server": {
      "command": "/absolute/path/to/my_mcp_server",
      "args": []
    }
  }
}
```

### 4. Restart Claude Desktop

After saving the config, restart Claude Desktop. Your MCP server will be available.

## Blocking vs Supervised Mode

### Blocking Mode

Use `barrel_mcp:start_stdio/0` when you want the server to run in the current process:

```erlang
main(_Args) ->
    setup_tools(),
    barrel_mcp:start_stdio().  %% Blocks here
```

This is ideal for escripts and simple applications.

### Supervised Mode

Use `barrel_mcp:start_stdio_link/0` when you want the server supervised:

```erlang
-module(my_app_sup).
-behaviour(supervisor).
-export([init/1]).

init([]) ->
    %% Ensure tools are registered first
    setup_tools(),

    Children = [
        #{id => mcp_stdio,
          start => {barrel_mcp, start_stdio_link, []},
          restart => permanent,
          type => worker}
    ],
    {ok, {#{strategy => one_for_one}, Children}}.
```

## Protocol Details

### Message Format

Each message is a single line of JSON (newline-delimited):

```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}\n
```

### Supported Methods

The stdio transport supports all MCP methods:

- `initialize` / `initialized` - Connection lifecycle
- `tools/list` / `tools/call` - Tool operations
- `resources/list` / `resources/read` - Resource operations
- `prompts/list` / `prompts/get` - Prompt operations
- `ping` - Keep-alive

### Notifications

MCP notifications (methods without `id`) don't receive responses:

```
{"jsonrpc":"2.0","method":"notifications/initialized"}\n
```

## Building Releases

For production use, build an Erlang release instead of an escript.

### Using rebar3 Release

1. Add to `rebar.config`:

```erlang
{relx, [
    {release, {my_mcp_server, "1.0.0"}, [my_app, barrel_mcp]},
    {mode, prod},
    {extended_start_script, true}
]}.
```

2. Create your main module:

```erlang
-module(my_mcp_main).
-export([start/0]).

start() ->
    %% Called when release starts
    setup_tools(),
    barrel_mcp:start_stdio().
```

3. Configure your app to call this on start:

```erlang
%% In your application module
start(_Type, _Args) ->
    %% Start your supervisor
    {ok, Sup} = my_app_sup:start_link(),

    %% If running in MCP mode, start stdio
    case application:get_env(my_app, mcp_mode, false) of
        true -> spawn(fun my_mcp_main:start/0);
        false -> ok
    end,

    {ok, Sup}.
```

4. Build and run:

```bash
rebar3 release
_build/default/rel/my_mcp_server/bin/my_mcp_server foreground
```

## Debugging

### Testing Locally

You can test your stdio server manually:

```bash
# Start your server
./my_mcp_server

# Then type JSON-RPC messages (each on one line):
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hello","arguments":{"name":"Erlang"}}}
```

### Logging

Since stdout is used for MCP responses, use stderr for debugging:

```erlang
debug(Msg) ->
    io:format(standard_error, "[DEBUG] ~s~n", [Msg]).
```

Or use Erlang's logger to a file:

```erlang
%% Configure in your app startup
logger:add_handler(file_handler, logger_std_h, #{
    config => #{file => "/tmp/mcp_server.log"}
}).
```

### Common Issues

**Server not appearing in Claude Desktop:**
- Check config file path and JSON syntax
- Use absolute path to executable
- Restart Claude Desktop after config changes

**"Command not found" errors:**
- Ensure the executable has the shebang line
- Check file permissions (`chmod +x`)
- Use absolute paths in config

**No responses:**
- Ensure all tools are registered before `start_stdio/0`
- Check stderr for errors

## Environment Variables

Claude Desktop passes environment variables to your server:

```erlang
%% Access them in your code
HomeDir = os:getenv("HOME"),
PathVar = os:getenv("PATH").
```

You can also configure environment in `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "/path/to/my_mcp_server",
      "args": [],
      "env": {
        "MY_CONFIG": "/path/to/config.json",
        "DEBUG": "true"
      }
    }
  }
}
```

## Working Directory

The working directory is typically the user's home directory or where
Claude Desktop was launched. To ensure consistent behavior:

```erlang
%% Set a known working directory
file:set_cwd("/path/to/my/app"),

%% Or use absolute paths for all file operations
ConfigPath = filename:join([os:getenv("HOME"), ".config", "myapp"]).
```

## See Also

- [Getting Started](getting-started.md) - Basic setup
- [Tools, Resources & Prompts](tools-resources-prompts.md) - MCP primitives
- `barrel_mcp_stdio` module documentation
