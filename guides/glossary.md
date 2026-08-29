# Glossary

The words the code and the other guides use with a fixed meaning.
Read this when a term in a module header or a comment is unfamiliar;
each entry names the module that owns the concept, so you can go
from the word to the code.

- **AS (authorization server)**: the OAuth server that issues tokens
  for an MCP server. Found from the PRM, validated by
  `barrel_mcp_client_auth_oauth:discover_authorization_server/2`.
- **Challenge**: a 401 or 403 the client transport hands to its auth
  handle (`barrel_mcp_client_auth:challenge/2`) as a map with
  `status`, `www_authenticate`, `server_url`, `protocol_version` and
  `dpop_nonce`. The handle answers with a new token or refuses.
- **Channel**: the process a server-to-client request is written to.
  For a session it is the `sse_pid` (`barrel_mcp_session:channel/2`);
  for a request answered on its own response stream it is the
  request process.
- **CIMD (Client ID Metadata Document)**: an HTTPS URL used as the
  OAuth `client_id`, the document at that URL being the client's
  metadata. One of the three registration mechanisms in
  `barrel_mcp_client_auth_oauth`, with DCR and pre-registration.
- **Collector**: the process that owns a task's outcome once the
  request process has answered with a task handle. Spawned by
  `barrel_mcp_protocol:spawn_task_collector/3`, it monitors the
  worker and writes `finish`, `fail` or `cancel` into
  `barrel_mcp_tasks`.
- **DCR (Dynamic Client Registration)**: RFC 7591 registration at
  the AS, done by the OAuth handle when it has no client id and the
  AS advertises a registration endpoint.
- **DPoP**: RFC 9449 proof-of-possession. With `dpop => true` the
  OAuth handle signs a proof JWT for every token request and every
  MCP request, and sends `Authorization: DPoP <token>` once the AS
  issued a DPoP-bound token.
- **EMA (Enterprise-Managed Authorization)**: the token-exchange chain
  where an identity provider's token is exchanged (RFC 8693) for an
  assertion the AS accepts (RFC 7523). `{oauth_enterprise, Config}`.
- **Envelope**: one JSON-RPC 2.0 message as a map: a request, a
  response or a notification. `barrel_mcp_protocol` encodes and
  decodes envelopes; nothing else touches the wire shape.
- **Era**: which of the two protocol families a request belongs to.
  The **modern** era (2026-07-28 and later) is stateless: each
  request carries its version, capabilities and identity in `_meta`.
  The **legacy** or **handshake** era (2025-11-25 and earlier)
  establishes those with `initialize`. Defined by
  `barrel_mcp_version:era/1`, decided per request by
  `barrel_mcp_ctx:from_request/2`. See
  [Protocol Versions](protocol-versions.md).
- **Escalate**: what a modern tool call does when the tool has not
  answered inside the inline window: the request process creates a
  task, hands the worker to a collector and answers with the task
  handle (`barrel_mcp_task_relay:escalate/6`).
- **Federation**: several clients, one per remote server, under
  `barrel_mcp_client_sup`, addressed by server id through
  `barrel_mcp_clients`.
- **Handle (auth)**: the client-side auth state,
  `barrel_mcp_client_auth:t()`, wrapping a provider module
  (`barrel_mcp_client_auth_bearer`, `barrel_mcp_client_auth_oauth`)
  and its opaque state. Threaded through the transport, which calls
  it for headers, challenges and settlement.
- **Inline window**: how long a modern tool call waits for its
  worker before escalating to a task. `task_inline_ms` in the
  `barrel_mcp` application environment, default 100 ms
  (`barrel_mcp_task_relay:inline_ms/0`).
- **`input_required`**: the state of a task, or the `resultType` of
  a synchronous answer, when the tool asked the client a question
  and waits for the answer (`barrel_mcp_tasks:await_input/5`). See
  MRTR.
- **`Last-Event-ID`**: the header a client sends when it reopens an
  SSE stream, naming the last event it saw. The engine replays newer
  events from the session's replay buffer.
- **`_meta`**: the per-envelope metadata map. In the modern era it
  carries the protocol version, the client capabilities and the
  request identity; in both eras it carries progress tokens, task
  ids and subscription ids. Keys are `?MCP_META_*` in
  `include/barrel_mcp.hrl`.
- **MRTR (multi round-trip request)**: a request whose answer is a
  question back to the client (`resultType: "input_required"`) that
  the client repeats with the answer and the server's opaque
  `request_state`. The state is sealed by `barrel_mcp_request_state`
  so the server keeps nothing between rounds.
- **Plan**: what `barrel_mcp_protocol:handle/2` returns for a tool
  call, `{async, Plan}`: a map with the `spawn` closure that starts
  the worker, the request id, the timeout and the context. The
  transport drives it (`drive_async_plan/4` or the engine's own
  path) because only the transport knows how the answer is written.
- **Principal**: who a request is from, as the auth provider states
  it (`barrel_mcp_auth:principal/2`, `anonymous` under
  `barrel_mcp_auth_none`). Sessions, tasks and elicitations are owned
  by a principal. See [Authentication](authentication.md).
- **PRM (Protected Resource Metadata)**: RFC 9728, the document an
  MCP server publishes at `/.well-known/oauth-protected-resource`
  naming its authorization servers and scopes. Served by the engine
  from the `resource_metadata` option; fetched by the OAuth handle
  from a 401.
- **Relay**: the process a modern tool worker reports to while the
  request process decides between an inline answer and a task. It
  forwards to whichever process owns the outcome, and is redirected
  to the collector on escalation (`barrel_mcp_task_relay`).
- **Replay buffer**: the last `sse_buffer_max` events (default 256)
  a session's stream sent, kept in `#mcp_session.sse_buffer` for
  `Last-Event-ID`.
- **Request state**: the opaque, HMAC-sealed blob an MRTR carries
  between rounds (`barrel_mcp_request_state`).
- **Session**: the legacy-era state a client establishes with
  `initialize`: version, capabilities, principal, the SSE channel,
  the replay buffer, pending server-to-client requests, in-flight
  workers. One `#mcp_session{}` row in `barrel_mcp_session`,
  identified by `Mcp-Session-Id`. Modern requests have none.
- **Settled**: the auth handle callback the transport invokes when a
  request the handle authorized got a 2xx
  (`barrel_mcp_client_auth:settled/1`), so a handle can commit a new
  token.
- **Shell**: the one-child supervisor around each client in the
  federation (`barrel_mcp_client_shell`). It carries the client's
  restart budget so one failing server cannot exhaust the others.
- **Task**: a tool call that outlives its request. Created in
  `barrel_mcp_tasks`, polled with `tasks/get`, cancelled with
  `tasks/cancel`. Legacy clients read the result with `tasks/result`;
  modern ones get it inlined in `tasks/get`.
- **`taskSupport`**: what a tool declares about tasks: `forbidden`
  (default), `optional` or `required`. Set with the `task_support`
  option at registration, read by `barrel_mcp_registry:task_support/1`,
  advertised on `tools/list` in the modern era.
- **Worker**: the process running a tool handler. Spawned by
  `barrel_mcp_registry:run_tool/3` with a `reply_to` in its context,
  it sends one `{tool_result, ...}`, `{tool_error, ...}`,
  `{tool_failed, ...}` or `{tool_input_required, ...}` message and
  ends.
