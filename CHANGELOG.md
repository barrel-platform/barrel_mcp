# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.1.0] - 2026-05-28

Erlang/OTP 29 support. No public API changes.

### Changed

- Support OTP 29; CI now runs on OTP 28 and 29 (dropped 27) with rebar3 3.27.
- Replaced the deprecated bare `catch` operator with `try ... catch` throughout,
  as OTP 29 deprecates `catch ...`.
- Updated dependencies: `erlang_h1` 0.2.3, `h2` 0.6.1, `hackney` 4.0.3; test
  deps `meck` 1.2.0 and `cowboy` 2.15.0.

## [2.0.2] - 2026-05-23

A security release from a release-time review of the HTTP transport
and the auth providers. No public API changes.

### Security

- **Authentication is enforced on every Streamable HTTP verb.**
  Previously only POST ran the configured auth provider; GET (open
  SSE stream) and DELETE (terminate session) were gated by the
  `Mcp-Session-Id` alone. A caller holding a leaked session id could
  read a session's server-to-client SSE traffic (including replayed
  buffered events) or terminate sessions without presenting a
  credential. Both verbs now run the same auth gate as POST, before
  any session lookup. With `barrel_mcp_auth_none` (the default)
  behaviour is unchanged.
- **Resource, prompt and completion handler crashes no longer leak
  exception terms to the client.** The 2.0.1 change that returns a
  generic `Internal tool error` covered only `tools/call`. The
  synchronous `resources/read`, `prompts/get` and
  `completion/complete` paths still serialised the caught
  `Class:Reason` (which can carry internal paths, argument values or
  secret-bearing terms) into the JSON-RPC error. They now log the
  class, reason, stack, request id and handler name via
  `logger:error` and return a generic message.
- **The built-in listener caps concurrent connections.** Because
  `idle_timeout` is `infinity` (so long-lived SSE GETs are never
  reaped), a connection lived until the peer closed it, so a flood of
  connections or slow/idle keep-alive clients could exhaust file
  descriptors and memory. Each listener now bounds established
  connections (default 16384, override with the `max_connections`
  start option) and drops connections past the cap. h1's default 60s
  `request_timeout` already bounds slow request headers.
- **Basic-auth unknown-user timing matches the configured mode.**
  When `hash_passwords` was `false` the unknown-user path still ran
  the slow PBKDF2 stand-in while the configured-user path ran a fast
  SHA-256 compare, so response timing could reveal whether a username
  existed. The stand-in now does the same work as the active
  comparison mode.

### Fixed

- **Client reports its real version.** The default `client_info` sent
  in `initialize` was pinned at `2.0.0`; it now matches the library
  version. The README dependency example also pinned the stale
  `v1.3.0` tag.

## [2.0.1] - 2026-05-21

Follow-up hardening from a review of the 2.0.0 transport.

### Fixed

- **`_auth` no longer leaks into inbound responses.** The Streamable HTTP transport tagged the authenticated principal (`_auth`) on every decoded message before splitting requests from responses, so a client-posted JSON-RPC response (answering a server `sampling`/`elicitation` request) carried `_auth` into the delivered map. It is now attached only on the request dispatch path, matching 1.x behaviour. Server-internal only; no data was sent to clients.
- **Accept loop no longer spins on persistent errors.** `barrel_mcp_http_listener` now backs off briefly on a non-`closed` accept error, so a system error such as file-descriptor exhaustion (`emfile`) throttles the acceptor instead of burning CPU.

## [2.0.0] - 2026-05-21

A dependency-restructuring release. The HTTP server transport is rebuilt on the `h1` and `h2` libraries and Cowboy is removed from the library, so `barrel_mcp` can be embedded next to web frameworks (such as Livery) that bring their own HTTP stack without dragging Cowboy into the runtime. The protocol core and the public start/stop API are unchanged.

### Changed (breaking)

- **No Cowboy in the runtime.** The `barrel_mcp` application's `applications` list is now `[kernel, stdlib, crypto, h1, h2, hackney]` (was `[..., cowboy, hackney]`). The built-in HTTP server (`barrel_mcp:start_http/1`, `barrel_mcp:start_http_stream/1`) runs on `h1`/`h2`: a cleartext bind speaks HTTP/1.1, and a TLS bind serves HTTP/1.1 and HTTP/2 on the same port via ALPN. Start/stop options and the protocol-core entry points are unchanged. Hosts that relied on `barrel_mcp` transitively starting Cowboy must drop that assumption and add the apps they need to their own release.
- **Dependencies.** Added `h1` (hex package `erlang_h1`) 0.2.2 and `h2` 0.6.0; removed `cowboy`. The MCP HTTP client still uses `hackney`, bumped to 4.0.0. Cowboy is now a test-only dependency (the OAuth DCR and EMA suites mock an authorization server with it).

### Added

- `barrel_mcp_http_engine`: a transport-neutral implementation of the Streamable HTTP and simple HTTP protocol logic (routing, sessions, CORS, Origin validation, authentication, the OAuth protected-resource-metadata endpoint, async tool calls). It drives response I/O through a small `Responder` map of closures, so the built-in `h1`/`h2` server and external adapters (for example a Livery handler) can both reuse it.
- `barrel_mcp_http_listener`: the built-in single-port `h1`/`h2` server (cleartext h1, TLS h1+h2 via ALPN). A listener `stop` now tears down its in-flight connection processes.

### Removed

- `barrel_mcp_prm_handler`: the `/.well-known/oauth-protected-resource` route is now served directly by `barrel_mcp_http_engine`.

## [1.3.0] - 2026-05-10

A feature release that completes the OAuth surface vs MCP `2025-11-25` and `modelcontextprotocol/ext-auth`: Enterprise-Managed Authorization (EMA) for SSO-driven hosts, Dynamic Client Registration (RFC 7591) including the section-3 protected variant, plus four security follow-ups from review (scope fail-closed, no exception leakage, capped client buffers, no redirect-following on discovery).

### Security follow-ups

