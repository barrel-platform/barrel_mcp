# Server Internals

How the server side of `barrel_mcp` is put together: which process
runs what, how a request travels from the socket to a tool handler
and back, and where the decisions that span several modules are
made. Read this before changing anything under `src/` on the server
side; the usage guides tell you how to call the library, this one
tells you how to modify it. The client side has its own page,
[Client Internals](internals.md), and the words used here are
defined in the [Glossary](glossary.md).

## 1. Module map

```erl
barrel_mcp                      public facade: register, start, stop
  |- barrel_mcp_registry        tools / resources / prompts, tool workers
  |- barrel_mcp_http_stream     Streamable HTTP listener config
  |- barrel_mcp_http            simple HTTP (POST only) listener config
  |- barrel_mcp_stdio           stdio transport (own process tree)
  `- barrel_mcp_listener_sup    one child per listener
       `- barrel_mcp_http_listener   h1/h2 acceptors, connections, request processes
            `- barrel_mcp_http_engine    HTTP verbs, sessions, SSE, auth, CORS, tool calls
                 `- barrel_mcp_protocol     JSON-RPC envelopes, era gating, method handlers
                      |- barrel_mcp_ctx            per-request context, era, _meta validation
                      |- barrel_mcp_registry       handler lookup and execution
                      |- barrel_mcp_session        legacy sessions, SSE channel, pending requests
                      |- barrel_mcp_tasks          task table and lifecycle
                      |- barrel_mcp_task_relay     inline-or-task hand-off (modern era)
                      |- barrel_mcp_subscriptions  subscriptions/listen filters
                      |- barrel_mcp_elicitation    URL-mode elicitation records
                      |- barrel_mcp_request_state  MRTR sealed state
                      |- barrel_mcp_headers        x-mcp-* header mirroring
                      |- barrel_mcp_pagination     cursors for */list
                      `- barrel_mcp_jsonschema     input/output schema validation
barrel_mcp_auth + barrel_mcp_auth_*   server auth providers (bearer, apikey, basic, custom, none)
barrel_mcp_version                   the revision registry and the era function
```

`barrel_mcp_stdio` calls `barrel_mcp_protocol` directly and never
goes through the engine. The legacy 2024-11-05 HTTP+SSE pair lives
inside the engine (section 4.6).

## 2. Supervision tree

`barrel_mcp_app:start/2` seeds the MRTR signing key
(`barrel_mcp_request_state:ensure_key/0`, a `persistent_term`) and
starts `barrel_mcp_sup`.

```erl
barrel_mcp_sup                   one_for_one, 5 restarts / 10 s
  |- barrel_mcp_registry         gen_statem, permanent
  |- barrel_mcp_session          gen_server, permanent
  |- barrel_mcp_subscriptions    gen_server, permanent
  |- barrel_mcp_elicitation      gen_server, permanent
  |- barrel_mcp_listener_sup     supervisor, one_for_one, 3 / 60 s, no static children
  |    `- <listener name>        barrel_mcp_http_listener, transient, added at start_http_stream/start_http
  |- barrel_mcp_tasks            gen_server, permanent
  `- barrel_mcp_client_sup       supervisor (client side, see Client Internals)
