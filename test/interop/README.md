# Python interop tests

Smoke-tests `barrel_mcp` against the official MCP Python SDK in both
directions and both protocol eras.

The two SDK generations need separate virtualenvs. v1 speaks the
handshake era, v2 speaks `2026-07-28` and replaced `FastMCP` with
`MCPServer`, so neither interpreter can run the other's scripts.

| venv | SDK | Era | Scripts |
|---|---|---|---|
| `.venv` | `mcp ~= 1.27.0` | handshake (`2025-11-25`) | `client.py`, `server.py` |
| `.venv-modern` | `mcp == 2.0.0` | modern (`2026-07-28`) | `client_modern.py`, `server_modern.py` |

- **Direction A**: Python client → Erlang server. The Erlang
  side stands up a Streamable HTTP listener; the client connects,
  lists / calls the registered tool, reads a resource, lists prompts.
  The handshake-era script also sets the log level and drives
  sampling, elicitation and roots; it runs a second time with
  `--post-only`, never opening the GET stream, so those three server
  requests must arrive on the call's own response stream. The modern
  one additionally covers:
  - the `server/discover` probe and the `_meta` serverInfo stamp
  - `resultType` on every result and the freshness hints on a
    cacheable one
  - multi round-trip requests on `tools/call`, `prompts/get` and
    `resources/read`
  - `-32021` when the server asks for a capability the client never
    declared, and the client's own cap on retry rounds
  - `subscriptions/listen`: the acknowledged filter, a resource update
    arriving on the stream, and no delivery of a type nobody asked for
  - `x-mcp-header` mirroring, including values that need the base64
    sentinel. The server rejects a header that disagrees with the body,
    so a call that succeeds is the assertion.
- **Direction B**: Erlang client → Python server over stdio.
  `barrel_mcp_client` spawns the script and round-trips a
  `tools/call`. The handshake-era case leaves `protocol_version`
  unset, so it also covers the probe falling back against an SDK that
  has never heard of `server/discover`. The modern cases add the probe
  landing on `2026-07-28` over stdio, and a multi round-trip request
  the reference implementation produced, so our client's retry loop is
  driven by an envelope it had no hand in building.

The corresponding CT cases skip when their interpreter is not
configured, so the default `rebar3 ct` keeps working without Python.

## Conformance runner

`make conformance` runs the official `@modelcontextprotocol/conformance`
runner (pinned in `test/conformance/package.json`) against our server
in `test/barrel_mcp_conformance_SUITE.erl`, one CT case per run:

| case | runner selection |
|---|---|
| `conformance_2026_07_28` | `--spec-version 2026-07-28 --suite all` |
| `conformance_2025_11_25` | `--spec-version 2025-11-25 --suite all` |
| `conformance_2025_06_18` | `--spec-version 2025-06-18 --suite all` |
| `conformance_2025_03_26` | `--spec-version 2025-03-26 --suite all` |
| `requirements_2026_07_28` | `--requirements 2026-07-28` |
| `requirements_2025_11_25` | `--requirements 2025-11-25` |

And the runner's client mode against our client, four more cases. The
runner starts a server per scenario and runs
`test/barrel_mcp_conformance_client.erl` against it: an `erl` node the
suite assembles from `barrel_mcp_test_helpers:child_args/2`, reading
the URL from its plain arguments and the scenario, context and
protocol version from the environment. The `auth/*` scenarios drive
the OAuth handle's authorization-code flow headlessly (the redirect
step fetches the authorization URL and returns its `Location`).

| case | runner selection |
|---|---|
| `client_requirements_2026_07_28` | `client --requirements 2026-07-28` |
| `client_requirements_2025_11_25` | `client --requirements 2025-11-25` |
| `client_conformance_2025_06_18` | `client --spec-version 2025-06-18 --suite all` |
| `client_conformance_2025_03_26` | `client --spec-version 2025-03-26 --suite all` |

`--suite all` is every scenario the runner knows for a revision,
drafts included; `--requirements` is the frozen set a revision
required at release, which the runner ships for those two revisions
only. Any FAILURE in a scored scenario fails the case. There is no
expected-failures file: a failing check is a defect to fix, not a
baseline.

A `--requirements` run also executes the scenarios its YAML lists as
`not_scored` (extensions, and scenarios pending against the runner's
own reference fixture); the runner reports them and exits 0
regardless. The case reads that list from the runner's YAML and
prints those failures apart, so a regression there is still visible.
The SEP-2663 task scenarios on the server side and the extension
grants (client credentials, EMA, WIF, DPoP) on the client side are
among them and pass here; the one thing left in that report is the
runner's own `wire-schema-valid` check validating a `CreateTaskResult`
against the core `CallToolResult` schema, which no implementation can
satisfy.

## Run locally

```sh
make interop-setup   # creates both venvs
make interop-test    # Python cases, then the conformance runner
```

The venvs live at `test/interop/.venv/` and
`test/interop/.venv-modern/`; remove a directory if you need to
re-create it.

## Expected output

The handshake-era direction B logs a validation error from the Python
server: our client probes `server/discover` and that SDK does not know
the method. That is the fallback working, not a failure.

## CI

The `interop` job in `.github/workflows/ci.yml` runs all four cases on
Linux with Python 3.12 + OTP 28. Both SDK versions are pinned for
reproducibility; bump them intentionally when validating against a
newer SDK.
