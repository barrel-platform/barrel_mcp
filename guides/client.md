# MCP Client

barrel_mcp includes a client library for connecting to external MCP servers.
This allows your Erlang application to consume tools, resources, and prompts
from other MCP-compatible services.

## Connecting to a Server

### HTTP Transport

```erlang
%% Connect to an HTTP MCP server
{ok, Client} = barrel_mcp_client:connect(#{
    transport => {http, <<"http://localhost:9090/mcp">>}
}).

%% With custom options
{ok, Client} = barrel_mcp_client:connect(#{
    transport => {http, <<"https://api.example.com/mcp">>},
    timeout => 30000,  %% Request timeout in ms
    headers => #{
        <<"Authorization">> => <<"Bearer your-token">>
    }
}).
```

### stdio Transport

For connecting to local MCP servers via stdin/stdout:

```erlang
{ok, Client} = barrel_mcp_client:connect(#{
    transport => {stdio, "/path/to/mcp-server", ["--arg1", "--arg2"]}
}).
```

## Initializing the Connection

After connecting, initialize to exchange capabilities:

```erlang
{ok, Client} = barrel_mcp_client:connect(#{
    transport => {http, <<"http://localhost:9090/mcp">>}
}),

{ok, ServerInfo, Client1} = barrel_mcp_client:initialize(Client),

%% ServerInfo contains:
%% #{
%%     <<"protocolVersion">> => <<"2024-11-05">>,
%%     <<"serverInfo">> => #{
%%         <<"name">> => <<"example-server">>,
%%         <<"version">> => <<"1.0.0">>
%%     },
%%     <<"capabilities">> => #{
%%         <<"tools">> => #{},
%%         <<"resources">> => #{},
%%         <<"prompts">> => #{}
%%     }
%% }
```

## Working with Tools

### List Available Tools

```erlang
{ok, Tools, Client2} = barrel_mcp_client:list_tools(Client1),

%% Tools is a list of tool definitions:
%% [
%%     #{
%%         <<"name">> => <<"search">>,
%%         <<"description">> => <<"Search for information">>,
%%         <<"inputSchema">> => #{...}
%%     },
%%     ...
%% ]
```

### Call a Tool

```erlang
{ok, Result, Client3} = barrel_mcp_client:call_tool(Client2, <<"search">>, #{
    <<"query">> => <<"erlang mcp">>
}),

%% Result contains the tool output:
%% #{
%%     <<"content">> => [
%%         #{<<"type">> => <<"text">>, <<"text">> => <<"Results...">>}
%%     ]
%% }
```

### Error Handling

```erlang
case barrel_mcp_client:call_tool(Client, <<"unknown">>, #{}) of
    {ok, Result, NewClient} ->
        process_result(Result);
    {error, {method_not_found, _}, NewClient} ->
        logger:warning("Tool not found"),
        handle_missing_tool();
    {error, Reason, NewClient} ->
        logger:error("Tool call failed: ~p", [Reason]),
        handle_error(Reason)
end.
```

## Working with Resources

### List Resources

```erlang
{ok, Resources, Client2} = barrel_mcp_client:list_resources(Client1),

%% Resources list:
%% [
%%     #{
%%         <<"uri">> => <<"file:///config">>,
%%         <<"name">> => <<"Configuration">>,
%%         <<"mimeType">> => <<"application/json">>
%%     },
%%     ...
%% ]
```

### Read a Resource

```erlang
{ok, Content, Client3} = barrel_mcp_client:read_resource(Client2, <<"file:///config">>),

%% Content structure:
%% #{
%%     <<"contents">> => [
%%         #{
%%             <<"uri">> => <<"file:///config">>,
%%             <<"text">> => <<"{\"key\": \"value\"}">>
%%         }
%%     ]
%% }
```

## Working with Prompts

### List Prompts

```erlang
{ok, Prompts, Client2} = barrel_mcp_client:list_prompts(Client1),

%% Prompts list:
%% [
%%     #{
%%         <<"name">> => <<"summarize">>,
%%         <<"description">> => <<"Summarize content">>,
%%         <<"arguments">> => [
%%             #{<<"name">> => <<"content">>, <<"required">> => true}
%%         ]
%%     },
%%     ...
%% ]
```

### Get a Prompt

