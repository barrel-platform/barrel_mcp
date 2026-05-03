# Building an MCP Client with `barrel_mcp`

`barrel_mcp` is a pure MCP library. It implements the wire protocol,
the transports, and the client state machine. It does **not** call
LLM providers, build prompts, or run an agent loop — those belong to
the host application that uses this library.

This guide is task-oriented. Each section answers "I want to do X"
with a working snippet, notes, and a pointer to the spec or wire
detail. Snippets tagged `` ```erlang `` are extracted from this file
and compile-checked in CI; snippets tagged `` ```erl `` are
illustrative output only.

If you have not yet read [the architecture](internals.md), the short
summary is: a `barrel_mcp_client` is a `gen_statem` that owns one
connection to one MCP server. It dispatches inbound responses to
waiting callers, server-initiated requests to a host-supplied handler
module, and notifications to either subscribers or the same handler.

---

## 1. What `barrel_mcp` gives you, and what it doesn't

It gives you:

- Streamable HTTP and stdio transports.
- A spec-conformant MCP client (`barrel_mcp_client`).
- Server-to-client request dispatch via the
  [`barrel_mcp_client_handler`](#10-handle-server-initiated-requests)
  behaviour.
- OAuth 2.1 + PKCE primitives (RFC 9728, RFC 8414, RFC 8707) and a
  refresh-only auth handle.
- A federation registry (`barrel_mcp_clients`) for hosting many MCP
  connections in one app.
- A JSON Schema subset validator (`barrel_mcp_schema`).

It does not give you:

- LLM provider HTTP (Anthropic, OpenAI, Hermes, etc.). Implement that
  in your host application.
- An agent loop. Drive your own multi-turn loop using the building
  blocks below.
- Tool-name namespacing across servers. That's host policy.
- A browser-based redirect listener for OAuth. Hosts run that step
  with whatever UI fits their environment.

---

## 2. Choose a transport

| Transport | Use it when | Where it lives |
| --- | --- | --- |
| Streamable HTTP | The server is remote or runs as a long-lived service. You want session resumption and server-initiated requests over SSE. | `barrel_mcp_client_http` |
| stdio | The server is a local subprocess (CLI tools, native MCP servers shipped as binaries). | `barrel_mcp_client_stdio` |

In both cases the high-level API on `barrel_mcp_client` is identical.
The transport tuple in the connect spec is the only difference:

```erl
%% Streamable HTTP
#{transport => {http, <<"https://server.example/mcp">>}}

%% stdio
#{transport => {stdio, #{command => "/usr/local/bin/mcp-server",
                         args => ["--quiet"]}}}
```

---

## 3. Connect spec reference

`barrel_mcp_client:start_link/1` and `start/1` accept a single map.
Every key is documented below.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `transport` | `{http, Url}` \| `{stdio, #{command, args}}` | required | Which transport to open. |
| `client_info` | `#{name, version}` | `#{name => <<"barrel_mcp_client">>, version => <<"2.0.0">>}` | Sent in `initialize`. |
| `capabilities` | map | `#{}` | Client capabilities to declare. Booleans become spec-shape objects on the wire (e.g. `#{sampling => true}` becomes `#{<<"sampling">> => #{}}`). |
| `handler` | `{Mod, Args}` | `{barrel_mcp_client_handler_default, []}` | Module implementing `barrel_mcp_client_handler` to handle server-initiated requests and notifications. |
| `auth` | `none` \| `{bearer, Token}` \| `{oauth, Config}` | `none` | Authentication. See section 14. |
| `protocol_version` | binary | `?MCP_CLIENT_PROTOCOL_VERSION` (`<<"2025-11-25">>`) | Target protocol version. The client negotiates downward if the server reports an older one. |
| `request_timeout` | pos_integer | `30000` | Default per-request timeout in ms. |
| `init_timeout` | pos_integer | `30000` | Time allowed for the `initialize` round-trip. |
| `ping_interval` | pos_integer \| `infinity` | `infinity` | If set, the client sends `ping` every N ms while in `ready`. |
| `ping_failure_threshold` | pos_integer | `3` | Consecutive ping failures before the connection is closed with reason `ping_failed`. |

---

## 4. Connect and close

```erl
{ok, Client} = barrel_mcp_client:start_link(#{
    transport => {http, <<"http://127.0.0.1:9090/mcp">>}
}),
%% ... use Client ...
ok = barrel_mcp_client:close(Client).
```

`start_link/1` links the calling process to the client. Use `start/1`
for unsupervised one-offs (tests, scripts).

The state machine moves `connecting → initializing → ready`. Calls
made before `ready` return `{error, not_ready}`. Wait for the first
`server_capabilities/1` to succeed if you need to gate work on
readiness:

```erlang
wait_ready(Pid, 0) -> {error, not_ready};
wait_ready(Pid, N) ->
    case catch barrel_mcp_client:server_capabilities(Pid) of
        {ok, _} -> ok;
        _ ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.
```

---

## 5. Capability negotiation and version downgrade

The client declares what it can answer (sampling, roots, elicitation)
and the server replies with what it can serve (tools, resources,
prompts, logging, completions). After the handshake:

```erlang
get_caps(Pid) ->
    {ok, ServerCaps} = barrel_mcp_client:server_capabilities(Pid),
    case maps:is_key(<<"tools">>, ServerCaps) of
        true -> ok;
        false -> {error, no_tools}
    end.
```

Version is negotiated automatically. The client sends
`?MCP_CLIENT_PROTOCOL_VERSION` (`<<"2025-11-25">>` today); if the
server replies with an older version (e.g. `2025-03-26`), the client
adopts that and uses it on every subsequent `MCP-Protocol-Version`
header. Read it back with `barrel_mcp_client:protocol_version/1`.

---

## 6. List tools, resources, and prompts

Single-page calls return one chunk:

```erlang
list_one_page(Pid) ->
    {ok, Tools} = barrel_mcp_client:list_tools(Pid),
    Tools.
```

Pagination is opt-in. Pass `#{want_cursor => true}` to receive
`{ok, Items, NextCursor | undefined}`. If the server has more pages
than you want to walk by hand, use the `*_all` helpers:

```erlang
list_every_tool(Pid) ->
    {ok, AllTools} = barrel_mcp_client:list_tools_all(Pid),
    AllTools.
```

The same shape applies to `list_resources/1,2`,
`list_resource_templates/1,2`, and `list_prompts/1,2`.

---

## 7. Call a tool

```erlang
call_echo(Pid) ->
    barrel_mcp_client:call_tool(Pid, <<"echo">>, #{<<"text">> => <<"hi">>}).
```

`call_tool/4` accepts an option map:

```erlang
call_with_progress(Pid, Token) ->
    barrel_mcp_client:call_tool(
        Pid,
        <<"slow">>,
        #{<<"size">> => 1000},
        #{progress_token => Token, timeout => 60000}).
```

When `progress_token` is supplied, the calling process receives one
`{mcp_progress, Token, Params}` message per `notifications/progress`
the server emits, until the request settles (response, cancel, or
timeout).

The full echo-client example lives in
[`examples/echo_client/src/echo_client.erl`](https://github.com/barrel-platform/barrel_mcp/tree/main/examples/echo_client/src/echo_client.erl).

### Tool results

`call_tool/3,4` returns the server's `result` map. Three shapes
the spec allows:

```erlang
classify(#{<<"isError">> := true} = R) ->
    {error, maps:get(<<"content">>, R)};
classify(#{<<"structuredContent">> := Data} = R) ->
    {structured, Data, maps:get(<<"content">>, R, [])};
classify(#{<<"content">> := Content}) ->
    {ok, Content}.
```

- `isError: true` → the tool reported a domain-level failure
  (validation, business rule). The `content` is human-readable.
- `structuredContent` → typed payload, optionally paired with
  human-readable `content` blocks. When the tool registered an
  `outputSchema`, the typed payload conforms to it.
- Plain `content` → standard MCP content blocks.

### Tasks

If the server registered the tool with `long_running => true`,
`call_tool` returns immediately with `#{<<"taskId">> := Id,
<<"status">> := <<"running">>}`. Track progress with the methods
in section 12.

---

## 8. Read and subscribe to resources

```erlang
read_resource(Pid, Uri) ->
    barrel_mcp_client:read_resource(Pid, Uri).
```

Subscribe to be notified of updates:

```erlang
watch_resource(Pid, Uri) ->
    {ok, _} = barrel_mcp_client:subscribe(Pid, Uri),
    receive
        {mcp_resource_updated, Uri, Params} ->
            handle_update(Params)
    after 5000 ->
        timeout
    end.
handle_update(_) -> ok.
```

The subscription stays in the client's state until you call
`unsubscribe(Pid, Uri)` or close the client. Subscribers are
identified by their pid; multiple processes can subscribe to the same
URI on the same client.

---

### Logging

Set the server's log level for the session, and route the
inbound `notifications/message` stream into your application's
logger via the handler.

```erlang
set_debug_level(Pid) ->
    barrel_mcp_client:set_log_level(Pid, <<"debug">>).
```

Levels match RFC 5424 names: `debug`, `info`, `notice`,
`warning`, `error`, `critical`, `alert`, `emergency`.

### Server introspection

```erlang
caps(Pid) ->
    barrel_mcp_client:server_capabilities(Pid).

info(Pid) ->
    barrel_mcp_client:server_info(Pid).

negotiated_version(Pid) ->
    barrel_mcp_client:protocol_version(Pid).
```

`server_capabilities/1` is the authoritative source for what the
server actually supports (e.g. whether `tasks` is advertised).
Check before calling capability-gated methods.

---

## 9. Get prompts and run completion

```erlang
fetch_prompt(Pid) ->
    barrel_mcp_client:get_prompt(Pid, <<"summarize">>,
                                 #{<<"length">> => <<"short">>}).
```

```erlang
ask_completion(Pid) ->
    barrel_mcp_client:complete(Pid,
        #{<<"type">> => <<"ref/prompt">>, <<"name">> => <<"summarize">>},
        #{<<"name">> => <<"length">>, <<"value">> => <<"sho">>}).
```

`complete/3` is the spec-named `completion/complete` request used to
auto-complete prompt argument values.

---

## 10. Handle server-initiated requests

The server can call into the client (`sampling/createMessage`,
`roots/list`, `elicitation/create`). Implement
`barrel_mcp_client_handler` and supply it as `handler => {Mod, Args}`.

Three return shapes from `handle_request/3`:

- `{reply, Result, State}` — synchronous answer.
- `{error, Code, Message, State}` — JSON-RPC error response.
- `{async, Tag, State}` — defer; reply later from any process via
  `barrel_mcp_client:reply_async(Pid, Tag, Result)`.

Skeleton:

```erlang
-module(my_handler).
-behaviour(barrel_mcp_client_handler).
-export([init/1, handle_request/3, handle_notification/3, terminate/2]).

init(Args) ->
    {ok, Args}.

handle_request(<<"sampling/createMessage">>, Params, State) ->
    Result = sample_via_llm(Params, State),
    {reply, Result, State};
handle_request(<<"roots/list">>, _, State) ->
    {reply, #{<<"roots">> => [
        #{<<"uri">> => <<"file:///workspace">>,
          <<"name">> => <<"workspace">>}
    ]}, State};
handle_request(Method, _Params, State) ->
    {error, -32601, <<"Method not found: ", Method/binary>>, State}.

handle_notification(_Method, _Params, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

sample_via_llm(_, _) ->
    %% Replace with an HTTP call to your LLM provider.
    #{<<"content">> => #{<<"type">> => <<"text">>, <<"text">> => <<"hi">>},
      <<"model">> => <<"placeholder">>,
      <<"role">> => <<"assistant">>}.
```

The `sampling_host` example in
[`examples/sampling_host/src/sampling_host.erl`](https://github.com/barrel-platform/barrel_mcp/tree/main/examples/sampling_host/src/sampling_host.erl)
shows the full server-to-client round-trip end to end.

---

## 11. Asynchronous handler replies

When answering a server request takes time (calling an LLM provider,
asking a user, etc.), block the model thread instead of the state
machine:

```erl
handle_request(<<"sampling/createMessage">>, Params, State) ->
    Tag = make_ref(),
    Self = self(),  %% the host process; not the gen_statem
    spawn(fun() ->
        Result = slow_llm_call(Params),
        barrel_mcp_client:reply_async(Self, Tag, Result)
    end),
    {async, Tag, State}.
```

`reply_async/3` may also be used for errors via
`reply_async(Pid, Tag, {error, Code, Message})`.

---

## 12. Notifications and tasks

The handler's `handle_notification/3` callback receives every inbound
notification with its raw `params` map. Common methods:

- `notifications/resources/updated` — also dispatched to subscribers
  of the URI as `{mcp_resource_updated, Uri, Params}` (see section 8).
- `notifications/progress` — also dispatched to the caller of the
  request that owns the progress token (see section 7).
- `notifications/tools/list_changed`, `.../resources/list_changed`,
  `.../prompts/list_changed` — catalogue updated; re-fetch or
  invalidate caches.
- `notifications/tasks/changed` — a long-running task transitioned
  state. The full task record is in `params`.
- `notifications/message` — server logging stream.
- `notifications/replay_truncated` — your `Last-Event-ID` was
  outside the server's replay window; resync rather than trust the
  partial stream.

The handler is the right place to integrate with your application's
metrics, logs, or UI.

### Task methods

When a tool was registered as `long_running` on the server, the
initial `call_tool` returns a `taskId`. Track it with the typed
wrappers:

```erlang
poll_task(Pid, TaskId) ->
    barrel_mcp_client:tasks_get(Pid, TaskId).

list_tasks(Pid) ->
    %% Single page; use `tasks_list_all/1' or
    %% `tasks_list/2' with `#{want_cursor => true}' for paging.
    barrel_mcp_client:tasks_list(Pid).

abort_task(Pid, TaskId) ->
    barrel_mcp_client:tasks_cancel(Pid, TaskId).
```

When you registered a `progress_token` on the originating call,
the same task usually emits `notifications/progress` updates that
arrive through your handler, so polling is rarely required —
prefer subscribing to `notifications/tasks/changed` in the
handler over busy-polling `tasks_get/2`.

---

## 13. Cancel, time out, ping

```erlang
cancel_request(Pid, Id) ->
    barrel_mcp_client:cancel(Pid, Id).
```

The id is the JSON-RPC request id for the in-flight call.
`barrel_mcp_client` increments these internally; in tests you can
read pending ids via `sys:get_state/1`. In production you usually
don't cancel by id — you set a `timeout` on `call_tool/4` and let
the deadline fire.

Periodic ping is opt-in:

```erl
%% Spec snippet — a key on barrel_mcp_client:start_link/1's input map.
#{ping_interval => 30000, ping_failure_threshold => 3}
```

After three consecutive ping failures (default), the connection
closes with reason `ping_failed` and the linked owner sees the exit.

---

## 14. Authenticate

### Static bearer

```erl
#{transport => {http, <<"https://server.example/mcp">>},
  auth => {bearer, <<"my-static-token">>}}
```

`barrel_mcp_client_auth_bearer` attaches `Authorization: Bearer ...`
on every request. A 401 returns `{error, unauthorized}` and the
caller must restart with a new token.

### OAuth 2.1 + PKCE

The interactive authorization-code redirect is a host concern; once
you have an access token (and ideally a refresh token), pass them
through:

```erl
#{transport => {http, <<"https://server.example/mcp">>},
  auth => {oauth, #{
    access_token   => <<"eyJ...">>,
    refresh_token  => <<"opaque">>,
    token_endpoint => <<"https://auth.example/token">>,
    client_id      => <<"my-client">>,
    resource       => <<"https://server.example/mcp">>
  }}}