- **Scope checks now fail closed.** When `required_scopes` is configured but a custom auth provider returns an `AuthInfo` map without a `scopes` key (or with a non-list value), the request is rejected with `{error, insufficient_scope}`. Previously these requests were admitted because the catch-all `check_scopes/2` clause returned `{ok, AuthInfo}`. Behaviour is unchanged for `barrel_mcp_auth_bearer` (which always emits a list).
- **Tool crash details no longer leak to clients.** When a tool handler raises, `barrel_mcp_registry` logs the class, reason, stack, request id, module and function via `logger:error`. The wire-level error is now a generic `<<"Internal tool error">>` from both `barrel_mcp_protocol` and `barrel_mcp_http_stream`; the previous `io_lib:format("~p", [Reason])` could disclose module/file/function names and exception terms.
- **Streamable-HTTP client buffers are capped.** `barrel_mcp_client_http` now bounds in-flight response buffers (16 MiB) and SSE event buffers (4 MiB). On overrun the client emits `{mcp_closed, Pid, {response_too_large, Bytes}}` and drops the request from tracking; a malicious or compromised MCP server can no longer drive unbounded memory growth in the host.
- **OAuth discovery no longer follows redirects.** `barrel_mcp_client_auth_oauth:discover_protected_resource/1` and `discover_authorization_server/1` previously passed `{follow_redirect, true}`, which let an untrusted MCP server redirect discovery into an SSRF-style probe. The flag is now `false`; non-2xx surfaces as `{error, {http_error, Status}}`.

### Enterprise-Managed Authorization grant

- New connect-spec entry `auth => {oauth_enterprise, Config}` chains an IdP-issued ID Token (or SAML assertion) through RFC 8693 token-exchange (at the IdP) and RFC 7523 jwt-bearer (at the AS) into a short-lived MCP access token. Required Config keys: `idp_token_endpoint`, `as_token_endpoint`, `client_id`, `subject_token`, `subject_token_type`, `audience`, `resource`. Optional `client_secret` / `client_assertion`, `scopes`. Implements the second half of `modelcontextprotocol/ext-auth` for SSO-driven MCP hosts.
- New public exchangers `barrel_mcp_client_auth_oauth:token_exchange/2` and `jwt_bearer/2` for hosts that want to drive each step directly.
- The handle re-walks the chain on every 401 (no `refresh_token` involved). When the IdP returns `invalid_grant` the library surfaces the typed `{error, subject_token_expired}` so the host can re-acquire from its IdP without parsing JSON.

### Dynamic Client Registration (RFC 7591)

- New public `barrel_mcp_client_auth_oauth:register_client/2`. Posts the supplied client metadata to the AS's `registration_endpoint` and returns the response unchanged: `client_id`, optional `client_secret`, `client_id_issued_at`, `client_secret_expires_at`, plus any echoed metadata. Hosts feed the returned credentials into a subsequent `{oauth, ...}` / `{oauth_client_credentials, ...}` connect spec.
- Stays a standalone exchanger: auto-wiring would need persistent storage of issued credentials, which is host policy. Documented in the OAuth section of the auth guide.
- New `register_client/3` accepts an `Opts` map. `initial_access_token` (RFC 7591 section 3) attaches `Authorization: Bearer ...` so protected registration endpoints work.

### `_meta` end-to-end propagation

- The MCP spec defines `_meta` as the extensibility hook on every JSON-RPC envelope. Previously only `_meta.progressToken` was read on `tools/call`; everything else dropped on the floor. Now:
  - **Inbound**: tool handler `Ctx` carries the full inbound `_meta` map under the `meta` key. `progress_token` stays for back-compat. The async plan emitted by `barrel_mcp_protocol:handle/1` for `tools/call` carries `meta` so transports without their own `_meta` extraction (stdio, legacy HTTP) get it via `barrel_mcp_protocol:drive_async_plan/2`.
  - **Outbound**: new return shapes on tool handlers — `{result_meta, Result, MetaMap}`, `{structured_meta, Data, Content, MetaMap}`, `{tool_error, Content, MetaMap}` — surface `_meta` on the response. The existing tuple shapes are unchanged.
  - **Envelope helpers**: new `barrel_mcp_protocol:success_response/3` and `error_response/4` accept an optional `_meta` map. Empty map omits the field. Used by every transport's tool-outcome path so the wire shape is consistent.
- 8 new eunit cases cover the envelope helpers, `drive_async_plan` for the new result/structured/error meta variants, and an end-to-end `_meta` round-trip through a tool that echoes Ctx-supplied `_meta` back through the response.

### Server-side OAuth Protected Resource Metadata + spec-correct `WWW-Authenticate`

- New `resource_metadata` start option on `barrel_mcp:start_http_stream/1` and `barrel_mcp:start_http/1`. When set, the server registers a cowboy route at `/.well-known/oauth-protected-resource` that returns the configured RFC 9728 PRM document as JSON, and threads the absolute PRM URL into the auth provider's challenge.
- **Wire change.** `barrel_mcp_auth_bearer`'s 401 challenge now emits `Bearer realm="...", resource_metadata="<URL>"` (RFC 9728 / MCP auth sub-spec) instead of the previous non-conformant `resource="..."` parameter (which conflated the RFC 8707 audience claim with the metadata URL). MCP clients can now auto-discover a barrel_mcp deployment's authorization server end-to-end by parsing `WWW-Authenticate` and following `resource_metadata`.
- New `barrel_mcp_prm_handler` cowboy handler. Two new helpers exported from `barrel_mcp_http_stream`: `normalize_resource_metadata/1`, `inject_resource_metadata_url/2` (legacy `barrel_mcp_http` reuses them).
- New CT cases `prm_endpoint_serves_metadata` and `bearel_challenge_includes_resource_metadata` in `barrel_mcp_http_stream_security_SUITE`.

### `barrel_mcp_client:notify_roots_list_changed/1`