```erlang
{ok, PromptResult, Client3} = barrel_mcp_client:get_prompt(Client2, <<"summarize">>, #{
    <<"content">> => <<"Long text to summarize...">>
}),

%% PromptResult contains messages:
%% #{
%%     <<"messages">> => [
%%         #{
%%             <<"role">> => <<"user">>,
%%             <<"content">> => #{
%%                 <<"type">> => <<"text">>,
%%                 <<"text">> => <<"Please summarize...">>
%%             }
%%         }
%%     ]
%% }
```

## Connection Management

### Closing Connections

Always close connections when done:

```erlang
ok = barrel_mcp_client:close(Client).
```

### Connection State

The client maintains state that must be threaded through calls:

```erlang
%% Pattern: Always use the returned client for subsequent calls
{ok, Client1} = barrel_mcp_client:connect(Opts),
{ok, _, Client2} = barrel_mcp_client:initialize(Client1),
{ok, Tools, Client3} = barrel_mcp_client:list_tools(Client2),
{ok, Result, Client4} = barrel_mcp_client:call_tool(Client3, <<"tool">>, #{}),
ok = barrel_mcp_client:close(Client4).
```

### Using with gen_server

```erlang
-module(my_mcp_worker).
-behaviour(gen_server).

-export([start_link/1, call_tool/2]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

call_tool(Pid, {ToolName, Args}) ->
    gen_server:call(Pid, {call_tool, ToolName, Args}).

init(Opts) ->
    {ok, Client} = barrel_mcp_client:connect(Opts),
    {ok, _, Client1} = barrel_mcp_client:initialize(Client),
    {ok, #{client => Client1}}.

handle_call({call_tool, Name, Args}, _From, #{client := Client} = State) ->
    case barrel_mcp_client:call_tool(Client, Name, Args) of
        {ok, Result, NewClient} ->
            {reply, {ok, Result}, State#{client := NewClient}};
        {error, Reason, NewClient} ->
            {reply, {error, Reason}, State#{client := NewClient}}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #{client := Client}) ->
    barrel_mcp_client:close(Client),
    ok.
```

## Authentication

### Bearer Token

```erlang
{ok, Client} = barrel_mcp_client:connect(#{
    transport => {http, <<"https://api.example.com/mcp">>},
    headers => #{
        <<"Authorization">> => <<"Bearer eyJhbGciOiJIUzI1NiIs...">>
    }
}).
```

### API Key

```erlang
{ok, Client} = barrel_mcp_client:connect(#{
    transport => {http, <<"https://api.example.com/mcp">>},
    headers => #{
        <<"X-API-Key">> => <<"your-api-key">>
    }
}).
```

### Basic Auth

```erlang
Credentials = base64:encode(<<"user:password">>),
{ok, Client} = barrel_mcp_client:connect(#{
    transport => {http, <<"https://api.example.com/mcp">>},
    headers => #{
        <<"Authorization">> => <<"Basic ", Credentials/binary>>
    }
}).
```

## Error Handling

Common errors and how to handle them:

```erlang
case barrel_mcp_client:call_tool(Client, Name, Args) of
    {ok, Result, NewClient} ->
        {ok, Result, NewClient};

    {error, {http_error, 401}, NewClient} ->
        %% Authentication failed - refresh token and retry
        NewHeaders = refresh_auth_token(),
        retry_with_new_auth(NewClient, NewHeaders);

    {error, {http_error, 404}, NewClient} ->
        %% Endpoint not found
        {error, server_not_found, NewClient};

    {error, {http_error, 500}, NewClient} ->
        %% Server error - maybe retry
        {error, server_error, NewClient};

    {error, timeout, NewClient} ->
        %% Request timed out
        {error, timeout, NewClient};

    {error, {method_not_found, _}, NewClient} ->
        %% Tool/resource/prompt doesn't exist
        {error, not_found, NewClient};

    {error, Reason, NewClient} ->
        %% Other errors
        logger:error("MCP client error: ~p", [Reason]),
        {error, Reason, NewClient}
end.
```

## Best Practices

1. **Always thread client state** - Each operation returns an updated client
2. **Close connections** - Use `close/1` or handle in `terminate/2`
3. **Handle errors** - MCP servers may be unavailable or return errors
4. **Set appropriate timeouts** - Especially for slow operations
5. **Cache tool/resource lists** - Don't fetch on every call if they don't change
