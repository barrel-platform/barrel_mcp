# Authentication

barrel_mcp provides a pluggable authentication system following OAuth 2.1 patterns
as recommended by the MCP specification. Authentication is optional and configurable
per HTTP server instance.

## Overview

Authentication in barrel_mcp is handled by **providers** - modules implementing the
`barrel_mcp_auth` behaviour. The library includes several built-in providers:

| Provider | Use Case |
|----------|----------|
| `barrel_mcp_auth_none` | No authentication (default) |
| `barrel_mcp_auth_bearer` | JWT tokens or opaque Bearer tokens |
| `barrel_mcp_auth_apikey` | API key authentication |
| `barrel_mcp_auth_basic` | HTTP Basic authentication |

## Bearer Token Authentication

The most common pattern for MCP servers, supporting both JWT and opaque tokens.

### JWT with HS256

```erlang
barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_bearer,
        provider_opts => #{
            %% HMAC secret for HS256 signature verification
            secret => <<"your-256-bit-secret-key-here">>,

            %% Optional: Validate issuer claim
            issuer => <<"https://auth.example.com">>,

            %% Optional: Validate audience claim
            audience => <<"https://api.example.com">>,

            %% Optional: Clock skew tolerance in seconds (default: 60)
            clock_skew => 120,

            %% Optional: Custom scope claim name (default: <<"scope">>)
            scope_claim => <<"permissions">>
        },
        %% Optional: Require specific scopes
        required_scopes => [<<"mcp:read">>, <<"mcp:write">>]
    }
}).
```

### JWT with RS256/ES256 (Custom Verifier)

For asymmetric algorithms, provide a custom verifier function:

```erlang
%% Using jose library for RS256
Verifier = fun(Token) ->
    try
        JWK = jose_jwk:from_pem_file("public_key.pem"),
        case jose_jwt:verify(JWK, Token) of
            {true, {jose_jwt, Claims}, _} -> {ok, Claims};
            {false, _, _} -> {error, invalid_token}
        end
    catch
        _:_ -> {error, invalid_token}
    end
end,

barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_bearer,
        provider_opts => #{verifier => Verifier}
    }
}).
```

### Opaque Tokens (Token Introspection)

For tokens that require server-side validation:

```erlang
Verifier = fun(Token) ->
    %% Call your auth server's introspection endpoint
    case httpc:request(post, {
        "https://auth.example.com/introspect",
        [{"Authorization", "Bearer " ++ SecretKey}],
        "application/x-www-form-urlencoded",
        "token=" ++ binary_to_list(Token)
    }, [], []) of
        {ok, {{_, 200, _}, _, Body}} ->
            Claims = jsx:decode(list_to_binary(Body), [return_maps]),
            case maps:get(<<"active">>, Claims, false) of
                true -> {ok, Claims};
                false -> {error, invalid_token}
            end;
        _ ->
            {error, invalid_token}
    end
end,

barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_bearer,
        provider_opts => #{verifier => Verifier}
    }
}).
```

## API Key Authentication

Simple and effective for server-to-server communication.

### Static Key Map

```erlang
barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            keys => #{
                <<"ak_prod_abc123">> => #{
                    subject => <<"service-a">>,
                    scopes => [<<"read">>, <<"write">>],
                    metadata => #{team => <<"platform">>}
                },
                <<"ak_prod_xyz789">> => #{
                    subject => <<"service-b">>,
                    scopes => [<<"read">>]
                }
            }
        }
    }
}).
```

### Hashed Keys (Recommended for Production)

Store hashed keys to protect against database leaks:

```erlang
%% Generate hashed keys (do this once, store the hash)
Hash1 = barrel_mcp_auth_apikey:hash_key(<<"ak_prod_abc123">>),
Hash2 = barrel_mcp_auth_apikey:hash_key(<<"ak_prod_xyz789">>),

barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            keys => #{
                Hash1 => #{subject => <<"service-a">>},
                Hash2 => #{subject => <<"service-b">>}
            },
            hash_keys => true  %% Enable hash comparison
        }
    }
}).
```

### Custom Header Name

```erlang
barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            header_name => <<"X-Service-Key">>,  %% Custom header
            keys => #{<<"my-key">> => #{subject => <<"service">>}}
        }
    }
}).
```

### Dynamic Key Validation

```erlang
Verifier = fun(ApiKey) ->
    case my_db:lookup_api_key(ApiKey) of
        {ok, #{user_id := UserId, scopes := Scopes}} ->
            {ok, #{subject => UserId, scopes => Scopes}};
        not_found ->
            {error, invalid_credentials}
    end
end,

barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{verifier => Verifier}
    }
}).
```

