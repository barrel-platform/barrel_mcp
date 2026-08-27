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

The recommended format is a peppered HMAC-SHA-256 digest. The
`pepper` is a server-side secret mixed into the hash so a leak of
the stored hash table on its own isn't enough to forge keys.

```erlang
Pepper = <<"random-32-byte-pepper-loaded-from-env">>,
Hash1 = barrel_mcp_auth_apikey:hash_key(<<"ak_prod_abc123">>,
                                         #{pepper => Pepper}),
Hash2 = barrel_mcp_auth_apikey:hash_key(<<"ak_prod_xyz789">>,
                                         #{pepper => Pepper}),

barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_apikey,
        provider_opts => #{
            keys => #{
                Hash1 => #{subject => <<"service-a">>},
                Hash2 => #{subject => <<"service-b">>}
            },
            hash_keys => true,
            pepper => Pepper
        }
    }
}).
```

Stored values look like
`<<"hmac-sha256$<base64-encoded-hash>">>`.

For verification outside the auth pipeline (config tooling,
tests), use `barrel_mcp_auth_apikey:verify_key/2` — it does a
constant-time comparison and accepts both the new format and
legacy unsalted hex SHA-256 digests for one release.

#### Migrating from legacy SHA-256

`hash_key/1` (no pepper) still produces the legacy hex SHA-256
format and is still accepted by the verifier. To migrate:

1. Generate a `pepper` and load it from a secret store.
2. Re-hash each existing key with `hash_key/2`.
3. Replace the entries in your `keys` map.
4. Drop the legacy entries.

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

`hash_password/1,2` defaults to **PBKDF2-SHA256** (100k
iterations, random 16-byte salt). Stored values look like
`<<"pbkdf2-sha256$<iters>$<base64(salt)>$<base64(hash)>">>`.

```erlang
%% Hash passwords once, store the resulting binary, use that in
%% the credentials map.
AdminHash = barrel_mcp_auth_basic:hash_password(<<"secret123">>),
UserHash  = barrel_mcp_auth_basic:hash_password(<<"viewer456">>),

barrel_mcp:start_http(#{
    port => 9090,
    auth => #{
        provider => barrel_mcp_auth_basic,
        provider_opts => #{
            credentials => #{
                <<"admin">>    => AdminHash,
                <<"readonly">> => UserHash
            },
            hash_passwords => true
        }
    }
}).
```

`hash_password/2` accepts an options map:

- `algorithm` — `pbkdf2-sha256` (default) or `sha256-hex` (legacy,
  for migration only).
- `iterations` — PBKDF2 iteration count (default 100000).

The verification path is the public `verify_password/2`. It
accepts the modern format and legacy hex SHA-256 digests for one
release; the legacy code path logs a deprecation warning on every
match.

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

## OAuth grant flows

`barrel_mcp_client` ships three grants plus a registration
pre-step. Pick by **who is in the loop and when**:

### Authorization Code + PKCE — interactive

For flows where a real user authorises the host. Browser
redirect, PKCE prevents code interception, refresh on 401.

```
User    Host                   AS                  MCP server
 │  click "connect"             │                       │
 │──►│ redirect + PKCE          │                       │
 │   │─────────────────────────►│                       │
 │   │ login + consent          │                       │
 │   │◄─────────────────────────│                       │
 │   │ exchange_code +          │                       │
 │   │ code_verifier            │                       │
 │   │─────────────────────────►│                       │
 │   │ access_token +           │                       │
 │   │ refresh_token            │                       │
 │   │◄─────────────────────────│                       │
 │   │ Bearer access_token                              │
 │   │──────────────────────────────────────────────────►│
 │   │       (on 401: refresh_token grant)              │
```

```erlang
auth => {oauth, #{
    access_token   => <<"...">>,            % required
    refresh_token  => <<"...">>,            % optional, enables refresh
    token_endpoint => <<"https://idp/oauth/token">>,
    client_id      => <<"...">>,
    client_secret  => <<"...">>,            % optional confidential client
    resource       => <<"https://mcp/...">>,
    scopes         => [<<"mcp.read">>, <<"mcp.write">>]
}}
```

The host drives the browser dance and feeds the resulting tokens
in. The library handles the refresh.

#### Validate the authorization response

Before you send the code to any token endpoint, check what came back
against what you recorded when you built the authorization URL:

```erlang
validate(Query, State, Issuer, AsMetadata) ->
    barrel_mcp_client_auth_oauth:validate_callback(Query, #{
        state => State,
        issuer => Issuer,
        as_metadata => AsMetadata
    }).
```

`state` ties the response to the request you started. `iss` (RFC 9207)
says which authorization server minted the code, and it is the only
thing that catches a code from one server being replayed at another's
endpoint, which a client talking to more than one otherwise cannot
detect.

| AS advertises `iss` | `iss` present | Result |
|---|---|---|
| yes | yes | compared |
| yes | no | rejected |
| no / unstated | yes | compared |
| no / unstated | no | accepted |

A present `iss` is compared whatever the metadata says, so a server that
emits it before advertising it still gets checked. An absent one is only
fatal when the server said it would send one, where its absence means
the parameter went missing rather than was never sent.

Comparison is exact. Do not case-fold, drop a default port, add or strip
a trailing slash, or decode percent-encoding first; each of those merges
two distinct issuers into one.

Validate error responses too. On a mismatch the `error`,
`error_description` and `error_uri` are not yours to act on or display,
since you cannot tell who wrote them.

### Client Credentials — unattended (M2M)

For agent hosts running without a human. The host already has
its own credentials.

```
Host                              AS                  MCP server
 │  POST /token                    │                       │
 │  grant=client_credentials       │                       │
 │  + Basic <client_id:secret>     │                       │
 │────────────────────────────────►│                       │
 │  access_token                   │                       │
 │◄────────────────────────────────│                       │
 │  Bearer access_token                                    │
 │────────────────────────────────────────────────────────►│
 │             (on 401: re-acquire via same grant)         │
```

```erlang
auth => {oauth_client_credentials, #{
    token_endpoint   => <<"https://idp/oauth/token">>,
    client_id        => <<"my-agent-host">>,
    client_secret    => <<"...">>,          % OR client_assertion (JWT)
    resource         => <<"https://mcp/...">>,
    scopes           => [<<"mcp.read">>]
}}
```

Eager fetch on init — a misconfigured client fails up front.
Re-acquires via the same grant on 401. No `refresh_token` is
involved.

### Enterprise-Managed Authorization — SSO chain

For SSO-driven hosts. The user already has a session at the org
IdP; their identity flows into a short-lived MCP access token
without re-prompting. Two-step chain (RFC 8693 → RFC 7523).

```
User    Host        IdP             AS                MCP server
 │  active SSO session              │                       │
 │  ID Token                        │                       │
 │ ─────────►│                      │                       │
 │           │ POST /token          │                       │
 │           │ grant=token-exchange │                       │
 │           │ subject_token=<id_token>                     │
 │           │ audience=<AS issuer> │                       │
 │           │ resource=<MCP url>   │                       │
 │           │─────────────────────►│                       │
 │           │ ID-JAG (signed JWT)  │                       │
 │           │◄─────────────────────│                       │
 │           │ POST /token          │                       │
 │           │ grant=jwt-bearer     │                       │
 │           │ assertion=<ID-JAG>   │                       │
 │           │─────────────────────►│                       │
 │           │  access_token        │                       │
 │           │◄─────────────────────│                       │
 │           │  Bearer access_token                         │
 │           │─────────────────────────────────────────────►│
 │           │ (on 401: re-walk the chain)                 │
 │           │ (id_token expires →                         │
 │           │  {error, subject_token_expired})            │
```

```erlang
auth => {oauth_enterprise, #{
    idp_token_endpoint => <<"https://idp/oauth/token">>,
    as_token_endpoint  => <<"https://as/oauth/token">>,
    client_id          => <<"...">>,
    client_secret      => <<"...">>,        % OR client_assertion
    subject_token      => <IdToken>,        % from IdP, opaque
    subject_token_type =>
        <<"urn:ietf:params:oauth:token-type:id_token">>, % or saml2
    audience           => <<"https://as">>,
    resource           => <<"https://mcp/...">>,
    scopes             => [<<"mcp.read">>]
}}
```

The library treats `subject_token` as opaque — both OIDC and
SAML modes hit the same code path. The browser flow at the IdP
stays a host concern.

### Dynamic Client Registration — pre-step