```

On 401 the library posts a `refresh_token` grant to `token_endpoint`
(with the RFC 8707 `resource` parameter), updates the handle, and
retries the original request once.

To drive the *initial* auth code flow yourself, use the discovery
helpers:

```erlang
discover(Server) ->
    {ok, Resp401, Headers} = first_request_returns_401(Server),
    Www = proplists:get_value(<<"www-authenticate">>, Headers),
    PrmUrl = barrel_mcp_client_auth_oauth:parse_www_authenticate(Www),
    {ok, Prm} = barrel_mcp_client_auth_oauth:discover_protected_resource(PrmUrl),
    [Issuer | _] = maps:get(<<"authorization_servers">>, Prm),
    {ok, AS} = barrel_mcp_client_auth_oauth:discover_authorization_server(Issuer),
    {Url, Verifier, _State} = barrel_mcp_client_auth_oauth:build_authorization_url(
        maps:get(<<"authorization_endpoint">>, AS),
        #{client_id => <<"my-client">>,
          redirect_uri => <<"http://localhost:38080/cb">>,
          resource => maps:get(<<"resource">>, Prm)}),
    {Url, Verifier, AS, Resp401}.
first_request_returns_401(_) ->
    {ok, ignore, [{<<"www-authenticate">>,
                   <<"Bearer resource_metadata=\"https://srv/.well-known/oauth-protected-resource\"">>}]}.
