# Python interop tests

Smoke-tests `barrel_mcp` against the official MCP Python SDK
(`pip install mcp`) in both directions:

- **Direction A** — Python client → Erlang server. The Erlang
  side stands up a Streamable HTTP listener; `client.py`
  connects, lists / calls the registered tool, reads a
  resource, lists prompts, sets the log level.
- **Direction B** — Erlang client → Python server. `server.py`
  runs `FastMCP` over stdio with one `echo` tool;
  `barrel_mcp_client` spawns it and round-trips a `tools/call`.

The corresponding CT cases in
`test/barrel_mcp_python_interop_SUITE` skip when no Python
interpreter is available, so the default `rebar3 ct` keeps
working without Python on the path.

## Run locally

```sh
make interop-setup   # creates .venv and installs mcp
make interop-test    # runs both directions
```

`interop-setup` lives at `test/interop/.venv/`; remove that
directory if you need to re-create it.

## CI

The `interop` job in `.github/workflows/ci.yml` runs both
cases on Linux with Python 3.12 + OTP 28. We pin
`mcp ~= 1.27.0` (PEP 440 compatible release) for reproducibility;
bump it intentionally when validating against a newer SDK.
