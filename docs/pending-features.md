# Pending features

Design notes and scope sketches for features that are **not yet
implemented** and likely worth doing. Each entry is sized to be
picked up as one focused PR. Intent: someone landing here can
estimate effort and pick up the work without re-deriving the
spec context.

If you want one of these prioritised, open an issue.

---

## Dynamic Client Registration (RFC 7591)

> **Status:** not implemented.
> **Spec:** [RFC 7591][rfc7591].

Hosts that don't have a pre-issued `client_id` for the target
authorization server can register one programmatically. Common
when distributing an MCP host (each user instance gets its own
client) or in lab / dev setups against a fresh AS. The AS
metadata document advertises the endpoint via
`registration_endpoint`.

### Library work

A single new exchanger:

```erlang
-spec register_client(RegistrationEndpoint :: binary(),
                       Metadata :: map()) ->
    {ok, ClientInfo :: map()} | {error, term()}.
```

`Metadata` is the RFC 7591 client metadata map (`redirect_uris`,
`client_name`, `grant_types`, `response_types`, `scope`,
`token_endpoint_auth_method`, …). The response — `client_id`,
optional `client_secret`, `client_id_issued_at`,
`client_secret_expires_at`, plus any echoed metadata — flows
back to the caller verbatim. The host then feeds the returned
`client_id` (and `client_secret`, if any) into a subsequent
`{oauth, ...}` / `{oauth_client_credentials, ...}` /
`{oauth_enterprise, ...}` connect spec.

This stays a **standalone exchanger** — not auto-wired into
`init/1`. Auto-registration on first connect would need the
library to persist credentials somewhere (file? ETS?), which
is host policy.

### Tests

Extend the existing cowboy mock in
`test/barrel_mcp_client_auth_oauth_tests.erl` with a
`/oauth/register` route. Cases:

1. AS returns just `client_id`; function returns the response
   map verbatim.
2. AS issues both `client_id` and `client_secret`.
3. 4xx error path returns `{error, {http_error, 4xx, Body}}`.

### Estimated size

~80 LOC + ~50 LOC of tests.

[rfc7591]: https://datatracker.ietf.org/doc/html/rfc7591
