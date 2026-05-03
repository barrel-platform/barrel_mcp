# Pending features

Design notes and scope sketches for features that are **not yet
implemented** and likely worth doing. Each entry is sized to be
picked up as one focused PR. Intent: someone landing here can
estimate effort and pick up the work without re-deriving the
spec context.

If you want one of these prioritised, open an issue.

---

## Enterprise-Managed Authorization (MCP `ext-auth` extension)

> **Status:** not implemented.
> **Spec:** [`modelcontextprotocol/ext-auth` —
> `enterprise-managed-authorization`][ema-spec].
> **Companion already shipped:** OAuth Client Credentials grant
> (`auth => {oauth_client_credentials, Config}`).

### Why

Enterprise deployments where every MCP client (and every other
internal tool) trusts the org's central Identity Provider, and a
user's existing SSO session should grant access to MCP servers
**without** a fresh OAuth dance per server. The flow chains an
ID Token from the IdP through an RFC 8693 token-exchange and an
RFC 7523 JWT-bearer access-token request to land on a
short-lived MCP access token.

For agent hosts running unattended, the existing Client
Credentials grant already covers the M2M case. EMA only matters
when there's a real user behind the agent and the host wants
their identity to flow through to the MCP server.

### Wire flow (verbatim from the spec)

1. **User authenticates at IdP** via OIDC or SAML (host
   responsibility — the library does not drive a browser).
   Output: an ID Token (`urn:ietf:params:oauth:token-type:id_token`)
   or SAML assertion (`urn:ietf:params:oauth:token-type:saml2`).

2. **Token exchange at IdP**'s token endpoint
   ([RFC 8693][rfc8693]):

   - `grant_type` = `urn:ietf:params:oauth:grant-type:token-exchange`
   - `requested_token_type` = `urn:ietf:params:oauth:token-type:id-jag`
   - `audience` = AS issuer URL (the MCP server's authorization
     server)
   - `resource` = MCP server's RFC 9728 resource identifier
   - `subject_token` = ID Token / SAML assertion from step 1
   - `subject_token_type` = matches the input token type

   Returns an Identity Assertion JWT (the "ID-JAG"). The JWT
   header `typ` MUST be `oauth-id-jag+jwt`. Required claims:
   `iss`, `sub`, `aud`, `resource`, `client_id`, `jti`, `exp`,
   `iat`.

3. **Access-token request at AS**'s token endpoint
   ([RFC 7523][rfc7523]):

   - `grant_type` = `urn:ietf:params:oauth:grant-type:jwt-bearer`
   - `assertion` = ID-JAG from step 2

   The `aud` of the assertion MUST be the AS issuer URL.
   `client_id` of the assertion MUST match the authenticating
   client.

4. **Bearer token returned** — used like any OAuth access token
   on subsequent MCP requests.

### Library work

Most of the plumbing already exists from `client_credentials/2`
and the auth-code grant; EMA is a thin set of additions on top.

#### `barrel_mcp_client_auth_oauth`

Add two new exchangers:

```erlang
-spec token_exchange(IdpTokenEndpoint, Params) ->
    {ok, IdJagJwt :: binary()} | {error, term()} when
    Params :: #{
        client_id := binary(),
        client_secret => binary() | undefined,
        client_assertion => binary() | undefined,
        subject_token := binary(),
        subject_token_type := binary(),  %% id_token | saml2
        audience := binary(),            %% AS issuer URL
        resource := binary()             %% MCP server URL
    }.
%% Sends the RFC 8693 request, returns the ID-JAG (extracted
%% from `access_token' field of the response per RFC 8693).

-spec jwt_bearer(AsTokenEndpoint, Params) ->
    {ok, AccessTokenResponse :: map()} | {error, term()} when
    Params :: #{
        client_id := binary(),
        client_secret => binary() | undefined,
        assertion := binary(),           %% the ID-JAG
        scopes => [binary()],
        resource => binary()
    }.
