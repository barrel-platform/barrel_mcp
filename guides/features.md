# barrel_mcp features

Tracks notable capabilities and the spec-conformance status of the
Erlang MCP library. See `CHANGELOG.md` for release-by-release detail.

## Server

- HTTP transport (`barrel_mcp_http`) — JSON-RPC over POST.
- Streamable HTTP transport (`barrel_mcp_http_stream`) — protocol
  `2025-03-26`. POST (JSON or SSE), GET (SSE), DELETE, OPTIONS.
- stdio transport (`barrel_mcp_stdio`).
- Tool / resource / prompt registries.
- Session management with `Mcp-Session-Id` and TTL.
- Authentication providers: bearer, API key, basic, custom.
- Server-to-client sampling (`sampling/createMessage`) and resource
  update notifications.

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
  `completion/complete`, `logging/setLevel`, `ping`.
- Pagination via `cursor` / `nextCursor` (single page by default;
  `want_cursor => true` to follow paging).
- Cancellation: `barrel_mcp_client:cancel/2` sends
  `notifications/cancelled` and unblocks the caller.
- Progress: callers may pass `progress_token` in `tools/call`.
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
- `barrel_mcp_client_auth_bearer` — static token.
- OAuth 2.1 + PKCE: planned for Phase D (Protected Resource Metadata
  discovery, RFC 8707 `resource` parameter).

### Roadmap

- Phase B: deeper notifications + ergonomics — logging stream,
  resources/list_changed callbacks, completion routing, schema
  validation against `inputSchema` (opt-in).
- Phase C: refined control plane — periodic `ping`, deadline timers,
  progress notification dispatch.
- Phase D: OAuth 2.1 + PKCE auth.
