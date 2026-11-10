# Agents

Instructions for AI coding agents working on barrel_mcp. Read this file
before you change anything; it applies to every agent and every change.

## Project Overview

barrel_mcp is an Erlang library implementing the Model Context
Protocol (MCP) for both server and client modes. It speaks every
released revision from `2024-11-05` through `2026-07-28` on one
endpoint: the legacy handshake era (`initialize`, sessions) and the
stateless era, chosen per request (see `guides/protocol-versions.md`).
It serves the Streamable HTTP and stdio transports for Claude Code and
any other MCP client. One OTP application; `src/` is flat and every module is
prefixed `barrel_mcp_`:

```
src/    Server: barrel_mcp (public facade), barrel_mcp_registry
        (tools/resources/prompts), barrel_mcp_protocol (JSON-RPC
        wire), barrel_mcp_session, barrel_mcp_http / _http_stream /
        _http_engine / _http_listener (h1/h2 server), barrel_mcp_stdio,
        barrel_mcp_auth + barrel_mcp_auth_* (bearer/apikey/basic/
        custom/none), barrel_mcp_schema, barrel_mcp_pagination,
        barrel_mcp_tasks, barrel_mcp_tool_format, barrel_mcp_uri_template
        Client: barrel_mcp_client + _clients / _client_sup,
        barrel_mcp_client_http / _client_stdio (transports),
        barrel_mcp_client_transport, barrel_mcp_client_handler(+_default),
        barrel_mcp_client_auth + _client_auth_bearer / _client_auth_oauth
include/    Shared records
test/       EUnit + Common Test (OAuth DCR/enterprise suites, snippet
            checks, python interop). The h1-based mock auth server is
            test/barrel_mcp_test_http.erl.
guides/     ex_doc guides (getting-started, transports, auth, ...)
docs/       Pending-features notes and design docs
examples/   Runnable example apps
```

The HTTP server is built on the sibling hex libraries `h1` and `h2`
(HTTP/1.1 + HTTP/2 on one port via ALPN) plus `hackney` for the
client; there is no Cowboy dependency. Do not reimplement HTTP/1,
HTTP/2, or HPACK logic here; that lives in the wire libs.

Authoritative behaviour is the test suites under `test/` and the
module docs.

## First principle: compliance, latest spec, safety

barrel_mcp faces untrusted peers on both sides: a server answers any
client that reaches its port, and a client talks to servers and
authorization servers it does not control. Every change that touches
how JSON-RPC messages, MCP methods, results, errors, `_meta`,
capabilities, protocol versions, HTTP headers, SSE events, stdio
frames, OAuth requests and responses or JWTs are read, parsed or
written, or how a session, request, subscription, task or token
changes state, must pass three checks before it is called done,
committed or opened as a pull request:

1. **Compliance**: the behaviour matches the governing spec section
   for the revision it applies to, and a test shows the accept and the
   reject path. The test fails on main without the change.
2. **Latest specification**: you checked that the spec you cite is the
   current one (no newer MCP revision, extension release, RFC update or
   draft revision that changes the rule), and you read the section
   itself instead of quoting from memory or from an SDK.
3. **Safety**: the change does not open a known abuse class (resource
   exhaustion, flood, session hijack, cross-session leak, token
   confusion) and every per-peer resource it touches stays bounded.

Use the [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md)
skill to run them. When in doubt whether a change is protocol code, it
is.

## Specification issues are bugs, not security issues