Not a grant. One of three ways to get a `client_id` before any of the
others; see [Client registration](#client-registration) for choosing
between them. RFC 7591, and now deprecated in favour of Client ID
Metadata Documents.

```
Host                                    AS
 │  POST /register                       │
 │  { client_name, redirect_uris,        │
 │    grant_types, ... }                 │
 │──────────────────────────────────────►│
 │  { client_id, client_secret?,         │
 │    client_id_issued_at, ... }         │
 │◄──────────────────────────────────────│
```

```erlang
{ok, Info} = barrel_mcp_client_auth_oauth:register_client(
    <<"https://idp/oauth/register">>,
    #{<<"client_name">> => <<"my-host">>, ...}),
ClientId     = maps:get(<<"client_id">>, Info),
ClientSecret = maps:get(<<"client_secret">>, Info, undefined).
```

For protected registration endpoints (RFC 7591 section 3) pass
the AS-issued initial access token via `register_client/3`:

```erlang
{ok, Info} = barrel_mcp_client_auth_oauth:register_client(
    <<"https://idp/oauth/register">>,
    #{<<"client_name">> => <<"my-host">>, ...},
    #{initial_access_token => <<"...">>}).
```

Feed the returned credentials into one of the grants above. The
library does not persist them; that's a host concern.

`application_type` is always sent, inferred from `redirect_uris` unless
you set one. Omitting it defaults to `web` under OIDC, which rejects the
loopback URIs a local client needs, and the registration error rarely
explains why. Loopback or non-https redirects infer `native`; remote
https infers `web`.

Registration can still be refused over redirect-URI rules. Surface that
to the user or developer rather than swallowing it; retrying with a
different `application_type` or a conforming redirect URI is reasonable,
guessing repeatedly is not.

## Client registration

A client needs a `client_id` before it can start any flow. There are
three ways to have one, and the choice is not free-form:

```erlang
choose(AsMetadata) ->
    barrel_mcp_client_auth_oauth:registration_strategy(AsMetadata, #{
        client_id              => <<"pre-registered-if-you-have-one">>,
        client_id_metadata_url => <<"https://app.example/oauth/client.json">>
    }).
```

Returns, in the specification's priority order:

| Result | When | Why it ranks there |
|---|---|---|
| `{pre_registered, ClientId}` | you already have one | it names a relationship that exists; nothing discovered improves on it |
| `{client_id_metadata_document, Url}` | the AS advertises `client_id_metadata_document_supported` and you host a document | no credential to store, and none to go stale |
| `{dynamic_registration, Endpoint}` | the AS has a `registration_endpoint` | deprecated; the only branch that mints a credential you must then keep |
| `prompt_user` | none of the above | a client cannot invent an identity |

### Client ID Metadata Documents

With CIMD the `client_id` **is** an HTTPS URL, and the authorization
server fetches your metadata from it at authorization time. That removes
the registration round trip and the per-server credential with it: the
same URL works at every authorization server, because whoever needs the
metadata reads it.

Build the document and serve it at exactly that URL:

```erlang
document() ->
    barrel_mcp_client_auth_oauth:client_id_metadata_document(#{
        <<"client_id">> => <<"https://app.example/oauth/client.json">>,
        <<"client_name">> => <<"Example MCP Client">>,
        <<"redirect_uris">> => [<<"http://127.0.0.1:3000/callback">>]
    }).
```

`client_id`, `client_name` and `redirect_uris` are required.
`grant_types`, `response_types` and `token_endpoint_auth_method` default
to the public-client-with-PKCE shape; set them yourself for anything
else, including adding `refresh_token` to `grant_types` if you want
refresh tokens.

The `client_id` must be https and carry a path. A bare origin is not an
identity, and the value in the document must equal the URL you serve it
from, because servers compare the two and reject a document naming a
different client than the one they fetched.

### Binding credentials to an authorization server

A `client_id` from pre-registration or dynamic registration belongs to
the server that issued it. The authorization server can change under a
client at any time, since it comes from the resource's metadata and that
is refetched, so check before reusing anything you stored:

```erlang
check(Stored, Issuer) ->
    barrel_mcp_client_auth_oauth:check_issuer_binding(Stored, Issuer).
```

`ok`, `{error, unbound_credentials}` if what you stored never recorded
where it came from, or `{error, {issuer_changed, Was, Now}}`. Re-register
against the new server rather than trying the old credentials there:
sending them hands a client identity to a party never given it, and
fails in a way that reads like a bad token.

A CIMD `client_id` passes against any issuer. It is a URL the server
resolves for itself, so it was never bound to one and needs no
re-registration when the server changes.

### Where they overlap on the wire

All grants hit the same OAuth-server token endpoint with
`application/x-www-form-urlencoded` bodies. Confidential clients
authenticate with HTTP Basic; `private_key_jwt` clients pass a
`client_assertion` instead. RFC 8707 `resource` is attached on
every grant. The MCP auth sub-spec layers
[RFC 9728 PRM](#oauth-protected-resource-metadata-rfc-9728) on
top so any of the grants can be auto-discovered from a `401`
response.

### When to pick which

| Situation | Use |
|---|---|
| Real user, browser available, host wants their identity | `auth_code` (`{oauth, ...}`) |
| Background agent / cron / unattended host | `client_credentials` (`{oauth_client_credentials, ...}`) |
| Enterprise SSO; user identity must flow to MCP | `enterprise_managed` (`{oauth_enterprise, ...}`) |
| No `client_id` yet | [Client registration](#client-registration) first, then one of the above |

## OAuth Protected Resource Metadata (RFC 9728)

For OAuth-protected deployments, MCP clients auto-discover the
authorization server by:

1. Hitting any endpoint and receiving a 401 with
   `WWW-Authenticate: Bearer ... resource_metadata="<URL>"`.
2. Following the URL to fetch the
   [RFC 9728](https://datatracker.ietf.org/doc/html/rfc9728)
   Protected Resource Metadata document.
3. Reading `authorization_servers` from the document and
   completing the OAuth dance against one of them.

The server side of this loop is opt-in via a `resource_metadata`
option on `barrel_mcp:start_http_stream/1` (and
`start_http/1`):

```erlang
{ok, _} = barrel_mcp:start_http_stream(#{
    port => 8080,
    auth => #{provider => barrel_mcp_auth_bearer,
              provider_opts => #{secret => Secret}},
    resource_metadata => #{
        resource              => <<"http://localhost:8080/mcp">>,
        authorization_servers => [<<"https://idp.example.com">>]
    }
}).
```

When set:

- `/.well-known/oauth-protected-resource` is served by the HTTP
  transport as a JSON metadata document.
- The bearer challenge on 401 emits
  `resource_metadata="<absolute PRM URL>"`. The PRM URL is
  derived from `resource` by default; pass
  `metadata_url => <<"https://...">>` in the option map to
  override.

The audience-claim string in `state.resource` (used for token
verification by `barrel_mcp_auth_bearer`) is unaffected; only
the wire emission of `WWW-Authenticate` changed.

The client side is implemented by
`barrel_mcp_client_auth_oauth:parse_www_authenticate/1` and
`discover_protected_resource/1` — together with the server side
above, the MCP authorization sub-spec discovery flow works
end-to-end.

## Dynamic Client Registration (RFC 7591)

Hosts that don't have a pre-issued `client_id` for the target
authorization server can register one programmatically. The AS
metadata document advertises the endpoint via
`registration_endpoint`.

```erlang
{ok, Info} = barrel_mcp_client_auth_oauth:register_client(
    <<"https://idp.example.com/oauth/register">>,
    #{<<"client_name">>   => <<"my-mcp-host">>,
      <<"redirect_uris">> => [<<"http://localhost:5173/callback">>],
      <<"grant_types">>   => [<<"authorization_code">>,
                              <<"refresh_token">>],
      <<"response_types">> => [<<"code">>],
      <<"token_endpoint_auth_method">> => <<"none">>}).

%% Info now contains:
%%   #{<<"client_id">>           => <<"...">>,
%%     <<"client_secret">>       => <<"...">>,   % if confidential
%%     <<"client_id_issued_at">> => 1700000000,  % UNIX epoch
%%     ...}
```

Feed the returned credentials into a subsequent
`{oauth, ...}` / `{oauth_client_credentials, ...}` connect spec.
This stays a standalone exchanger — the library doesn't persist
the issued credentials. That's a host concern (file, DB, secret
manager).

## Security Best Practices

1. **Always use TLS** in production
2. **Hash stored credentials** using the provided hash functions
3. **Use short-lived tokens** with refresh capability
4. **Validate audience claims** to prevent token misuse
5. **Implement rate limiting** at the transport layer
6. **Log authentication failures** for security monitoring