```

Listener names are `barrel_mcp_http_stream_listener` and
`barrel_mcp_http_simple_listener`. When `barrel_mcp_listener_sup` is
not running (the library embedded without its application), the
listener is started unsupervised by `barrel_mcp_listener_sup:supervised_start/3`'s
fallback.

`barrel_mcp_stdio` is not under the tree: `start/0` runs it
unregistered and blocks the caller until it exits, `start_link/0`
registers it as `barrel_mcp_stdio` for a host supervisor.

### The listener

`barrel_mcp_http_listener` is a `proc_lib` process that traps exits.
On start it opens the socket, registers under its name, and spawns
`acceptors` linked acceptor processes (default `max(2, schedulers)`)
kept in a map. An acceptor that exits abnormally is logged and
replaced after `?ACCEPT_ERROR_BACKOFF` (50 ms); `acceptors/1` lists
the live pool.

Each accepted socket gets a connection process (`spawn`, then the
connection links itself to the listener), counted against
`max_connections` (default 16384) through an atomics counter that a
monitor releases on exit. The connection negotiates h1 or h2 and
spawns one request process per request with
`spawn_opt([link, monitor])` (`spawn_handler/7`): h1 serves requests
one at a time, h2 one process per stream. A request process that
crashes is answered 500 by the connection, except for `shutdown`,
`{shutdown, _}` and `{noproc, {gen_statem, call, _}}`, which are a
peer that went away.

When the listener stops it closes the socket and exits `shutdown`,
which reaches every connection and request over the links.

## 3. Process model of a request

`barrel_mcp_http_engine:handle/6` runs in the request process. What
it spawns during a `tools/call`:

| process | spawned by | primitive | reports to | ends |
| --- | --- | --- | --- | --- |
| tool worker | `barrel_mcp_registry:run_tool/3` | `spawn` (no link) | `reply_to` in its Ctx: `{tool_result, ...}`, `{tool_error, ...}`, `{tool_failed, ...}`, `{tool_input_required, ...}` | after one message; killed on disconnect (`settle_disconnect/2`) or when a task cannot be created |
| task relay | `barrel_mcp_task_relay:start/0` | `spawn_link` from the request process | its `target`: the request process, then the collector | `stop`, or the worker's `DOWN` once forwarded; unlinked before escalation |
| task collector | `barrel_mcp_protocol:spawn_task_collector/3` | `spawn` | `barrel_mcp_tasks` (`finish`, `fail`, `cancel`) | first terminal message; monitors the worker; `?WORKER_HANDOFF_MS` without a worker fails the task |
| legacy-SSE driver | `barrel_mcp_http_engine:legacy_answer/3` | `spawn` | `push_legacy/2` onto the session's stream | when `drive_async_plan/4` returns |
| stream watcher | `answer_on_stream/3` | `spawn_link` | kills the worker if the SSE stream dies | `done` |

Under stdio the coordinator runs each request in a `spawn_monitor`
worker (at most `?DEFAULT_MAX_WORKERS`, 8; queue of 64), and that
worker drives the plan itself, so the tool worker's `reply_to` is the
stdio worker, or a relay it creates. The reader process sends one
frame and waits for `stdio_ack` before reading the next; the writer
serialises `io:format` calls. Either one exiting stops the
coordinator.

## 4. Request lifecycle per verb

Function names are the hops; every one is in
`src/barrel_mcp_http_engine.erl` unless a module is given.

### 4.1 Any request

1. `handle/6`: strip the query; serve
   `/.well-known/oauth-protected-resource` when `resource_metadata`
   is configured; `validate_origin/2` (403 on failure).
2. `route/7`: the 2024-11-05 pair's paths (`sse_path`,
   `sse_message_path`) go to section 4.6; everything else to
   `dispatch/6` keyed on the engine `mode` (`stream` or `simple`)
   and the verb.

### 4.2 Streamable POST, modern era

1. `stream_post/4`: `Accept` check (406), authentication
   (`with_auth_info/4`), body decode; a batch goes to
   `stream_post_batch/6`.
2. `stream_post_request/6`: a JSON-RPC response goes to
   `handle_inbound_response/6`; otherwise the era fork:
   `barrel_mcp_ctx:era(barrel_mcp_ctx:from_request(Request, Extra))`.
3. `handle_modern_request/6`: `validate_metadata_headers/2` (the
   `Mcp-*` headers must agree with the body, else 400
   `?MCP_HEADER_MISMATCH`).
4. `dispatch_modern_request/6`: `barrel_mcp_protocol:handle/2` with
   `auth_info`, `streaming => true`, `transport_version`. No session
   is looked up or minted.
5. In the protocol: `handle/2` → `dispatch/4` (`serves/2`: does this
   era have the method) → `dispatch_versioned/4`
   (`barrel_mcp_ctx:validate_version/1`, `check_version/1`) →
   `dispatch_valid/4` (`barrel_mcp_ctx:validate/1`, then
   `handle_request/4`, `with_cache_hints/3`, `finalize/2`).
6. `handle_request(<<"tools/call">>, ...)` → `tool_call_plan/4`
   returns `{async, Plan}`.
7. Back in the engine, `dispatch_modern_request/6` matches
   `{async, Plan}` → `handle_async_tool_call/7`, which computes the
   mode (section 5), spawns the worker with `reply_to =>
   reply_target(Relay, self())`, then `wait_for_tool/4` (inline) or
   `wait_inline_or_escalate/6` (escalate).
8. The answer is a JSON body, or an SSE response stream when the
   client's `Accept` asks for one (`stream_sse_response/5`). A
   `{subscribe, Sub}` return opens a subscription stream
   (`handle_subscription/4`, `subscription_loop/3`).

### 4.3 Streamable POST, legacy era

Steps 1 and 2 as above, then:

3. `handle_inbound_request/6` → `lookup_session/5`: `initialize`
   without a header mints a session and records the principal; any
   other request must name a session the same principal owns
   (`owned_session/2`), else 404.
4. `handle_dispatch/6`: `validate_protocol_version/3`, activity
   update, `barrel_mcp_protocol:handle/2` with `session_id`.
5. Same protocol path as 4.2 step 5; `initialize/3` records the
   negotiated version and capabilities on the session.
6. `{async, Plan}` → `handle_async_tool_call/7`; the legacy mode is
   `task` (immediate task, `handle_long_running_call/10`) or
   `inline`; the worker is recorded in the session's in-flight table
   so a `notifications/cancelled` or a DELETE can kill it.
7. The answer goes back on the POST's own SSE stream
   (`stream_sse_response/5`); server-to-client requests raised while
   it runs go on the same stream when the client has no standalone
   GET open, else on the GET.

### 4.4 GET (standalone stream, legacy era only)

`dispatch/6` answers 405 when sessions are off. Otherwise
`stream_get_sse/3` → `stream_get_sse_authed/4` (header required, 400)
→ `stream_get_sse_session/5` (`owned_session/2`, 404) →
`replay_sse_events/3` for `Last-Event-ID` → `set_sse_pid` → `sse_loop/2`
until `session_terminated`, `mcp_disconnect` or a failed write, then
`sse_cleanup/2`.

### 4.5 DELETE

`stream_delete/3` → `stream_delete_authed/4` → `owned_session/2` →
`barrel_mcp_session:delete/1` (204). Deleting a session fails its
pending server-to-client requests and signals its SSE loop.

### 4.6 The 2024-11-05 HTTP+SSE pair

`legacy_sse_open/3`: mint a session bound to the principal, start the
stream, send the `endpoint` event carrying the session id, `sse_loop/2`;
the session is deleted when the loop ends. `legacy_sse_post/5`:
`legacy_session_of/2` checks the `sessionId` query parameter against
the principal (404 either way), `legacy_dispatch/6` handles the
message, the answer is pushed onto the stream and the POST gets 202.
An `{async, Plan}` here is driven by a spawned driver
(`legacy_answer/3`, `answer_on_stream/3`).

### 4.7 stdio

`barrel_mcp_stdio` classifies each frame (`Classification` section),
queues or starts a worker (`start_worker/3`), and the worker calls
`barrel_mcp_protocol:handle/2` then `settle_result/2`, which drives an
`{async, Plan}` with `barrel_mcp_protocol:drive_async_plan/4`. The
mode decision for stdio is therefore the protocol's (section 5).

## 5. Tool-call modes

A registered tool declares `task_support` (`forbidden` by default,
`optional`, `required`; `long_running => true` is the old spelling of
`optional`). Whether a call becomes a task depends on that, on
whether the client declared the tasks extension, and on the era:

| `task_support` | extension declared | era | mode |
| --- | --- | --- | --- |
| `forbidden` | any | any | `inline`: run to completion, answer in place |
| `optional` | no | any | `inline` |
| `required` | no | any | `refuse`: `-32021` naming the extension |
| `optional` or `required` | yes | legacy | `task`: create the task first, answer with the handle |
| `optional` or `required` | yes | modern | `escalate`: run inline for `task_inline_ms`, then task |

The rule is written twice, on purpose in two shapes:

- HTTP, `barrel_mcp_http_engine:handle_async_tool_call/7`: the
  five-clause `case {Support, Enabled}` with the `when Modern` guard,
  because the engine writes the answer itself.
- Every other transport, `barrel_mcp_protocol:task_plan/2` consumed
  by `drive_async_plan/4`, which picks `drive_inline_then_task/5`
  (modern) or `drive_as_task/4` (legacy).

Change one and change the other; `barrel_mcp_tasks_tests` pins both.

### The relay

In `escalate` mode the worker does not report to the request process
but to a relay, so the outcome can be handed to a task after the
window without a race:

1. Request process: `Relay = barrel_mcp_task_relay:start()` (linked),
   spawn the worker with `reply_to => Relay`, `worker(Relay, Pid)`.
2. Relay forwards every worker message to its owner while the owner
   waits `inline_ms()`.
3. Outcome inside the window: `stop(Relay)`, answer in place.
4. Window over: `hold(Relay)`; the relay acknowledges with
   `relay_held` and starts holding messages. A relay that already
   ended counts as held (its forwarded messages are in the mailbox),
   so the owner re-checks its mailbox with a zero timeout.
5. Still nothing: `unlink(Relay)`, `escalate/6` creates the task
   (`barrel_mcp_tasks:create/3`, before the response is written, so
   `tasks/get` resolves at once), spawns a collector, sends
   `{redirect, Collector}`; the relay replays what it held to the
   collector and forwards from then on. The answer is the
   `CreateTaskResult` for the era.
6. The relay exits when the worker is down and everything is
   forwarded; a worker gone before it was watched (`noproc`) counts
   as normal.

## 6. Session

One `#mcp_session{}` row per legacy session in the
`barrel_mcp_sessions` table, created at three sites: `lookup_session/5`
on `initialize` (Streamable), `legacy_sse_open/3` (2024-11-05 pair),
`barrel_mcp_stdio:init/1` (one per stdio process).