A report is a specification issue when the fix is to make barrel_mcp
do what a spec it implements says (see
[Specifications](#specifications)):

- input accepted, rejected or framed differently from the spec
  (JSON-RPC envelopes, batches, ids, method params, results, `_meta`,
  capabilities, Streamable HTTP and SSE framing, stdio framing, JSON
  Schema validation, URI templates, pagination cursors);
- a wrong error code or HTTP status, a wrong protocol version
  negotiated or accepted, a method served in a revision that does not
  have it, or a state transition the spec does not allow (session,
  request, cancellation, subscription, task);
- an OAuth or discovery flow that does not follow RFC 9728, RFC 8414,
  RFC 7591, RFC 7636, RFC 8707 or the MCP authorization section, where
  the result is a failed or wrong flow rather than a peer or token
  accepted that should not be;
- a missing or wrong bound that the spec or an option defines (message
  and body size, SSE replay buffer, pending requests, subscriptions,
  tasks and their TTL, page size, schema depth).

This holds even when the report calls it denial of service, memory
exhaustion or a remote crash. Treat it as a bug:

- fix it in a public pull request, with a public issue if one is
  needed;
- list it under **Fixed** in the CHANGELOG, in plain English, citing
  the spec section;
- do not open a GitHub Security Advisory, request a CVE, embargo the
  fix, give it a severity, or describe how to attack it;
- when it arrived as an advisory, close the advisory as not a
  vulnerability and link the pull request that fixes it.

Only a problem that is not a spec deviation goes through
[SECURITY.md](SECURITY.md):

- code execution, including a wire value reaching a module or function
  call, or creating atoms;
- a request served without the authentication or authorization the
  configuration asks for: a server auth provider (`bearer`, `apikey`,
  `basic`, `custom`) bypassed, a token accepted for another audience or
  resource, `visible/4` or `authorize_subscribe/3` skipped, a task or
  session reachable by an identity that did not create it, a request
  accepted from an `Origin` the configuration rejects;
- one session's or identity's data (results, notifications, SSE
  replay, task results, elicitation answers) reaching another;
- credentials, tokens, API keys or the `request_state_key` leaking
  into logs or error bodies, or a client sending a token to a server or
  authorization server it was not issued for;
- forged or replayed request state (MRTR) being accepted;
- barrel_mcp weakening TLS below what the configuration allows.

Authentication, authorization, `Origin` checks and token audience stay
security issues even where a spec describes the check. If unsure, ask
the maintainer before treating anything as a security issue.

## Required Checks

Every change must be formatted and pass all checks before committing
or opening a PR:

```bash
rebar3 fmt          # Auto-format (always run first)
rebar3 compile      # Must compile cleanly (warnings_as_errors)
rebar3 lint         # Elvis linter
rebar3 xref         # Cross-reference analysis
rebar3 dialyzer     # Type checking
rebar3 eunit        # Unit tests
rebar3 ct           # Common Test (OAuth, snippet, suites)
```

CI (`.github/workflows/ci.yml`) runs `format`, `lint`, `xref`, and
`dialyzer` as distinct jobs alongside `tests`, all gated on
`compile`. It also runs the example apps and `make interop-test` (the
Python SDK suite and the official MCP conformance runner); see
[CONTRIBUTING.md](CONTRIBUTING.md) for those and the rest of the
workflow.

## Pull Requests

Work on one issue goes in one pull request. Give each change a
reviewer has to look at its own commit, with its tests, rather than
opening a pull request per change. Docs and CHANGELOG entries go in the
same pull request.

- Every bug fix and feature has a test. Show it failing on main.
- Never relax a limit or a check to make a peer pass; exclude the
  legitimate case precisely.
- A failing conformance or interop check is a defect to fix, never a
  baseline or expected-failure entry.
- Descriptions state what was wrong, the fix in a few lines, and
  breaking changes. Reference issues with `Fixes #N`. No test plan, no
  file-by-file walkthrough.
- No `Co-Authored-By`, "Generated with" or similar trailers, in commits
  or pull requests.
- CHANGELOG: plain English, what was wrong and what it means for the
  user, the spec section when there is one. No implementation details,
  no attack narratives.
- Follow "Write for the person who reads it" in
  [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it):
  plain English, no inflated or pseudo-technical wording, and a person
  has read the change before it is opened.

## Specifications

The specs barrel_mcp implements, at the version the code follows.
Where a newer one exists it is listed under
[Pending updates](#pending-updates). Last checked: 2026-11-10.

### MCP

| Spec | Scope in barrel_mcp | Code |
|---|---|---|
| MCP `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25` (legacy era) | `initialize` handshake, sessions, `Mcp-Session-Id`, server-to-client requests over SSE, `resources/subscribe`, core tasks (`2025-11-25`) | `barrel_mcp_protocol`, `barrel_mcp_session`, `barrel_mcp_version`, `barrel_mcp_tasks` |
| MCP `2026-07-28` (modern era) | stateless requests, `_meta` version and capabilities, `server/discover`, MRTR `inputRequests`, `subscriptions/listen` | `barrel_mcp_protocol`, `barrel_mcp_ctx`, `barrel_mcp_request_state`, `barrel_mcp_subscriptions` |
| MCP basic: JSON-RPC 2.0 messages, lifecycle, cancellation, progress, ping | envelopes, ids, error codes, `notifications/cancelled`, `notifications/progress` | `barrel_mcp_protocol` |
| MCP transports: Streamable HTTP, stdio | POST/GET/DELETE, SSE, `Last-Event-ID` replay, `MCP-Protocol-Version`, `Origin` validation, newline-delimited stdio | `barrel_mcp_http_engine`, `barrel_mcp_http_stream`, `barrel_mcp_headers`, `barrel_mcp_stdio`, `barrel_mcp_client_http`, `barrel_mcp_client_stdio` |
| MCP server features: tools, resources, prompts, completion, logging, pagination | registry, structured content, resource templates, list-changed | `barrel_mcp_registry`, `barrel_mcp_tool_format`, `barrel_mcp_pagination` |
| MCP client features: roots, sampling, elicitation | client handler callbacks, form and URL elicitation | `barrel_mcp_client_handler`, `barrel_mcp_elicitation` |
| MCP authorization (each revision's `basic/authorization`) | protected resource, client discovery and token flows | `barrel_mcp_auth_bearer`, `barrel_mcp_client_auth_oauth` |
| MCP tasks extension (`modelcontextprotocol/ext-tasks`, `specification/draft` at `e4345978`) | tasks for the modern era: create, poll, result, cancel, `input_required` | `barrel_mcp_tasks`, `barrel_mcp_task_store`, `barrel_mcp_task_provider`, `barrel_mcp_task_relay`, `barrel_mcp_client` |

SEPs the code cites (SEP-1699 SSE resumption, SEP-2207, SEP-2350) are
covered by the core revision that merged them; check that revision's
text, not the SEP.

### Data formats

| Spec | Scope | Code |
|---|---|---|
| RFC 8259 JSON | encode and decode (OTP `json`) | `barrel_mcp_protocol`, `barrel_mcp_headers` |
| JSON Schema 2020-12, draft-07 | tool input and output schema validation | `barrel_mcp_jsonschema`, `barrel_mcp_schema` |
| RFC 6901 JSON Pointer, RFC 3986 URI | `$ref` resolution, URI handling | `barrel_mcp_jsonschema`, `barrel_mcp_client_auth_oauth` |
| RFC 6570 URI Template | resource templates | `barrel_mcp_uri_template` |
| RFC 5424 syslog severities | MCP logging levels | `barrel_mcp_session` |
| WHATWG HTML server-sent events | SSE framing | `barrel_mcp_http_stream`, `barrel_mcp_client_http` |

### HTTP and authorization

| Spec | Scope | Code |
|---|---|---|
| RFC 9110 HTTP semantics | headers, status codes | `barrel_mcp_headers`, `barrel_mcp_http_engine` |
| RFC 9113 HTTP/2 (wire in `h2`), HTTP/1.1 (wire in `h1`) | ALPN on one port | `barrel_mcp_http_listener` |
| RFC 6749 OAuth 2.0 (with RFC 9700 security BCP), OAuth 2.1 draft | authorization code with PKCE, client credentials, refresh | `barrel_mcp_client_auth_oauth` |
| RFC 6750 bearer tokens, RFC 7617 Basic | server auth providers, client headers | `barrel_mcp_auth_bearer`, `barrel_mcp_auth_basic`, `barrel_mcp_client_auth_bearer` |
| RFC 9728 protected resource metadata | `WWW-Authenticate` challenge, metadata document, client discovery | `barrel_mcp_auth_bearer`, `barrel_mcp_http_engine`, `barrel_mcp_client_auth_oauth` |
| RFC 8414 AS metadata, RFC 9207 issuer identification | discovery, `iss` check on the redirect | `barrel_mcp_client_auth_oauth` |
| RFC 7591 dynamic client registration, draft-ietf-oauth-client-id-metadata-document-00 | client registration | `barrel_mcp_client_auth_oauth` |
| RFC 7636 PKCE (S256), RFC 8707 resource indicators | authorization request, token audience | `barrel_mcp_client_auth_oauth`, `barrel_mcp_auth_bearer` |
| RFC 7521, RFC 7523 JWT client auth and grants, RFC 8693 token exchange | `private_key_jwt`, enterprise ID-JAG chain | `barrel_mcp_client_auth_oauth`, `barrel_mcp_jwt` |
| RFC 9449 DPoP, RFC 7518 JWA, RFC 7638 JWK thumbprint | proofs, ES256/RS256/HS256 | `barrel_mcp_jwt` |

RFC 9864 (fully-specified JOSE algorithms) updates RFC 7518 and needs
no change: ES256, RS256 and HS256 are already fully specified.

### Keeping the specifications current

A spec changes under the code when MCP releases a new revision, the
tasks extension publishes a new text, an RFC is obsoleted or updated,
or a draft gets a new revision. Check the list:

- before every release;
- when you change a module listed in it, for the specs that module
  follows;
- when the conformance runner, the Python SDK or a major MCP client
  moves to a newer revision, since interop breaks first.

Answer compliance questions from the spec repository at a pinned
commit, not from SDK code or summaries: clone
https://github.com/modelcontextprotocol/modelcontextprotocol (revisions
under `docs/specification/<revision>/`, normative types in
`schema/<revision>/schema.ts`) and
https://github.com/modelcontextprotocol/ext-tasks. Check an RFC with
`curl -sL https://www.rfc-editor.org/rfc/rfcNNNN.json` (`obsoleted_by`,
`updated_by`) and its errata on https://www.rfc-editor.org/errata/rfcNNNN.
Check a draft's latest revision on
`https://datatracker.ietf.org/doc/draft-.../`. Then set "Last checked"
above.

When a newer version exists, it is its own piece of work, not a side
change:

1. Add it under [Pending updates](#pending-updates) with what is known
   to differ.
2. Diff the sections the code relies on, old version against new, and
   list every change: methods, params and result fields, capabilities,
   error codes, headers, MUST and SHOULD changes, removed features.
3. Decide per change: follow it now, or keep the old behaviour and say
   why. A new MCP revision is added next to the old ones, never in
   place of them: older revisions stay negotiable.
4. Make the change in one pull request, one commit per item, each with
   a test, run through the
   [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md)
   checks, and run `make interop-test` with the conformance runner at a
   version that knows the new revision.
5. Update the citations in the code it touches, the row in the tables
   above and the "Last checked" date, and remove it from Pending
   updates. Add a CHANGELOG entry when behaviour or the wire changes,
   saying which version is now followed.

A new RFC number that only renumbers the same text still updates the
citations and the table, with no CHANGELOG entry.

### Pending updates

Known newer versions, checked 2026-11-10. Each needs the diff in step 2
before any code changes.

| Spec | Code follows | Latest | To check |
|---|---|---|---|
| MCP tasks extension | `specification/draft` at `e4345978` | `specification/2026-07-28` (released, last changed 2026-10-09) | method, field and status changes between the draft the code follows and the released text |
| JWT client auth audience | RFC 7521, RFC 7523 | RFC 10070 (November 2026) | `aud` of the `private_key_jwt` assertion: `client_assertion/1` falls back to the token endpoint when the AS metadata has no `issuer` |
| Client ID metadata document | draft-ietf-oauth-client-id-metadata-document-00 | -03 | document fields, fetch and validation rules in `barrel_mcp_client_auth_oauth` |

The conformance runner is pinned at `0.2.0-alpha.11` in
`test/conformance/package.json`; `0.2.0-alpha.12` is out. Bump it in
its own pull request and treat any new failure as a defect.

## Skills

Task guides for agents live in `.agents/skills/<name>/SKILL.md`; read
the one that matches the task before starting. `.claude/skills` links
to the same directories, so there is one copy.

- [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md):
  the three checks above (compliance, latest spec, safety) for a
  change, a commit or a pull request.
- [spec-compliance](.agents/skills/spec-compliance/SKILL.md): check a
  change or pull request against the MCP revision, extension or RFC it
  claims to follow.

## Build & Development Commands

```bash
rebar3 compile                                # Build
rebar3 shell                                  # Boot a dev shell
rebar3 ct --suite=test/barrel_mcp_oauth_dcr_SUITE  # One suite
rebar3 fmt                                     # Auto-format (erlfmt)
rebar3 fmt --check                             # Format check, no writes
rebar3 lint                                    # Elvis linter
make interop-test                              # Python interop suite
```

## Architecture

### Registry

`barrel_mcp_registry` is the source of truth for registered tools,
resources, resource templates, and prompts. Tools register a module +
function; resources may carry RFC 6570 templates expanded at
`resources/read`.

### Server transports

`barrel_mcp_http_listener` runs a small acceptor pool on one port and
negotiates HTTP/1.1 or HTTP/2 via ALPN (`h1`/`h2`), handing each
request to `barrel_mcp_http_engine`. `barrel_mcp_http_stream`
implements the Streamable HTTP transport (SSE, `Last-Event-ID`
replay, `Origin` validation, default bind `127.0.0.1`).
`barrel_mcp_stdio` serves the framed stdio transport; its `io:format`
to stdout is the wire, not a debug call.

### Protocol

`barrel_mcp_protocol` is the JSON-RPC codec. camelCase atoms in that
module, `barrel_mcp_schema`, and `barrel_mcp_tool_format` are external
wire shapes (JSON-RPC / JSON-Schema keywords), not our naming.

### Tool handlers

Arity 1 or arity 2 (`(Args, Ctx)`). `Ctx` drives progress, cancel,
and `_meta` hooks. Return shapes: plain content, `{tool_error, ...}`
(`isError: true`), `{structured, Data, ...}` (`structuredContent`),
or the meta-bearing variants that attach `_meta`.

### Auth

Server auth providers (`barrel_mcp_auth_*`) and client auth handles
(`barrel_mcp_client_auth*`) are dispatched dynamically by design
(`Provider:init/verify`, the OAuth client walks discovery →
token/refresh → enterprise chains).

## Conventions

- Run `rebar3 fmt` before committing; elvis must pass. New per-module
  elvis ignores belong in `rebar.config` with a one-line reason.
- Commit messages: one imperative subject line, body only for
  non-obvious "why". No diff restatement, no "generated by" /
  "co-authored-by" trailers.
- Do not use the em-dash character in code, docs, or messages.
- The HTTP server stays on `h1`/`h2`; keep the adapters thin and push
  wire-level changes upstream.
- `rebar.lock` is committed: CI keys its build cache on the lock hash,
  so a stale or absent lock silently pins old dependency versions.