%% Sends the RFC 7523 request, returns the standard token
%% response (`access_token`, `expires_in`, optional
%% `refresh_token`).
```

Both reuse `http_post_form/4` from the existing module. The
`Authorization` header for client authentication mirrors what
`client_credentials/2` does today: HTTP Basic when a
`client_secret` is supplied, body-only when only `client_id`,
`private_key_jwt` when a `client_assertion` is supplied.

#### A new `init/1` mode and connect-spec entry

```erlang
init(#{grant_type := enterprise_managed,
       idp_token_endpoint := IDP,
       as_token_endpoint := AS,
       client_id := CI,
       subject_token := ST,
       subject_token_type := STT,
       audience := Aud,
       resource := Res} = Cfg) ->
    case token_exchange(IDP, ...) of
        {ok, IDJAG} ->
            case jwt_bearer(AS, #{client_id => CI,
                                   client_secret => ...,
                                   assertion => IDJAG,
                                   resource => Res,
                                   scopes => maps:get(scopes, Cfg, undefined)}) of
                {ok, #{<<"access_token">> := AT} = R} ->
                    {ok, #h{
                        access_token = AT,
                        ...,
                        mode = enterprise_managed,
                        idp_token_endpoint = IDP,
                        as_token_endpoint = AS,
                        subject_token = ST,
                        subject_token_type = STT,
                        audience = Aud,
                        resource = Res
                    }};
                ...
            end;
        ...
    end.
```

`refresh/2` in `enterprise_managed` mode re-walks the chain
(token-exchange + jwt-bearer) using the stored `subject_token`.
If the IdP returns `invalid_grant` (subject token expired), the
library surfaces `{error, subject_token_expired}` and the host
must re-acquire the ID Token from the IdP — that's a host
responsibility, the library doesn't drive browser flows.

#### `barrel_mcp_client_auth`

```erlang
new({oauth_enterprise, Config}) when is_map(Config) ->
    Cfg = Config#{grant_type => enterprise_managed},
    case barrel_mcp_client_auth_oauth:init(Cfg) of
        {ok, H} -> {barrel_mcp_client_auth_oauth, H};
        Err -> Err
    end;
```

Plus type-spec update on `barrel_mcp_client:connect_spec()`.

#### Tests

Mirror the existing `barrel_mcp_client_auth_oauth_tests`
pattern — extend the cowboy mock to handle two endpoints (IdP
token-exchange + AS jwt-bearer):

1. `token_exchange/2` happy path: assert grant_type,
   `requested_token_type`, `subject_token`, response JWT
   captured.
2. `jwt_bearer/2` happy path: assert the `assertion` parameter
   carries the ID-JAG, response yields a Bearer token.
3. End-to-end via `{oauth_enterprise, Config}` connect-spec
   entry. Header surfaces the access_token. 401 triggers a
   re-walk and a new access_token.
4. `subject_token_expired` path: IdP returns
   `invalid_grant` → `refresh/2` returns the typed error.

### Out-of-band concerns

- **JWT validation** of the ID-JAG is the AS's job, not the
  client's. We don't need to verify or sign anything.
- **IdP discovery** is out of scope: the spec assumes the host
  knows the IdP token endpoint up front (it's enterprise
  config, not a per-server discovery). RFC 9728 PRM only points
  at the AS, not the IdP.
- **SAML flows** (`subject_token_type:saml2`) reuse the same
  RFC 8693 wire shape. The library treats `subject_token` as
  opaque — both OIDC and SAML modes hit the same code path.

### Estimated size

~300 LOC across `barrel_mcp_client_auth_oauth.erl`,
`barrel_mcp_client_auth.erl`, and the connect-spec type, plus
~150 LOC of tests. Reuses existing `http_post_form/4`,
`urlencode/1`, `add_optional/3`, and the cowboy mock pattern in
the existing eunit suite.

[ema-spec]: https://github.com/modelcontextprotocol/ext-auth/blob/main/specification/draft/enterprise-managed-authorization.mdx
[rfc8693]: https://datatracker.ietf.org/doc/html/rfc8693
[rfc7523]: https://datatracker.ietf.org/doc/html/rfc7523
