# Internals

How `barrel_mcp` is wired on the client side. Read this if you are
extending the library, debugging a stuck connection, or generating
code that introspects the architecture.

This file is paired with [Building a client](building-a-client.md);
the building guide is task-oriented, this one is structural.

## 1. Module map

| Module | Role |
| --- | --- |
| `barrel_mcp` | Top-level façade. `start_client/2`, `notify_resource_updated/1,2`, `sampling_create_message/3`, etc. |
| `barrel_mcp_client` | The client `gen_statem`. Owns one connection. |
| `barrel_mcp_client_sup` | Supervises client workers (transient). |
| `barrel_mcp_clients` | Federation registry: `ServerId → pid()`. |
| `barrel_mcp_client_transport` | Behaviour: `connect/2`, `send/2`, `close/1`. |
| `barrel_mcp_client_stdio` | Transport impl over `open_port/2`. |
| `barrel_mcp_client_http` | Transport impl over Streamable HTTP (POST + SSE GET). |
| `barrel_mcp_client_handler` | Behaviour for server-initiated requests and notifications. |
| `barrel_mcp_client_handler_default` | No-op default handler. |
| `barrel_mcp_client_auth` | Behaviour: `init/1`, `header/1`, `refresh/2`. |
| `barrel_mcp_client_auth_bearer` | Static-token impl. |
| `barrel_mcp_client_auth_oauth` | OAuth 2.1 + PKCE impl + discovery helpers. |
| `barrel_mcp_protocol` | JSON-RPC envelope codec; shared with the server. |
| `barrel_mcp_pagination` | Cursor walker for `*/list` requests. |
| `barrel_mcp_schema` | JSON Schema subset validator. |

## 2. Supervision tree

```
barrel_mcp_sup (one_for_one)
├── barrel_mcp_registry      -- server-side registry of tools/resources/prompts
├── barrel_mcp_session       -- server-side session manager
├── barrel_mcp_client_sup    -- one_for_one of barrel_mcp_client workers
│   ├── client(<<"server-1">>)
│   └── client(<<"server-2">>)
└── barrel_mcp_clients       -- registry: ServerId -> pid + monitor
```

`barrel_mcp_clients` is a `gen_server` that owns the lookup table
and serializes registration so two callers can't race on the same
`ServerId`. Lookups (`whereis_client/1`, `list_clients/0`) hit the
ETS table directly without crossing the process boundary.

## 3. Client state machine

`barrel_mcp_client` is a `gen_statem` in `state_functions` mode.

```
                         start_link/1
                              │
                              ▼
                       ┌────────────┐
                       │ connecting │  open transport, send `initialize'
                       └─────┬──────┘
                             │ transport up
                             ▼
                       ┌──────────────┐
                       │ initializing │  state-timeout = init_timeout
                       └─────┬────────┘
                             │ initialize response (negotiated version)
                             │ + notifications/initialized
                             │ + open SSE GET (HTTP only)
                             ▼
                       ┌────────┐
                       │ ready  │◀──── all client API calls go here
                       └─┬──┬───┘
                         │  │
              close/1 ───┘  └─── transport_closed | ping_failed
                              ▼
                       ┌─────────┐
                       │ closing │
                       └─────────┘
```

State transitions:

- `connecting → initializing` — internal event after `open_transport/1`.
- `initializing → ready` — successful `initialize` response, version in
  `?MCP_CLIENT_SUPPORTED_VERSIONS`.
- `initializing → stop {init_failed, _}` — server returned a JSON-RPC
  error to `initialize` or omitted `protocolVersion`.
- `ready → closing` — caller cast `close`, or stop on `mcp_closed`,
  or stop with `ping_failed`.

## 4. Inbound message flow

```
transport process (stdio port owner | http gen_server)
        │
        │  {mcp_in, TransportPid, Json}
        ▼
barrel_mcp_client gen_statem (info handler)
        │
        ├── decode_envelope/1 -> request | response | notification | error
        │
        ├── response/error  -> ETS pending lookup -> gen_statem:reply(Caller, _)
        ├── request         -> handler:handle_request/3 -> send response
        └── notification    -> handler:handle_notification/3
                               (+ subscriber routing for resources/updated)
                               (+ progress routing for notifications/progress)
```

The transport process owns the wire — socket, port, SSE buffer — and
forwards one JSON-RPC envelope per `{mcp_in, _, _}` message. The
gen_statem never reads the wire directly. This means transports can
implement framing however suits them (line-delimited for stdio,
SSE-event-delimited for HTTP) without leaking that into the state
machine.

When the transport ends, it sends `{mcp_closed, TransportPid, Reason}`
and the gen_statem stops with that reason.

## 5. Outbound flow

```
caller                              barrel_mcp_client gen_statem
   │                                          │
   │ gen_statem:call({request, M, P, T})      │
   ├─────────────────────────────────────────►│
   │                                          ├─ next_id/1
   │                                          ├─ pending#{Id => #pending{...}}
   │                                          ├─ encode_request/3
   │                                          └─ transport:send/2
   │                                          ▼
   │                                   transport process
   │                                          │
   │                                          ▼
   │                                   ... server ...
   │                                          │
   │                                          ▼
   │                                   {mcp_in, _, ResponseJson}
   │                                          │
   │                                  match by id, gen_statem:reply
   │◀─────────────────────────────────────────│
```

`pending` is a map keyed by request id. Each entry tracks the caller
`{From}`, the method name, the deadline, and the optional progress
token. The state machine drops the entry on settle and clears any
matching state-timeout.

## 6. Behaviour contracts

### `barrel_mcp_client_transport`

```
-callback connect(Owner :: pid(), Opts :: map()) ->
    {ok, pid()} | {error, term()}.
