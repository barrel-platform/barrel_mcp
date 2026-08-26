# Protocol Versions

barrel_mcp speaks every released revision of MCP, from `2024-11-05` through
`2026-07-28`. Those revisions fall into two eras that differ in how a peer says
who it is, and a server decides which one it is answering per request rather
than per deployment. You need this page when you are pinning a client to a
revision, when a request comes back with `-32020`, `-32021` or `-32022`, or when
you are writing a tool handler that has to work against both eras.

## The two eras

**Legacy** revisions (`2025-11-25` and earlier) open with an `initialize`
handshake. The server issues a session id, and every later request carries it.
Protocol version, client capabilities and client identity are established once
and remembered.

**Modern** revisions (`2026-07-28` and later) have no handshake and no session.
Every request carries its own protocol version, capabilities and identity in
`params._meta`.

| | Legacy | Modern |
|---|---|---|
| Opens with | `initialize` | nothing |
| Version comes from | the handshake | `_meta` on each request |
| Session | `Mcp-Session-Id` | none |
| Server to client | requests over SSE | `inputRequests` in the result |
| Subscriptions | `resources/subscribe` + GET SSE | `subscriptions/listen` |
| Resumable stream | `Last-Event-ID` | no |

A request is modern when `params._meta` carries
`io.modelcontextprotocol/protocolVersion`, and legacy otherwise. `initialize` is
always legacy.

## Serve both eras

Nothing to do. One listener answers both, and the eras do not see each other:

```erlang
{ok, _} = barrel_mcp:start_http_stream(#{port => 8080}).
```

A legacy client holding a session and an open GET stream, and a modern client
holding a `subscriptions/listen` stream, can run against that port at the same
time. Registry changes reach both.

## Pin a client to a revision

`protocol_version` defaults to `auto`, which sends `server/discover` and falls
back to the `initialize` handshake if the server does not answer it:

```erlang
{ok, Pid} = barrel_mcp:start_client(my_client, #{
    transport => {http, #{url => <<"http://localhost:8080/mcp">>}},
    protocol_version => auto,
    probe_timeout => 5000
}).
```

Pin a revision to skip the probe:

```erlang
%% Modern only. No probe, no handshake.
#{protocol_version => <<"2026-07-28">>}

%% Legacy only. Straight to initialize.
#{protocol_version => <<"2025-11-25">>}
```

Read back what was negotiated:

```erlang
{ok, Version} = barrel_mcp_client:protocol_version(Pid).
```

Pin when you know the server, since the probe costs a round trip against a
legacy one. Leave it on `auto` when you do not.

## Choose what the server advertises

On `-32022` the server names the revisions a client may retry with. By default
that is the modern list only:

```erlang
%% sys.config
{barrel_mcp, [{advertise_versions, modern}]}
```

Set `all` to advertise both eras. Be aware of what that means: a client that
picks a legacy revision off the list and names it in per-request `_meta` is
rejected again, because a legacy revision cannot be reached that way. It has to
drop to the handshake. Legacy clients never see this list, and `initialize`
works either way.

## Compare revisions in your own code

Revisions are an enumerated set, not an ordered scalar. They happen to be
date-shaped today, so they happen to sort, but comparing the binaries makes any
string from a peer you do not recognise look newer than everything you know:
`<<"zzz">> > <<"2026-07-28">>` is true and means nothing.

```erlang
true  = barrel_mcp_version:is_at_least(<<"2026-07-28">>, <<"2025-11-25">>),
false = barrel_mcp_version:is_at_least(<<"zzz">>, <<"2024-11-05">>),
modern = barrel_mcp_version:era(<<"2026-07-28">>),
[<<"2026-07-28">> | _] = barrel_mcp_version:all().
```

An unrecognised revision satisfies no minimum. An unrecognised *minimum* raises,
since that is a bug where it is written.

## Methods that exist in one era only

| Method | Legacy | Modern |
|---|---|---|
| `initialize` | yes | no |
| `ping` | yes | no |
| `logging/setLevel` | yes | no |
| `resources/subscribe` / `unsubscribe` | yes | no |
| `tasks/list`, `tasks/result` | yes | no |
| `subscriptions/listen` | no | yes |
| `tasks/update` | no | yes |
| `server/discover` | yes | yes |

Everything else (`tools/*`, `resources/read`, `prompts/*`, `completion/complete`,
`tasks/get`, `tasks/cancel`) works in both.

Calling one from the wrong era is `-32601`, as an unknown method: it does not
exist there, and the peer that asked cannot use it if it did.

The client answers before the round trip rather than letting the server reject
it, so the verbs stay callable and tell you why:

```erlang
{error, {unsupported, <<"ping">>}} = barrel_mcp_client:ping(Pid).
```

`subscribe/2` and `unsubscribe/2` are the exception. They keep their signatures
and their meaning, running over `subscriptions/listen` in modern mode and
`resources/subscribe` in legacy. `notify_roots_list_changed/1` is a cast and is
dropped in modern mode, where Roots no longer exists. Ping keepalive turns
itself off, since a configured cadence would only produce method-not-found on a
timer.

## Write a handler that works in both

Handlers do not choose an era. Arity-2 handlers get a `Ctx` and ask it what the
client can do:

```erlang
my_tool(Args, Ctx) ->
    case barrel_mcp:client_supports(Ctx, elicitation) of
        true  -> ask_the_user(Args, Ctx);
        false -> use_a_default(Args)
    end.
```

Asking for input works the same in both eras from the handler's side. What
differs is the wire: legacy sends a server-to-client request over the session
stream, modern returns the question in the result and waits for the client to
retry. See the [Features guide](features.md) for the full shape.

## Errors this revision added

| Code | Meaning | What to do |
|---|---|---|
| `-32020` | `MCP-Protocol-Version` or an `Mcp-*` header disagrees with the body | Re-fetch `tools/list` and retry once; the tool's header annotations changed |
| `-32021` | The server needs a capability you did not declare | Declare it in `_meta`, or accept the degraded path |
| `-32022` | The revision you named is not served | Retry with one from `data.supported` |

`-32020` through `-32099` are reserved for the specification. Do not emit a code
in that range that the spec does not define.

## Notes

- Nothing was removed in 3.0. Every legacy path still works, and a 2.3.0
  deployment upgrades without configuration changes.
- The HTTP+SSE transport from `2024-11-05` is off unless you configure it.
  Pass `sse_path` and `sse_message_path` to `start_http_stream/1` to serve it
  alongside Streamable HTTP on the same listener; without them a legacy client
  reaches you over Streamable HTTP carrying an older revision.
- `barrel_mcp_version` is the only place that orders revisions. Nothing else in
  the library compares version binaries, and neither should your code.
