# barrel_mcp features

Tracks notable capabilities and the spec-conformance status of the
Erlang MCP library. See `CHANGELOG.md` for release-by-release detail.

## Server

### Transports

- HTTP transport (`barrel_mcp_http`) — JSON-RPC over POST. Legacy.
- Streamable HTTP transport (`barrel_mcp_http_stream`) — MCP
  `2025-11-25` with downward negotiation to `2025-06-18`,
  `2025-03-26`, `2024-11-05`. POST (JSON or SSE), GET (SSE),
  DELETE, OPTIONS. Default bind `127.0.0.1`; public binds require
  `allowed_origins`. `Origin` is validated structurally on every
  method (POST/GET/DELETE/OPTIONS); literal `Origin: null` is
  rejected unless explicitly allowed. CORS echoes the validated
  origin (no wildcard); `Access-Control-Allow-Headers` is derived
  from the configured auth provider.
- stdio transport (`barrel_mcp_stdio`).

### Wire-level conformance

- POSTed JSON-RPC requests return either a JSON envelope or an SSE
  stream. Notifications and POSTed responses to server-initiated
  requests return HTTP 202 with empty body.
- Missing `Mcp-Session-Id` on a non-`initialize` request → 400;
  unknown id → 404.
- `MCP-Protocol-Version` validated server-side: missing falls back
  to the session-stored negotiated version; unsupported → 400.
- JSON-RPC `id` must be string or integer; `null` and other shapes
  rejected with -32600. Top-level JSON arrays (batches) explicitly
  rejected — MCP removed batching.
- `notifications/cancelled` aborts the in-flight tool call; the
  cancelled HTTP request closes with 200 and an empty body (no
  JSON-RPC envelope, per spec).
- Per-session SSE ring buffer (default 256 entries) for
  `Last-Event-ID` replay; out-of-window ids surface a synthetic
  `notifications/replay_truncated` event.

### Registries

- **Tools** — handlers may be arity 1 or arity 2. Arity-2
  handlers receive a `Ctx` map with `session_id`, `request_id`,
  `progress_token`, and an `emit_progress` function.
- **Resources** — text/binary content, MIME types,
  `notifications/resources/updated` for live updates. Handlers
  may return a single block (`#{text := _}` /
  `#{blob := _, mimeType := _}`, with optional `mimeType` and
  `annotations`) or a list of pre-built content blocks for
  multi-part responses.
- **Resource templates** — RFC 6570 URI templates, surfaced via
  `resources/templates/list`.
- **Prompts** — multi-message conversation templates with
  arguments.
- **Completions** — keyed by `{prompt, Name, Arg}` or
  `{resource_template, Uri, Arg}`; advertised via the
  `completions` capability when at least one is registered.
- All registrations accept optional `title` and `icons`.
- Tool, resource, prompt, and resource-template registrations
  also accept `annotations` — a free-form map surfaced verbatim
  under `annotations` in the matching `*/list` payload. Tools use
  `readOnlyHint`, `destructiveHint`, `idempotentHint`,
  `openWorldHint`; resources/prompts/templates use `audience`
  (`["user" | "assistant"]`) and `priority` (0..1).

### Tool features

- Return shapes: plain (text / map / list / image), `{tool_error,
  Content}` (→ `isError: true`), `{structured, Data}` /
  `{structured, Data, Content}` (→ `structuredContent`).
- `validate_input` and `validate_output` opt-in schema validation
  via `barrel_mcp_schema`.
- `long_running => true` returns a `taskId` immediately and runs
  the worker in the background. Backed by `barrel_mcp_tasks` —
  surfaces `tasks/list`, `tasks/get`, `tasks/cancel`, and
  `notifications/tasks/changed`.
- Cancellation: cooperative arity-2 handlers see
  `{cancel, RequestId}` in their mailbox; arity-1 handlers run to
  completion but their result is discarded.