| field | written by |
| --- | --- |
| `id`, `created_at`, `client_info` | `create/1` |
| `last_activity` | `handle_dispatch/6` on every legacy request |
| `client_capabilities` | `barrel_mcp_protocol:initialize/3` |
| `protocol_version` | `initialize/3`; `remember_version/2` and `maybe_capture_initialize_version/3` in the engine |
| `sse_pid` | `stream_get_sse_session/5`, `sse_cleanup/2`, `legacy_sse_open/3`, `barrel_mcp_stdio:bind_session/2` (legacy era only) |
| `sse_buffer`, `sse_buffer_max` | `record_sse_event` from the engine's SSE helpers; the max from `lookup_session/5` (`sse_buffer_size`, default 256) |
| `log_level` | `logging/setLevel` handler |
| `principal` | `lookup_session/5`, `legacy_sse_open/3` |

Beside the row, `barrel_mcp_session` keeps three more tables keyed by
session: resource subscriptions, pending server-to-client requests
(`#pending{}`, matched on `{SessionId, Id}` at delivery), and
in-flight tool workers (`{SessionId, RequestId}` → worker and
waiter). `delete/1` fails the pending rows, kills the in-flight
workers and signals the SSE loop. Expired sessions are swept on a
timer.

Ownership: a session belongs to the principal that initialized it.
`owned_session/2` answers `unknown_session` for another principal,
which every verb reports as the 404 an unknown id gets.

