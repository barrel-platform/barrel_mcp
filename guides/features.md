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
- Pagination via `cursor` / `nextCursor`. Single page by default
  (`want_cursor => true` to follow paging by hand). The sugar helpers
  `list_tools_all/1`, `list_resources_all/1`,
  `list_resource_templates_all/1`, `list_prompts_all/1` walk every
  page via `barrel_mcp_pagination:walk/1`.
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

- Resumable Streamable HTTP via `Last-Event-ID` (transport buffers
  the last id but does not yet replay missed events on reconnect).
- Periodic deadline timer for in-flight requests beyond the per-call
  timeout (today timeouts fire only when configured per-request).