-callback send(TransportPid :: pid(), JsonBinary :: iodata()) ->
    ok | {error, term()}.
-callback close(TransportPid :: pid()) -> ok.
```

The transport process MUST emit `{mcp_in, TransportPid, JsonBinary}`
to `Owner` for every complete inbound JSON-RPC envelope. On
shutdown — peer disconnect, port exit, fatal error — it MUST emit
`{mcp_closed, TransportPid, Reason}` exactly once.

### `barrel_mcp_client_handler`

```
-callback init(Args :: term()) -> {ok, state()} | {error, term()}.
-callback handle_request(Method :: binary(),
                         Params :: map(),
                         State :: state()) ->
    {reply, Result :: term(), state()} |
    {error, Code :: integer(), Message :: binary(), state()} |
    {async, Tag :: term(), state()}.
-callback handle_notification(Method :: binary(),
                              Params :: map(),
                              State :: state()) -> {ok, state()}.
-callback terminate(Reason :: term(), State :: state()) -> any().
```

The default handler (`barrel_mcp_client_handler_default`) returns
`method_not_found` for every request and ignores every notification.
Hosts only implement what they declare in their `capabilities`.

The `{async, Tag, State}` reply form lets a handler defer the
response while the state machine continues to process other inbound
traffic. The host posts the actual reply via
`barrel_mcp_client:reply_async/3`.

### `barrel_mcp_client_auth`

```
-callback init(Config :: term()) -> {ok, handle()} | {error, term()}.
-callback header(handle()) -> {ok, binary()} | none | {error, term()}.
-callback refresh(handle(), WwwAuthenticate :: binary() | undefined) ->
    {ok, handle()} | {error, term()}.
```

The HTTP transport calls `header/1` on every outgoing request. On a
401 it calls `refresh/2` once with the `WWW-Authenticate` header
value, then retries the original request with the new handle. The
caller-facing constructor is `barrel_mcp_client_auth:new/1` which
wraps the chosen impl as `{Module, State}` (or `none` for no auth).

## 7. State record fields

| Field | Type | Holds |
| --- | --- | --- |
| `spec` | map | The connect spec passed to `start_link/1`. |
| `transport` | `{Mod, Pid}` | Active transport. |
| `request_id` | int | Monotonic counter for outbound JSON-RPC ids. |
| `pending` | map | `Id ⇒ #pending{caller, method, deadline, progress_token}`. |
| `handler_mod` | atom | The host's handler module. |
| `handler_state` | term | The handler's per-instance state. |
| `async_replies` | map | `Tag ⇒ Id` for `{async, Tag, _}` requests. |
| `subscriptions` | map | `Uri ⇒ [pid()]` for `notifications/resources/updated`. |
| `progress` | map | `Token ⇒ pid()` for `notifications/progress`. |
| `ping_failures` | int | Consecutive ping errors; resets on success. |
| `server_capabilities` | map | What the server advertised at init. |
| `server_info` | map | `name`, `version` from the server. |
| `protocol_version` | binary | Negotiated version, after init. |

## 8. Wire format reference

### Streamable HTTP

Headers attached on every outgoing request:

| Header | When | Notes |
| --- | --- | --- |
| `content-type: application/json` | always | request body is a JSON-RPC envelope (or empty for GET). |
| `accept: application/json, text/event-stream` | always | the server may answer with either. |
| `mcp-session-id: <id>` | after the initialize POST returns one | echoed on every subsequent POST/GET/DELETE. |
| `mcp-protocol-version: <version>` | after init completes | the negotiated version. |
| `authorization: Bearer ...` | when an auth handle attaches one | bearer or OAuth-fronted. |
| `last-event-id: <id>` | reconnecting the GET SSE | not yet a full replay path; tracked but not yet replayed. |

The POST endpoint may answer with a JSON envelope or with an SSE
stream. The transport classifies on `content-type` and either
forwards the single envelope or parses SSE events until the matching
`done`. SSE event format:

```
id: <id>
event: <name>
data: <JSON-RPC envelope>
\n
```

The transport ignores `event:`, captures `id:` for resumability, and
forwards each `data:` payload as one `mcp_in` message.

The GET endpoint opens a long-lived SSE for unsolicited
server-to-client traffic. A 405 here means the server doesn't support
unsolicited streams; the client silently drops the GET and only
receives server-initiated requests interleaved on POST responses.

DELETE on close, with `Mcp-Session-Id`.

### stdio

Line-delimited JSON-RPC. One envelope per line. The transport reads
up to a 1 MiB line limit (configurable in
`barrel_mcp_client_stdio`). Anything larger fails framing with
`{mcp_closed, _, line_too_long}`.

stdin and stdout are the only channels. stderr from the subprocess is
discarded by default; redirect it in your launcher if you need it.

## 9. Where to look in the source

| Want to read | File |
| --- | --- |
| State machine + public API | `src/barrel_mcp_client.erl` |
| Streamable HTTP transport | `src/barrel_mcp_client_http.erl` |
| stdio transport | `src/barrel_mcp_client_stdio.erl` |
| Handler behaviour + default | `src/barrel_mcp_client_handler.erl`, `src/barrel_mcp_client_handler_default.erl` |
| OAuth flow | `src/barrel_mcp_client_auth_oauth.erl` |
| Federation | `src/barrel_mcp_clients.erl`, `src/barrel_mcp_client_sup.erl` |
| Pagination walker | `src/barrel_mcp_pagination.erl` |
| Schema validator | `src/barrel_mcp_schema.erl` |
| Wire envelope codec | `src/barrel_mcp_protocol.erl` |