```

After the user authorizes and you capture the `code` from the
redirect, exchange it:

```erl
{ok, Tokens} = barrel_mcp_client_auth_oauth:exchange_code(
    maps:get(<<"token_endpoint">>, AS),
    #{code => Code,
      code_verifier => Verifier,
      client_id => <<"my-client">>,
      redirect_uri => <<"http://localhost:38080/cb">>,
      resource => maps:get(<<"resource">>, Prm)}).
```

Then start the client with the tokens above.

---

## 15. Schema-validate before calling

`barrel_mcp_schema:validate/2` covers the JSON Schema subset MCP
tools actually use. Cache the schema returned by `tools/list`, then
validate before dispatching:

```erlang
call_validated(Pid, Name, Args, Schema) ->
    case barrel_mcp_schema:validate(Args, Schema) of
        ok -> barrel_mcp_client:call_tool(Pid, Name, Args);
        {error, Errors} -> {error, {invalid_args, Errors}}
    end.
```

This is opt-in — many hosts trust the LLM output enough to skip it.
Use it when you want a clear error before the request reaches the
server.

---

## 16. Federate many MCP servers

```erl
{ok, _} = barrel_mcp:start_client(<<"github">>, #{
    transport => {http, <<"https://mcp.github.example/">>},
    auth => {bearer, GhToken}
}),
{ok, _} = barrel_mcp:start_client(<<"local-files">>, #{
    transport => {stdio, #{command => "/usr/local/bin/mcp-files"}}
}),

