# Custom Authentication

barrel_mcp provides a simplified way to integrate custom authentication systems via `barrel_mcp_auth_custom`. This is useful when you have an existing key management system and want to use it for MCP HTTP authentication.

## Simple Interface

Instead of implementing the full `barrel_mcp_auth` behaviour (with `init/1`, `authenticate/2`, and `challenge/2`), you only need two functions:

```erlang
-module(my_auth).
-export([init/1, authenticate/2]).

%% Initialize authentication state
-spec init(Opts :: map()) -> {ok, State :: term()}.
init(_Opts) ->
    {ok, #{}}.

%% Authenticate a token
-spec authenticate(Token :: binary(), State :: term()) ->
    {ok, AuthInfo :: map(), NewState :: term()} |
    {error, Reason :: term(), NewState :: term()}.
authenticate(Token, State) ->
    case my_key_store:validate(Token) of
        {ok, KeyInfo} ->
            AuthInfo = #{
                subject => maps:get(user_id, KeyInfo),
                scopes => maps:get(permissions, KeyInfo, [])
            },
            {ok, AuthInfo, State};
        error ->
            {error, invalid_token, State}
    end.
```

## Usage

Configure the HTTP server to use your custom auth module:

```erlang
barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_custom,
        provider_opts => #{
            module => my_auth,
            module_opts => #{} % passed to my_auth:init/1
        }
    }
}).
```

## Token Extraction

`barrel_mcp_auth_custom` automatically extracts tokens from HTTP requests. It checks (in order):

1. `Authorization: Bearer <token>` header
2. `X-API-Key: <token>` header

The extracted token is passed to your `authenticate/2` function.

## AuthInfo Format

Your `authenticate/2` function should return a map with:

| Key | Type | Description |
|-----|------|-------------|
| `subject` | binary | User/client identifier |
| `scopes` | [binary] | List of permission scopes |

Additional keys are preserved in the `claims` field.

## Example: barrel_memory Integration

Here's how barrel_memory uses custom auth with its existing key system:

```erlang
-module(barrel_memory_mcp_auth).
-export([init/1, authenticate/2]).

init(Opts) ->
    {ok, Opts}.

authenticate(Token, State) ->
    case barrel_memory_api_keys:validate_key(Token) of
        {ok, KeyInfo} ->
            AuthInfo = #{
                subject => maps:get(team_id, KeyInfo, <<"unknown">>),
                scopes => maps:get(permissions, KeyInfo, [])
            },
            {ok, AuthInfo, State};
        {error, invalid_key} ->
            {error, invalid_token, State}
    end.
```

Configuration in barrel_memory:

```erlang
barrel_mcp:start_http(#{
    port => 9091,
    auth => #{
        provider => barrel_mcp_auth_custom,
        provider_opts => #{
            module => barrel_memory_mcp_auth
        }
    }
}).
```

## Claude Code Configuration

Once your MCP server is running with custom auth, add it to Claude Code:

```bash
# With Bearer token
claude mcp add my-server --transport http http://localhost:9090/mcp \
  --header "Authorization: Bearer your-api-key"

# Or with X-API-Key header
claude mcp add my-server --transport http http://localhost:9090/mcp \
  --header "X-API-Key: your-api-key"
```

## Error Handling

When authentication fails, `barrel_mcp_auth_custom` returns a 401 response with:

```
WWW-Authenticate: Bearer realm="mcp"
```

Your `authenticate/2` can return any error reason - it will be logged but not exposed to clients.
