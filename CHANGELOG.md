# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] - 2026-05-03

This release is driven by a Python interop harness (PR #24) that
exercises every spec wire surface against the official `mcp 1.27.0`
Python SDK in both directions on every CI run. The harness
surfaced several wire bugs we then fixed; this release captures
all of them. Breaking wire-level changes are listed up front.

**Breaking wire-level changes since 1.2.0** — hosts that produced
or consumed these envelopes need to update:

- `notifications/tasks/changed` was renamed to `notifications/tasks/status` (the spec method name).
- `tools/call` for `long_running => true` tools wraps the immediate response as `CreateTaskResult` (`{<<"task">> => Task}`) instead of the flat `{taskId, status}`.
- Task envelopes now use `lastUpdatedAt` (was `updatedAt`) and include a `ttl` field (always `null` for now).
- `tasks/cancel` returns the cancelled `Task` instead of `{}`.
- `tasks/result` returns a `CallToolResult` (`{<<"content">>, <<"structuredContent">>?}`) instead of the raw stored value.
- `initialize` advertises `tasks.list` / `get` / `cancel` / `result` as objects, not bare booleans.

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

## [1.2.0] - 2026-05-03

This release lands the agent-host story (server federation +
provider-shape bridge + multi-server aggregator) on top of a major
spec-conformance pass for MCP `2025-11-25`. The server's
`protocol_version` env default is now `<<"2025-11-25">>` (was
`<<"2025-03-26">>`).


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

[1.0.0]: https://github.com/barrel-db/barrel_mcp/releases/tag/v1.0.0