- New client emitter for `notifications/roots/list_changed`. Hosts that mutate their roots after `initialize` (user opened a new workspace, granted access to a new directory, …) call this so the server picks up the change without polling. The server may follow up with `roots/list` against the host's handler.
- The server-side dispatch hook (`application:set_env(barrel_mcp, roots_changed_handler, {Mod, Fun})`) was already in place; this PR closes the inverse direction.
- New `test/barrel_mcp_client_roots_SUITE` integration test stands up a real Streamable HTTP server with a roots-changed handler that forwards to the test process; asserts the notification round-trips end-to-end.

### `resources/read` runtime template expansion

- Registered `resource_template` entries are now matched against incoming `resources/read` URIs and routed to the template's handler. Previously templates only appeared in `resources/templates/list`; reading any URI matching one returned `Resource not found`.
- New `barrel_mcp_uri_template` module implementing RFC 6570 Level 1 (simple `{var}` expansion). `match/2` returns a binary-keyed map of substituted values; `expand/2` is the inverse. 13 eunit cases cover single / multi-variable, literal-only, malformed templates, and round-trip.
- The substituted variables flow into the handler's `Args` map alongside the original request `params`, so a `file:///{path}` template matched against `file:///etc/hosts` lets the handler read `<<"path">>`.
- Direction A of the Python interop suite reads `file:///etc/hosts` against the `file:///{path}` fixture template and asserts the handler's expanded `path` value round-trips.


## [1.2.0] - 2026-05-03

A large release that consolidates everything since 1.1.0:
hardened security on both HTTP transports, full server-side
spec parity for MCP `2025-11-25` (including the new `tasks/*`
surface and the three server-to-client primitives), the
agent-host story (federation registry, multi-server aggregator,
LLM provider tool-shape bridge), a Python interop harness that
exercises every wire surface against `mcp 1.27.0` in both
directions, server-side cursor pagination on every `*/list`
endpoint, the OAuth Client Credentials grant from
`modelcontextprotocol/ext-auth`, and three runnable example
apps. The default `protocol_version` env is now `2025-11-25`
(was `2025-03-26`).

**Breaking wire-level changes since 1.1.0** — hosts that
produced or consumed these envelopes need to update:

- `notifications/tasks/changed` was renamed to `notifications/tasks/status` (the spec method name).
- `tools/call` for `long_running => true` tools wraps the immediate response as `CreateTaskResult` (`{<<"task">> => Task}`) instead of the flat `{taskId, status}`.
- Task envelopes use `lastUpdatedAt` (was `updatedAt`) and include a `ttl` field (always `null` for now).
- `tasks/cancel` returns the cancelled `Task` instead of `{}`.
- `tasks/result` returns a `CallToolResult` (`{<<"content">>, <<"structuredContent">>?}`) instead of the raw stored value.
- Task status vocabulary is now `working | completed | failed | cancelled` (was `running | success | error | cancelled`).
- Task timestamps are RFC 3339 strings (were integer milliseconds).
- `initialize` advertises `tasks.list` / `get` / `cancel` / `result` as objects, not bare booleans.
- POST `tools/call` clients on Streamable HTTP must now list **both** `application/json` and `text/event-stream` in `Accept` (or `*/*`).
- `Origin` is structurally validated on every Streamable HTTP method; public binds require explicit `allowed_origins`.
- `barrel_mcp_http_stream` defaults to loopback (`{127, 0, 0, 1}`).
- Top-level JSON-RPC arrays (batch requests) are rejected with `-32600`.
- JSON-RPC `id` MUST be a string or integer; `null` and other shapes are rejected.

### Cancellation race fix in Streamable HTTP

- `wait_for_tool/2` now does a 50ms lookahead after every tool outcome to absorb a pending `{cancelled, _}` message that races with the worker's response. A cooperative arity-2 handler that returns `{tool_error, ...}` on cancel could deliver its outcome to the waiter's mailbox **before** the session-emitted `{cancelled, _}`, depending on scheduler — which made the HTTP path emit a JSON-RPC `isError: true` envelope instead of the spec-mandated 200 + empty body. With the lookahead the cancel always wins.

### OAuth Client Credentials grant (MCP `ext-auth` extension)

- `barrel_mcp_client_auth_oauth` now supports the OAuth 2.1 `client_credentials` grant for unattended agent hosts. Pass `auth => {oauth_client_credentials, Config}` on the connect spec; required keys are `token_endpoint` and `client_id`, plus either `client_secret` (HTTP Basic per RFC 6749) or `client_assertion` (`private_key_jwt`, RFC 7523). Optional `scopes`, `resource`.
- New public exchanger `barrel_mcp_client_auth_oauth:client_credentials/2` for direct use outside the auth-handle flow.
- The library fetches the token eagerly during `init/1` (so a misconfigured client fails fast) and re-acquires via the same grant on every 401 — no refresh_token involved. Reuses the existing PRM + AS metadata discovery code.
- Implements the OAuth Client Credentials extension from `modelcontextprotocol/ext-auth`. The Enterprise-Managed Authorization extension (token-exchange + JWT bearer assertions) is left for follow-up; ask if you need it.

### Doc cleanup: stale roadmap items + subscription session scope

- `guides/features.md`'s roadmap section called out a "periodic deadline timer" and "client-side `Last-Event-ID` resume" as missing. Both turn out to be either by-design (default request timeout already bounds every call; explicit `infinity` is a deliberate caller choice) or already shipped (the transport's `reopen_sse` loop preserves `sse_last_event_id` across server-initiated SSE closes, and a full client restart re-initializes the session anyway). Replaced the roadmap section with notes explaining each.
- `guides/tools-resources-prompts.md` now calls out that `resources/subscribe` is scoped to the calling `Mcp-Session-Id`: when a client re-initializes, the new session id has no carry-over subscriptions and must subscribe again. Matches the spec's session-lifecycle model; previously implicit.

### `examples/agent_host` — runnable multi-server federation demo

- New example app showing the `barrel_mcp_agent` aggregator + router end-to-end. `agent_host:run/0` connects two clients to one in-process MCP server under different `ServerId`s, calls `barrel_mcp_agent:list_tools/0` to surface the namespaced catalog, and routes a `<<"beta:echo">>` call through the right client. CT case asserts the namespaced names appear and the routed result round-trips.
- Closes the docs loop for `barrel_mcp_agent` (the module shipped without a runnable example).
- Picked up by `make examples-test` automatically (the existing `for ex in examples/*/` loop).