GitHub = barrel_mcp:whereis_client(<<"github">>),
{ok, Tools} = barrel_mcp_client:list_tools(GitHub).
```

Each connection is a supervised worker. Crashes are isolated; the
registry's monitor prunes the dead entry automatically. Tool-name
namespacing across servers is your call; a common pattern is
`<<ServerId/binary, "::", ToolName/binary>>` when surfacing the
catalogue to an LLM.

---

## 17. Errors you can see

| Return | Cause |
| --- | --- |
| `{error, not_ready}` | Call made before the `initialize` handshake completed. Wait for `ready`. |
| `{error, {unsupported, Method}}` | Server didn't advertise the capability the call requires. |
| `{error, {Code, Message}}` | Server returned a JSON-RPC error. |
| `{error, cancelled}` | Caller invoked `cancel/2`. |
| `{error, timeout}` | The per-request timeout fired. |
| `{error, unauthorized}` | 401 with no usable refresh path. |
| `{error, {protocol_version, Server, Supported}}` | Server's version is outside the client's supported list. Init failed. |

---

## 18. Production checklist

- Run clients under a supervisor. `barrel_mcp:start_client/2` does
  this for you; for ad-hoc clients call `barrel_mcp_client:start_link/1`
  inside your own supervision tree.
- Set `request_timeout` to a value that matches your SLO. The default
  30 s is generous.
- Set `ping_interval` if your transport is a long-lived HTTP
  connection that may sit idle behind proxies.
- Implement `handle_notification/3` to forward `notifications/message`
  to your logging system; this is how MCP servers emit operational
  signals.
- Validate tool inputs with `barrel_mcp_schema:validate/2` before
  forwarding model output.
- For OAuth, persist refresh tokens; the in-memory handle dies with
  the client.

---

## See also

- [Internals](internals.md) — architecture and behaviour contracts.
- [`examples/echo_client/`](https://github.com/barrel-platform/barrel_mcp/tree/main/examples/echo_client) — minimal
  end-to-end host.
- [`examples/sampling_host/`](https://github.com/barrel-platform/barrel_mcp/tree/main/examples/sampling_host) — handler
  behaviour worked example.
- [Features](features.md) — spec coverage matrix.