## 7. Registered processes and tables

| table | owner | options | key → value |
| --- | --- | --- | --- |
| `barrel_mcp_registry_table` | `barrel_mcp_registry` | public, set | `{Type, Name}` → handler map |
| `barrel_mcp_sessions` | `barrel_mcp_session` | protected | `SessionId` → `#mcp_session{}` |
| `barrel_mcp_resource_subs` | `barrel_mcp_session` | protected | `{SessionId, Uri}` |
| `barrel_mcp_pending_requests` | `barrel_mcp_session` | protected | `RequestId` → `#pending{}` |
| `barrel_mcp_inflight` | `barrel_mcp_session` | protected | `{SessionId, RequestId}` → `#in_flight{}` |
| `barrel_mcp_subscriptions_table` | `barrel_mcp_subscriptions` | protected | `{Pid, SubId}` → filter |
| `barrel_mcp_elicitations` | `barrel_mcp_elicitation` | protected | `Id` → `#elicitation{}` |
| `barrel_mcp_tasks_table` | `barrel_mcp_tasks` | protected | `TaskId` → `#task{}` |

Protected tables are read directly by request processes and written
only through their owner's `gen_server` calls; that is why the
`barrel_mcp_session` API is a long list of small calls.

`persistent_term` holds the registry snapshot (`{Handlers,
ParamHeaders}`, rebuilt on every registration), the MRTR signing key,
the dummy hash `barrel_mcp_auth_basic` compares against for unknown
users, and the JSON Schema metaschema.