### Server-side cursor pagination on `*/list`

- `tools/list`, `resources/list`, `resources/templates/list`, `prompts/list`, and `tasks/list` now accept an opaque `cursor` parameter and emit `nextCursor` when more entries remain. Page size is 50, sorted by name (or `taskId` for tasks). Existing single-shot callers see the first page transparently.
- Direction A of the Python interop suite registers 60 dummy tools and walks `tools/list` via `cursor` until exhausted, asserting at least one `nextCursor` was emitted, no duplicates across pages, and that all fixture tools are visible across the walk.

### Interop assertions tightened to value level

- Direction A's `list_tools`, `list_resources`, `read_resource`, `list_prompts`, `get_prompt`, `list_resource_templates`, and `complete` now assert the actual field values returned by the Erlang server (descriptions, mime types, prompt argument names, content text, completion suggestions) instead of just presence checks. Same for Direction B against the Python FastMCP server.

### Interop coverage: full feature surface

Direction A (Python client → Erlang server) now exercises every wire surface defined by the MCP spec:

- `ping`, `prompts/get`, `resources/templates/list`, `completion/complete`.
- Tool result variants: `structuredContent` and `isError: true`.
- `notifications/tools/list_changed` (auto-emitted by `reg`/`unreg`).
- `notifications/cancelled` end-to-end: start a long-running task, cancel mid-flight via `experimental.cancel_task`, verify the cooperative arity-2 worker observes `{cancel, RequestId}` in its mailbox.
- `notifications/tasks/status` captured via the `message_handler` while running other long-running tools.

Direction B (Erlang client → Python FastMCP server) now exercises:

- `tools/list`, `tools/call`, `resources/list`, `resources/read`, `prompts/list`, `prompts/get`, `ping`.

Together with sampling / elicitation / roots / progress / subscribe / tasks already covered, every spec wire surface is now verified against the reference SDK on every CI run.

### `notifications/tasks/changed` renamed to `notifications/tasks/status`

- The Task status-change notification was emitted under method `notifications/tasks/changed`. The reference Python SDK's `ServerNotification` discriminated union uses the spec method name `notifications/tasks/status`. Renamed everywhere to match. Hosts that subscribed to `notifications/tasks/changed` need to switch to the new name.

### Interop coverage: notifications/progress

- Direction A of the Python interop suite now exercises `notifications/progress` end-to-end. A server-side `progress_echo` tool emits three progress events through the arity-2 handler's `Ctx.emit_progress`; the reference Python SDK auto-attaches a progress token on `call_tool` and routes the inbound notifications to a `progress_callback`. Verifies the progress token plumbing, SSE delivery of progress notifications, and the SDK's progress dispatch.

### Long-running tools: spec-shaped CreateTaskResult + CallToolResult on tasks/result

- **Wire change.** `tools/call` for `long_running => true` tools now returns the spec-shaped `CreateTaskResult` envelope `{<<"task">> => Task}` (the full Task object with taskId, status, createdAt, lastUpdatedAt, ttl) instead of the flat `{taskId, status}` shape that was rejected by the reference Python SDK with a pydantic ValidationError. Hosts that previously read `Result.taskId` need to read `Result.task.taskId`.
- **Wire change.** The task collector now stores tool results as the spec-shaped `CallToolResult` (`{content, structuredContent?}`) instead of the raw value, so `tasks/result` returns a payload that decodes as `CallToolResult` against the reference SDK. Previously `tasks/result` could surface bare strings, which the JSON-RPC envelope validator rejected.
- Direction A of the Python interop suite now exercises the full long-running flow end-to-end: `experimental.call_tool_as_task` → poll `experimental.get_task` until `completed` → fetch `experimental.get_task_result(..., CallToolResult)`. Both wire shapes above are now validated against `mcp 1.27.0`'s pydantic models on every CI run.

### Interop coverage: elicitation/create + roots/list

- Direction A now exercises the remaining two server-to-client primitives end-to-end against the reference SDK: a server-side tool calls `barrel_mcp:elicit_create/3` (form-mode payload), the Python `elicitation_callback` returns an `accept` action with a fixed colour, and the tool surfaces that colour as text. Same shape for `roots/list`: a tool calls `barrel_mcp:roots_list/1`, the Python `list_roots_callback` returns one fixed root, and the tool surfaces its name. With sampling already covered, every server-to-client primitive is now wire-validated against the reference implementation on every CI run.

### Interop coverage: server-to-client sampling/createMessage

- Direction A of the Python interop suite now exercises the full sampling round-trip against the reference SDK: a server-side tool calls `barrel_mcp:sampling_create_message/3`, the Python `sampling_callback` returns a canned reply, the tool surfaces that text as its result. Verifies that the pending-request map, SSE delivery, response correlation, and capability gating all interoperate with the reference implementation.

### Interop coverage: resources/subscribe + notifications/resources/updated

- Direction A of the Python interop suite now exercises the full subscribe round-trip: subscribe to a URI, trigger a server-side `notify_resource_updated/1`, wait for the inbound `notifications/resources/updated` to arrive on the client SSE stream, unsubscribe. Verifies that `barrel_mcp_session:subscribe_resource/2`, `notify_resource_updated/1`, and the SSE delivery path all interoperate correctly with the reference implementation's notification handling.

### Tasks Task-shape wire alignment