- Progress: handlers call `(maps:get(emit_progress, Ctx))(Done,
  Total, MessageOrUndef)`; out-of-band code can use
  `barrel_mcp:notify_progress/3,4`.

### Sessions

- ETS tables are `protected`; mutators run in
  `barrel_mcp_session`'s gen_server.
- `Mcp-Session-Id` lifecycle with TTL-based cleanup.
- Server-to-client sampling (`sampling/createMessage`),
  elicitation (`elicitation/create`), roots query (`roots/list`),
  and resource update notifications.

### Authentication

- Providers: `barrel_mcp_auth_bearer`, `barrel_mcp_auth_apikey`,
  `barrel_mcp_auth_basic`, `barrel_mcp_auth_none`,
  `barrel_mcp_auth_custom`.
- Hashing: `barrel_mcp_auth_basic:hash_password/1,2` defaults to
  PBKDF2-SHA256 (100k iterations, 16-byte salt).
  `barrel_mcp_auth_apikey:hash_key/2` produces a peppered HMAC-SHA-256
  digest. Both verifiers accept legacy hex SHA-256 digests for one
  release. All comparisons are constant-time.

### Server-to-client primitives

| Façade | Effect |
| --- | --- |
| `barrel_mcp:notify_resource_updated/1,2` | `notifications/resources/updated` to every subscriber. |
| `barrel_mcp:notify_progress/3,4` | `notifications/progress` to a session. |
| `barrel_mcp:notify_log/3,4` | `notifications/message` (server log stream) to a session, filtered against the session's `logging/setLevel`. |
| `barrel_mcp:notify_list_changed/1` | `notifications/tools/list_changed`, `.../resources/list_changed`, or `.../prompts/list_changed` to every active SSE session. Auto-emitted on `reg_*`/`unreg_*`. |
| `barrel_mcp:sampling_create_message/3` | Server→client `sampling/createMessage` (requires the client to declare `sampling` capability). |
| `barrel_mcp:elicit_create/3` | Server→client `elicitation/create` to ask the host for structured user input (requires the client to declare `elicitation` capability). |
| `barrel_mcp:roots_list/1,2` | Server→client `roots/list` to enumerate the host's available roots (requires the client to declare `roots` capability). |
| `barrel_mcp_tasks:create/3`, `finish/3`, `fail/3`, `cancel/2` | Long-running operation lifecycle. |

## Client (`barrel_mcp_client`)

`barrel_mcp_client` is a supervised `gen_statem` that holds one
connection to one MCP server and routes the protocol surface defined
by the spec.

### Transports

| Transport | Module | Notes |
| --- | --- | --- |
| Streamable HTTP | `barrel_mcp_client_http` | POST with `application/json, text/event-stream`, SSE on POST and on a long-lived GET, `Mcp-Session-Id` capture, `MCP-Protocol-Version` after init, DELETE on close, 401 retry through `barrel_mcp_client_auth`. |
| stdio | `barrel_mcp_client_stdio` | Subprocess line-delimited JSON-RPC. |

### Protocol coverage (Phase A — shipped)

- Targets `2025-11-25`; negotiates downward through `2025-06-18`,
  `2025-03-26`, `2024-11-05`.
- `initialize` with spec-shaped capability objects; `notifications/initialized` (the spec name).
- `tools/list`, `tools/call`, `resources/list`, `resources/read`,
  `resources/templates/list`, `resources/subscribe`,
  `resources/unsubscribe`, `prompts/list`, `prompts/get`,
  `completion/complete`, `logging/setLevel`, `ping`,
  `tasks/list`, `tasks/get`, `tasks/cancel`, `tasks/result`.
- Task statuses on the wire: `working`, `completed`, `failed`,
  `cancelled`. Task timestamps (`createdAt`, `updatedAt`) are
  RFC 3339 strings.