Registered names: the four gen_servers and the registry above,
`barrel_mcp_sup`, `barrel_mcp_listener_sup`, `barrel_mcp_client_sup`,
each listener under its name, and `barrel_mcp_stdio` when started
with `start_link/0`.

## 8. Where to look

| want to read | file |
| --- | --- |
| HTTP verbs, sessions on the wire, SSE, CORS, Origin | `src/barrel_mcp_http_engine.erl` |
| JSON-RPC envelopes, era gating, one handler per method | `src/barrel_mcp_protocol.erl` |
| Per-request context and `_meta` validation | `src/barrel_mcp_ctx.erl` |
| Tool / resource / prompt registration and workers | `src/barrel_mcp_registry.erl` |
| Session rows, pending requests, in-flight workers | `src/barrel_mcp_session.erl` |
| Task table, TTL, `input_required` | `src/barrel_mcp_tasks.erl` |
| Inline-or-task hand-off | `src/barrel_mcp_task_relay.erl` |
| Acceptors, connections, h1/h2 | `src/barrel_mcp_http_listener.erl` |
| stdio framing and worker pool | `src/barrel_mcp_stdio.erl` |
| Server auth providers and principals | `src/barrel_mcp_auth.erl`, `src/barrel_mcp_auth_*.erl` |
| Revisions and the era function | `src/barrel_mcp_version.erl`, `include/barrel_mcp.hrl` |

Tests are grouped by feature, not by module. The ones that pin each
area:

| area | tests |
| --- | --- |
| tool-call modes, tasks, MRTR | `test/barrel_mcp_tasks_tests.erl`, `test/barrel_mcp_mrtr_SUITE.erl`, `test/barrel_mcp_async_tools_SUITE.erl` |
| relay | `test/barrel_mcp_task_relay_tests.erl` |
| envelopes, dispatch, initialize | `test/barrel_mcp_protocol_tests.erl`, `test/barrel_mcp_protocol_envelope_tests.erl` |
| eras on one listener | `test/barrel_mcp_dual_era_SUITE.erl` |
| session ownership, Origin, headers, response codes | `test/barrel_mcp_http_stream_security_SUITE.erl` |
| cancellation, replay, spec additions | `test/barrel_mcp_spec_additives_SUITE.erl` |
| subscriptions | `test/barrel_mcp_subscriptions_SUITE.erl` |
| listener and embedding | `test/barrel_mcp_http_engine_embed_tests.erl`, `test/barrel_mcp_http_stream_tests.erl` |
| auth providers, principals | `test/barrel_mcp_auth_tests.erl`, `test/barrel_mcp_principal_tests.erl` |
| stdio | `test/barrel_mcp_stdio_SUITE.erl` |
| the official runner, both modes | `test/barrel_mcp_conformance_SUITE.erl` |
| the Python SDK, both eras | `test/barrel_mcp_python_interop_SUITE.erl` |