- Renamed the wire field `updatedAt` → `lastUpdatedAt` on every Task envelope (`tasks/get`, `tasks/list`, `notifications/tasks/changed`). The reference Python SDK models the field as `lastUpdatedAt`, and accepts no other name.
- Added a `ttl` field to every Task envelope (always `null` for now — we don't yet honour client-supplied TTLs). The Python SDK's `Task` model requires the field to be present.
- `tasks/cancel` now returns the cancelled Task instead of `{}`. Matches `CancelTaskResult` in the reference SDK; existing barrel_mcp clients that pattern-match `{ok, _}` are unaffected.
- Extended the Direction A interop test to call `experimental.list_tasks()`, exercising the Task wire shape end-to-end against the reference pydantic models.

### Tasks capability wire shape fix

- `initialize` now advertises `tasks.list` / `tasks.get` / `tasks.cancel` / `tasks.result` as the spec-shaped empty objects (`#{}`) instead of bare `true` booleans. Caught by the new Python interop tests; the reference Python SDK rejects `bool` for these fields with a pydantic `ValidationError`. `listChanged` stays a boolean (the spec keeps that one as bool).

### Python interop test harness

- New `test/interop/` directory pairing a Python MCP client (`client.py`, Streamable HTTP) and a Python FastMCP server (`server.py`, stdio) with the official `mcp` SDK pinned to `~= 1.27.0`.
- New `test/barrel_mcp_python_interop_SUITE` Common Test suite drives both directions: Python client → Erlang server (initialize, list_tools / call_tool, list_resources / read_resource, list_prompts, set_logging_level), and Erlang client → Python server (list_tools, call_tool round-trip).
- `make interop-setup` creates the venv, `make interop-test` runs the suite. The CT cases skip cleanly when `INTEROP_PYTHON` is unset, so the default `rebar3 ct` loop is unaffected by missing Python tooling.
- New `interop` CI job runs both directions on Linux with Python 3.12 + OTP 28.

### `barrel_mcp_agent` — multi-server tool aggregator

- New module sitting on top of `barrel_mcp_clients`. Aggregates `tools/list` across every connected MCP client, rewrites each tool name to `<<"ServerId<sep>ToolName">>` (default separator `:`), and routes a namespaced `call_tool/2,3` back to the correct client.
- `to_anthropic/0,1` and `to_openai/0,1` return the aggregated catalog directly in provider format, ready to hand to a model.
- Closes the orchestration gap for hosts running an agent loop against multiple MCP servers.

### `barrel_mcp_tool_format` — LLM provider tool-shape translator

- New module bridging MCP tool definitions and the tool shapes the LLM provider APIs expect.
- `to_anthropic/1`, `to_openai/1` translate MCP `tools/list` entries (single map or list) to the Anthropic Messages API and OpenAI Chat Completions tool shapes.
- `from_anthropic_call/1`, `from_openai_call/1` translate a model's tool-call back to the `(Name, Arguments)` pair `barrel_mcp_client:call_tool/4` expects. Accepts both parsed arguments (already a map) and the wire form (JSON string).
- Closes the bridge an agent host needs when it hands MCP tools to a model and routes the model's tool calls back through an MCP client.

### `resources/read` content-block flexibility

- Resource handlers may now return a list of pre-built content blocks; each block is passed through verbatim, with `uri` auto-injected when the handler omits it.
- The `#{text := _}` and `#{blob := _, mimeType := _}` map shapes accept optional `mimeType` (text only — blob already requires it) and `annotations` keys, matching the spec's per-content metadata. Both flow through to the wire under `mimeType` / `annotations`.

### Tool, resource, prompt, and resource-template annotations

- `reg_tool/4`, `reg_resource/4`, `reg_prompt/4`, and `reg_resource_template/4` accept a new `annotations` option — a free-form map surfaced verbatim under `annotations` in the matching `*/list` payload. The MCP spec defines `readOnlyHint` / `destructiveHint` / `idempotentHint` / `openWorldHint` for tools, and `audience` / `priority` for resources, prompts, and templates. Registrations without annotations omit the field on the wire.

### `logging/setLevel` actually filters the log stream

- The previous `logging/setLevel` handler was a no-op stub that accepted any payload and returned `{}`. It now validates the requested level against the eight RFC 5424 levels (debug, info, notice, warning, error, critical, alert, emergency), persists the chosen level on the session, and rejects unknown levels with `-32602`.
- New `barrel_mcp:notify_log/3,4` façade. Emits `notifications/message` to a session and is silently dropped when the event level is below the session's configured level. Default session level is `info`, matching the spec.
- New helpers `barrel_mcp_session:set_log_level/2`, `get_log_level/1`, `log_level_priority/1`.

### Server-to-client `roots/list`

- New `barrel_mcp:roots_list/1,2` façade. Sends `roots/list` to the connected client behind a session id and returns the host's roots. Requires the client to have declared `roots` capability in its `initialize' request and an active SSE stream.
- New helpers `barrel_mcp:list_sessions_with_roots/0`, `barrel_mcp_session:has_roots/1`, `barrel_mcp_session:list_roots_capable/0`.

### Server-to-client `elicitation/create`

- New `barrel_mcp:elicit_create/3` façade. Sends `elicitation/create` to the client behind a session id and blocks until the client responds (or `timeout_ms` elapses, default 30s). Requires the client to have declared `elicitation` capability in its `initialize' request and an active SSE stream. Mirrors the existing `sampling_create_message/3` flow.
- New helpers `barrel_mcp:list_sessions_with_elicitation/0`, `barrel_mcp_session:has_elicitation/1`, `barrel_mcp_session:list_elicitation_capable/0`.
- Internally, the server's pending-request map now carries the response tag, so sampling and elicitation responses route back to the correct caller without colliding.

### Tasks spec parity (MCP 2025-11-25)

- **Status vocabulary aligned with spec.** Internal `running | success | error | cancelled` replaced with `working | completed | failed | cancelled` on the wire (in `tasks/get`, `tasks/list`, `notifications/tasks/changed`, and the immediate `tools/call` response when `long_running => true`).
- **RFC 3339 timestamps.** `createdAt` and `updatedAt` are emitted as ISO 8601 strings via `calendar:system_time_to_rfc3339/1` instead of integer milliseconds.
- **`tasks/result` method.** New JSON-RPC method to fetch the recorded result for a `completed` task (or the recorded error for `failed`); returns `Task not yet complete` for `working`, `Task cancelled` for `cancelled`, and `Task not found` otherwise. New client wrapper `barrel_mcp_client:tasks_result/2`.
- **Tasks capability shape.** Advertised as `#{list, get, cancel, result, listChanged}` instead of the bare `#{listChanged}` placeholder.

### Critical correctness and security fixes

- **API-key auth verification.** `barrel_mcp_auth_apikey:verify_key/2` no longer returns `ok` for any HMAC-formatted stored value (it was self-comparing `Stored` with itself). The 2-arity helper now rejects HMAC formats with `{error, pepper_required}`; a new `verify_key/3` takes the pepper and does a constant-time HMAC compare. The provider state now keeps `pepper`, so `hash_keys => true` with a configured pepper actually verifies HMAC keys end to end.
- **Async tools/call works on stdio and legacy HTTP.** `barrel_mcp_protocol:handle/2` returns `{async, AsyncPlan}` for `tools/call`; both transports now drive the plan via the new `barrel_mcp_protocol:drive_async_plan/2` helper. Tool calls over stdio went from broken to functional.
- **Session cleanup no longer self-calls.** The cleanup timer in `barrel_mcp_session` previously routed through `gen_server:call(?MODULE, ...)` from inside its own `handle_info` and would deadlock. The cleanup is now inlined in `handle_info(cleanup, _)`.
- **Basic auth unknown-user timing.** The unknown-user fake check now runs the same PBKDF2 work as the configured-user path via a precomputed dummy hash. Previously the configured `hash_passwords => false` path used a fast SHA-256 compare while the unknown-user path always did PBKDF2, leaking username existence.
- **Streamable HTTP: Accept strictness.** POST clients must list both `application/json` and `text/event-stream` (or `*/*`). `application/json` alone now returns 406.
- **Streamable HTTP: initialize with unknown session id → 404.** Previously silently created a fresh session; now forces the client to re-initialize without a session header.
- **Legacy HTTP transport hardened.** Reuses the Streamable HTTP `validate_origin/2`, `cors_response_headers/3`, and `extract_headers/2` helpers. No more wildcard `Access-Control-Allow-Origin`; auth headers come from the configured provider's `auth_headers/1` callback (custom `header_name` flows through CORS and into header extraction).
- **`tasks/cancel` actually stops the worker.** Long-running tools now record their worker pid on the task; `tasks/cancel` sends `{cancel, RequestId}` to the worker before transitioning the stored status. Cooperative arity-2 handlers can abort cleanly; arity-1 handlers still run to completion but their result is dropped because the task is in a terminal state.

### Spec parity additives

- Long-running tools return a `taskId` immediately; clients track them via `tasks/list`, `tasks/get`, `tasks/cancel` and `notifications/tasks/changed`. Opt in with `reg_tool/4`'s `long_running => true`.
- Tools can return structured output via `{structured, Data}` or `{structured, Data, Content}`; the response includes `structuredContent`. Opt-in `validate_output => true` schema-checks the output and surfaces failures as `isError: true`.
- `completion/complete` is backed by a registry. Hosts call `barrel_mcp:reg_completion(Ref, Mod, Fun, Opts)` to provide suggestions for prompt or resource-template arguments. The `completions` capability is advertised when at least one is registered.
- Tool, resource, prompt, and resource-template registrations accept `title` and `icons`; the matching `*/list` responses surface them.
- Streamable HTTP keeps a per-session ring buffer of recent SSE events. Reconnecting clients with `Last-Event-ID` get every event newer than that id replayed before live mode; an out-of-window id yields a synthetic `notifications/replay_truncated`. Buffer size configurable via `start/1`'s `sse_buffer_size`.

### Spec parity: protocol bump, async tools, list-changed, auth hardening

- **Server protocol bumped to `2025-11-25`.** `initialize' negotiates with the client: when the client requests a version we speak, we echo it; otherwise we reply with our preferred version. Capabilities advertised in `initialize' now include `listChanged: true' on `tools', `resources', and `prompts'.
- **Async tool execution.** `barrel_mcp_protocol:handle/2` returns `{async, AsyncPlan}` for `tools/call'; the transport invokes the spawn closure to start a worker, records the in-flight entry, and waits on its mailbox. Tool handlers may export arity 1 (legacy) or arity 2 (`(Args, Ctx)` — the new shape that receives session/progress context).
- **`notifications/cancelled' wired end-to-end.** Inbound cancel finds the in-flight worker via `barrel_mcp_session:cancel_in_flight/2`, sends `{cancel, RequestId}' to the worker and `{cancelled, RequestId}' to the waiter. Per the MCP spec the cancelled HTTP request closes with 200 + empty body; no JSON-RPC response is emitted.
- **`notifications/progress' emit + handler context.** New façades `barrel_mcp:notify_progress/3,4`. Arity-2 tool handlers receive `Ctx` with an `emit_progress` function bound to the session's progress token, so they can emit progress without knowing about sessions.
- **`notifications/roots/list_changed' dispatch hook.** Configurable via `application:set_env(barrel_mcp, roots_changed_handler, {Mod, Fun}).`. No-op when unset.
- **`resources/templates/list' real registry.** New `barrel_mcp:reg_resource_template/4`, `unreg_resource_template/1`, `list_resource_templates/0`. The protocol method now returns the registered templates instead of an empty stub.
- **Server-side input validation.** `reg_tool/4` accepts `validate_input => true`; the registry runs `barrel_mcp_schema:validate/2` against the tool's `input_schema` before invoking the handler. Failures surface to the client as `isError: true` content.
- **Tool error reporting via `isError: true`.** Handlers may return `{tool_error, Content}'; the transport wraps it as `#{<<"content">> => Content, <<"isError">> => true}`.
- **`*/list_changed' notifications.** `barrel_mcp_registry:reg/4,5` and `unreg/2` automatically broadcast the matching `notifications/<kind>/list_changed` envelope to every active SSE session. New `barrel_mcp:notify_list_changed/1` for out-of-band catalogue changes.
- **Auth hardening.**
  - `barrel_mcp_auth_basic:hash_password/1,2` now defaults to **PBKDF2-SHA256** (100k iterations, random salt). Stored format `pbkdf2-sha256$<iters>$<b64(salt)>$<b64(hash)>`. Public `verify_password/2` accepts the new format and the legacy hex SHA-256 digest (the latter logs a deprecation warning).
  - `barrel_mcp_auth_apikey:hash_key/2` adds an **HMAC-SHA-256** keyed format (`hmac-sha256$<b64(hash)>`). Public `verify_key/2` honours both formats with constant-time comparison.

### Security and spec conformance (Streamable HTTP + JSON-RPC)

- **Origin validation.** Streamable HTTP and the legacy `barrel_mcp_http` now validate the `Origin` header on POST/GET/DELETE/OPTIONS using `uri_string:parse/1` (structural scheme/host/port match — no binary prefix matching). New options `allowed_origins` and `allow_missing_origin`. The literal `Origin: null` value is treated as a distinct present origin and is rejected unless explicitly allowed.
- **Default bind to loopback.** Both transports default to `{127, 0, 0, 1}`. Public binds require an explicit `allowed_origins`; the start function refuses with `{error, allowed_origins_required}` otherwise.
- **CORS tightening.** `Access-Control-Allow-Origin` now echoes the validated `Origin` (no wildcard) with `Vary: Origin`, and is omitted entirely when no `Origin` is sent. The `Access-Control-Allow-Headers` allow-list is derived from the configured auth provider via a new optional `auth_headers/1` callback on `barrel_mcp_auth`. Custom API-key header names are honoured both in CORS and in `extract_headers`.
- **Streamable HTTP response shape.** Notifications and POSTed responses to server-initiated requests now return **202 Accepted** with empty body. Missing `Mcp-Session-Id` on a non-initialize request returns **400 Bad Request**; unknown/invalid id returns **404 Not Found**. `initialize` is the only request that may run without a session.
- **`MCP-Protocol-Version` server validation.** Present-but-unsupported header → 400 with the supported list. Missing header on a session that has completed initialize falls back to the session-stored negotiated version. Pre-init / no session falls back to `2025-03-26` per spec compatibility guidance. New `?MCP_SUPPORTED_VERSIONS` macro.
- **JSON-RPC id strictness.** `barrel_mcp_protocol:handle/2` and `decode_envelope/1` now reject ids that are not `binary` or `integer` (including `null`) with `-32600 Invalid Request`.
- **Batch rejection.** Top-level JSON arrays are explicitly rejected with `-32600 Batch requests are not supported` at both the HTTP boundary and inside `handle/2`.
- **ETS visibility.** `barrel_mcp_sessions`, `barrel_mcp_resource_subs`, and `barrel_mcp_pending_requests` are now `protected`. Every public mutator on `barrel_mcp_session` (create, update_activity, delete, set_client_capabilities, set_protocol_version, set_sse_pid, subscribe_resource, unsubscribe_resource, deliver_response, cleanup_expired) routes through the gen_server.
- New `test/barrel_mcp_http_stream_security_SUITE.erl` covers Origin matching, session lookup, version validation, response shape, batch / id strictness, and ETS protection.

### Added

- **Spec-conformant MCP client** (`barrel_mcp_client`)
  - Rewritten as a `gen_statem` (`connecting` → `initializing` → `ready` → `closing`).
  - Async transports forward inbound JSON-RPC envelopes as `{mcp_in, _, _}` messages.
  - Streamable HTTP client transport (`barrel_mcp_client_http`): POST with `application/json, text/event-stream`, parses SSE from POST and from a long-lived GET stream, captures `Mcp-Session-Id`, sends `MCP-Protocol-Version` after init, DELETE on close, 401 retry through pluggable auth.
  - Stdio client transport (`barrel_mcp_client_stdio`) extracted into its own gen_server.
  - Targets MCP `2025-11-25` and negotiates downward through `2025-06-18`, `2025-03-26`, `2024-11-05`.
  - Server-initiated requests/notifications routed through a `barrel_mcp_client_handler` behaviour with sync, error, and async reply forms; default no-op handler ships in `barrel_mcp_client_handler_default`.
  - Capability-shaped initialize payload (booleans become spec objects on the wire).
  - Resource subscription notifications routed back to the subscribing process.
  - Pagination, cancellation, and progress-token plumbing on `tools/call`.
- **Federation registry** (`barrel_mcp_clients`): one supervised connection per server id, looked up via `barrel_mcp:start_client/2`, `whereis_client/1`, `list_clients/0`, `stop_client/1`.
- **Auth behaviour** (`barrel_mcp_client_auth`) with a static-bearer implementation; OAuth 2.1 + PKCE planned for a follow-up.
- **JSON-RPC envelope helpers** (`encode_request/3`, `encode_notification/2`, `encode_response/2`, `encode_error/3`, `decode_envelope/1`) shared between client and server.
- New tests: `barrel_mcp_client_tests` (loopback handshake / call_tool / version downgrade), `barrel_mcp_client_handler_tests`, `barrel_mcp_clients_tests`, `barrel_mcp_protocol_envelope_tests`.
- New doc: `guides/features.md` summarising the client surface and roadmap.

### Changed

- `notifications/initialized` is now the spec name; legacy bare `initialized` still accepted for one release.
- CORS on `barrel_mcp_http_stream` exposes `mcp-protocol-version` and `last-event-id`.

### Added (ergonomics)

- `barrel_mcp_pagination:walk/1,2`: cursor walker shared by every `*/list` paged helper, with a configurable max-pages guard.
- `barrel_mcp_client:list_tools_all/1`, `list_resources_all/1`, `list_resource_templates_all/1`, `list_prompts_all/1`: walk every page and return the union.
- `barrel_mcp_schema:validate/2`: minimal JSON Schema validator covering type/properties/required/enum/items/oneOf/anyOf/allOf/min-max-length/pattern/min-max-items/uniqueItems/min-max/exclusive bounds. Returns `ok` or `{error, [{Path, Reason}]}`. Hosts use it to pre-flight LLM-generated tool args before calling the server.

### Added (control plane)

- Progress dispatch: when a caller passes `progress_token` to `call_tool/4`, the client registers the caller pid against that token and routes inbound `notifications/progress` to it as `{mcp_progress, Token, Params}`. The mapping clears automatically when the request settles, is cancelled, or times out.
- Periodic ping: `ping_interval` (default `infinity`, opt-in) sends `ping` while in `ready`. After `ping_failure_threshold` consecutive failures (default `3`), the connection closes with reason `ping_failed`.

### Added (docs)

- `guides/building-a-client.md` — task-oriented walkthrough for hosting MCP clients on `barrel_mcp` (transport choice, connect spec, lifecycle, capability negotiation, tool calls, server-initiated requests via the handler behaviour, OAuth, federation, schema validation, error reference).
- `guides/internals.md` — architecture and behaviour contracts (module map, supervision tree, state machine, message flow, transport/handler/auth contracts, ETS layout, wire format).
- `examples/echo_client/` — minimal MCP host that boots a local server, lists tools, calls `echo`. Common-test suite asserts the round-trip.
- `examples/sampling_host/` — host implementing `barrel_mcp_client_handler` to answer `sampling/createMessage`. Common-test suite covers the full server-to-client round-trip.
- `test/snippet_check.escript` + `test/doc_snippets_SUITE.erl` — extracts every `` ```erlang `` fenced block from the new guides and example READMEs and verifies it compiles. Wired into `rebar3 ct`.
- `Makefile` with `examples-setup` and `examples-test` targets; CI runs example suites on OTP 27 + 28.
- Per-function `@doc` and `-spec` on the public client surface (`barrel_mcp_client`, `barrel_mcp_clients`, `barrel_mcp_client_handler` example).
- ex_doc sidebar reorganised: client modules grouped, new "Building a Client" / "Client Internals" pages.

### Added (auth)

- `barrel_mcp_client_auth_oauth`: OAuth 2.1 + PKCE per the MCP authorization spec.
  - Discovery helpers hosts can use during initial token acquisition: `parse_www_authenticate/1`, `discover_protected_resource/1` (RFC 9728), `discover_authorization_server/1` (RFC 8414, with OpenID Connect fallback).
  - PKCE primitives: `gen_code_verifier/0`, `code_challenge/1` (S256), `build_authorization_url/2`.
  - Token endpoint: `exchange_code/2` (authorization-code grant) and `refresh_token/2` (refresh grant). Both honour the RFC 8707 `resource` parameter and support confidential-client HTTP Basic.
  - Behaviour implementation that attaches `Authorization: Bearer ...` and refreshes transparently on 401 when a `refresh_token` was supplied.
- `barrel_mcp_client_auth:new({oauth, Config})` is now wired through; `Config` accepts `access_token` (required), `refresh_token`, `token_endpoint`, `client_id`, `client_secret`, `resource`, `scopes`. The interactive authorization-code redirect step stays a host concern; once the host has tokens it hands them to the client and the library handles refresh.

## [1.1.0] - 2025-01-27

### Added

- **MCP Streamable HTTP Transport** (`barrel_mcp_http_stream`)
  - Protocol version 2025-03-26 support for Claude Code integration
  - POST with JSON or SSE streaming responses
  - GET for server-to-client notification streams (SSE)
  - DELETE for session termination
  - OPTIONS for CORS preflight
  - HTTPS/TLS support
  - See `guides/http-stream.md` for usage

- **Session Management** (`barrel_mcp_session`)
  - ETS-based session tracking for Streamable HTTP transport
  - Sessions identified via `Mcp-Session-Id` header
  - Configurable TTL with automatic cleanup (default: 30 minutes)
  - SSE stream lifecycle management

- **Custom Authentication Provider** (`barrel_mcp_auth_custom`)
  - Simplified interface for custom authentication modules
  - Only requires `init/1` and `authenticate/2` callbacks
  - Automatically extracts tokens from Bearer and X-API-Key headers
  - See `guides/custom-authentication.md` for usage

### Changed

- Protocol version updated to `2025-03-26` for Streamable HTTP transport
- Supervisor now includes session manager child spec
- Added `crypto` to application dependencies

## [1.0.0] - 2025-12-29

Initial release of barrel_mcp, an Erlang implementation of the Model Context Protocol (MCP) 2024-11-05.

### Added

#### Core Features
- **Tools** - Register and call tools with JSON Schema validation
- **Resources** - Register and read resources with URI-based addressing
- **Prompts** - Register and retrieve prompts with argument substitution
- **Registry** - ETS + persistent_term based handler registry for fast lookups

#### Transports
- **HTTP Transport** - Cowboy-based HTTP server for MCP over HTTP
- **stdio Transport** - stdin/stdout transport for Claude Desktop integration
  - Blocking mode via `start_stdio/0`
  - Supervised mode via `start_stdio_link/0`

#### Client
- **MCP Client** - Connect to external MCP servers
  - HTTP transport support via hackney
  - Tool listing and calling
  - Resource listing and reading
  - Prompt listing and retrieval

#### Authentication
- Pluggable authentication system via `barrel_mcp_auth` behaviour
- Built-in providers:
  - `barrel_mcp_auth_none` - No authentication (default)
  - `barrel_mcp_auth_bearer` - JWT/Bearer token authentication (HS256 built-in)
  - `barrel_mcp_auth_apikey` - API key authentication
  - `barrel_mcp_auth_basic` - HTTP Basic authentication
- Scope-based authorization
- Constant-time credential comparison

#### Documentation
- Comprehensive EDoc documentation for all public APIs
- HexDocs integration via rebar3_ex_doc
- Guides:
  - Getting Started
  - stdio Transport
  - Authentication
  - Tools, Resources & Prompts
  - MCP Client

### Protocol Support
- JSON-RPC 2.0
- MCP 2024-11-05 specification
- Methods: initialize, ping, tools/list, tools/call, resources/list, resources/read, prompts/list, prompts/get

[1.3.0]: https://github.com/barrel-platform/barrel_mcp/releases/tag/v1.3.0
[1.2.0]: https://github.com/barrel-platform/barrel_mcp/releases/tag/v1.2.0
[1.0.0]: https://github.com/barrel-db/barrel_mcp/releases/tag/v1.0.0