- Pagination via `cursor` / `nextCursor`. Single page by default
  (`want_cursor => true` to follow paging by hand). The sugar helpers
  `list_tools_all/1`, `list_resources_all/1`,
  `list_resource_templates_all/1`, `list_prompts_all/1`,
  `tasks_list_all/1` walk every page via
  `barrel_mcp_pagination:walk/1`.
- Cancellation: `barrel_mcp_client:cancel/2` sends
  `notifications/cancelled` and unblocks the caller.
- Progress: pass `progress_token` to `call_tool/4` and the caller
  receives `{mcp_progress, Token, Params}` for every matching
  `notifications/progress` until the request settles.
- Periodic ping: opt-in via `ping_interval` (and
  `ping_failure_threshold`) in the connect spec; the connection is
  closed with reason `ping_failed` after the configured number of
  consecutive failures.
- Server→client requests dispatched through the
  `barrel_mcp_client_handler` behaviour. `{reply, _, _}`,
  `{error, _, _, _}`, and `{async, Tag, _}` reply forms; the host
  later calls `barrel_mcp_client:reply_async/3`.
- Server→client notifications routed to handler;
  `notifications/resources/updated` also forwarded to subscribers.

### Federation

- `barrel_mcp_clients` registers one supervised client per
  caller-chosen `ServerId`. Looked up via:
  - `barrel_mcp:start_client/2`
  - `barrel_mcp:stop_client/1`
  - `barrel_mcp:whereis_client/1`
  - `barrel_mcp:list_clients/0`
- Tool-name namespacing across servers is host policy and is not
  enforced by the library.

### Auth

- `barrel_mcp_client_auth` behaviour.
- `barrel_mcp_client_auth_bearer`: static token.
- `barrel_mcp_client_auth_oauth`: OAuth 2.1 + PKCE.
  - Discovery: `parse_www_authenticate/1`, `discover_protected_resource/1`
    (RFC 9728), `discover_authorization_server/1` (RFC 8414 with OpenID
    Connect fallback).
  - PKCE: `gen_code_verifier/0`, `code_challenge/1` (S256),
    `build_authorization_url/2`.
  - Token endpoint: `exchange_code/2`, `refresh_token/2`. Both attach
    the RFC 8707 `resource` parameter; confidential clients use HTTP
    Basic.
  - As an auth handle: when used through `auth => {oauth, Config}` on
    the client spec, the library attaches `Authorization: Bearer ...`
    on every request and runs the refresh-token grant on 401 if a
    `refresh_token` was supplied. The interactive authorization-code
    redirect stays a host concern.

### LLM provider bridge (`barrel_mcp_tool_format`)

Translates MCP tool maps to the shapes the major LLM provider
APIs expect, and translates a model's tool-call back into the
`(Name, Arguments)` pair `barrel_mcp_client:call_tool/4` consumes.

- `to_anthropic/1`, `to_openai/1` — MCP tool → provider tool.
- `from_anthropic_call/1`, `from_openai_call/1` — provider call →
  `{Name, Args}`. Accepts both parsed maps and JSON-string
  arguments (the OpenAI wire shape).

### Schema validation (`barrel_mcp_schema`)

Pure-Erlang JSON Schema subset validator hosts can use to pre-flight
LLM-generated tool args before calling the server. Covers `type`,
`properties`, `required`, `enum`, `items`, `oneOf`/`anyOf`/`allOf`,
`additionalProperties: false`, string `minLength`/`maxLength`/`pattern`,
number bounds, and array `minItems`/`maxItems`/`uniqueItems`.

```
case barrel_mcp_schema:validate(Args, ToolInputSchema) of
    ok -> barrel_mcp_client:call_tool(Pid, Name, Args);
    {error, Errors} -> reject(Errors)
end.
```

### Roadmap

- Periodic deadline timer for in-flight requests beyond the per-call
  timeout (today timeouts fire only when configured per-request).
- Client-side `Last-Event-ID` resume (server-side replay is shipped;
  client transport tracks the last id but does not yet replay on
  reconnect from its own state).