## Basic Authentication

HTTP Basic auth - simple but requires TLS in production.

### Static Credentials

```erlang
barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_basic,
        provider_opts => #{
            credentials => #{
                <<"admin">> => <<"secret123">>,
                <<"readonly">> => <<"viewer456">>
            },
            realm => <<"MCP Server">>
        }
    }
}).
```

### Hashed Passwords

```erlang
%% Hash passwords (store these, not plain text)
AdminHash = barrel_mcp_auth_basic:hash_password(<<"secret123">>),
UserHash = barrel_mcp_auth_basic:hash_password(<<"viewer456">>),

barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_basic,
        provider_opts => #{
            credentials => #{
                <<"admin">> => AdminHash,
                <<"readonly">> => UserHash
            },
            hash_passwords => true
        }
    }
}).
```

### With Scopes and Metadata

```erlang
barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_basic,
        provider_opts => #{
            credentials => #{
                <<"admin">> => #{
                    password => <<"secret123">>,
                    scopes => [<<"read">>, <<"write">>, <<"admin">>],
                    metadata => #{role => <<"administrator">>}
                }
            }
        }
    }
}).
```

## Custom Authentication Provider

Implement the `barrel_mcp_auth` behaviour for custom authentication:

```erlang
-module(my_oauth_provider).
-behaviour(barrel_mcp_auth).

-export([init/1, authenticate/2, challenge/2]).

%% Initialize provider state
init(Opts) ->
    ClientId = maps:get(client_id, Opts),
    ClientSecret = maps:get(client_secret, Opts),
    IntrospectUrl = maps:get(introspect_url, Opts),
    {ok, #{
        client_id => ClientId,
        client_secret => ClientSecret,
        introspect_url => IntrospectUrl
    }}.

%% Authenticate a request
authenticate(Request, State) ->
    Headers = maps:get(headers, Request, #{}),
    case barrel_mcp_auth:extract_bearer_token(Headers) of
        {ok, Token} ->
            introspect_token(Token, State);
        {error, no_token} ->
            {error, unauthorized}
    end.

%% Generate challenge response for failed auth
challenge(unauthorized, State) ->
    Realm = maps:get(realm, State, <<"mcp">>),
    {401, #{
        <<"www-authenticate">> => <<"Bearer realm=\"", Realm/binary, "\"">>
    }, <<"{\"error\":\"unauthorized\"}">>};
challenge(invalid_token, _State) ->
    {401, #{
        <<"www-authenticate">> => <<"Bearer error=\"invalid_token\"">>
    }, <<"{\"error\":\"invalid_token\"}">>};
challenge(insufficient_scope, _State) ->
    {403, #{
        <<"www-authenticate">> => <<"Bearer error=\"insufficient_scope\"">>
    }, <<"{\"error\":\"insufficient_scope\"}">>}.

%% Internal: Token introspection
introspect_token(Token, #{introspect_url := Url} = State) ->
    %% Your introspection logic here
    case call_introspection_endpoint(Token, Url, State) of
        {ok, #{<<"active">> := true} = Claims} ->
            {ok, #{
                subject => maps:get(<<"sub">>, Claims),
                scopes => parse_scopes(maps:get(<<"scope">>, Claims, <<>>)),
                claims => Claims
            }};
        _ ->
            {error, invalid_token}
    end.
```

## Accessing Auth Info in Handlers

After successful authentication, auth info is available in the request:

```erlang
my_tool_handler(Args) ->
    case maps:get(<<"_auth">>, Args, undefined) of
        undefined ->
            %% No auth (using barrel_mcp_auth_none)
            do_something_anonymous();
        #{subject := Subject, scopes := Scopes} = AuthInfo ->
            %% Authenticated request
            case lists:member(<<"admin">>, Scopes) of
                true -> do_admin_action(Subject);
                false -> do_user_action(Subject)
            end
    end.
```

## Error Responses

Authentication failures return proper HTTP status codes and WWW-Authenticate headers:

| Error | Status | Description |
|-------|--------|-------------|
| `unauthorized` | 401 | No credentials provided |
| `invalid_token` | 401 | Token is malformed or signature invalid |
| `expired_token` | 401 | Token has expired |
| `invalid_credentials` | 401 | Wrong username/password or API key |
| `insufficient_scope` | 403 | Token lacks required scopes |

## Security Best Practices

1. **Always use TLS** in production
2. **Hash stored credentials** using the provided hash functions
3. **Use short-lived tokens** with refresh capability
4. **Validate audience claims** to prevent token misuse
5. **Implement rate limiting** at the transport layer
6. **Log authentication failures** for security monitoring
