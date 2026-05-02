# echo_client

Minimal MCP host built on `barrel_mcp_client`. Boots a `barrel_mcp`
Streamable HTTP server in-process, registers an `echo` tool, connects
a client, calls the tool, and prints the result.

## Run it

```
cd examples/echo_client
rebar3 shell
1> echo_client:run().
tools: [<<"echo">>]
echo: hello, mcp
<<"hello, mcp">>
```

## Run the test

```
cd examples/echo_client
rebar3 ct
```

## What to read

- `src/echo_client.erl` — the entire flow in ~50 lines.
- `test/echo_client_SUITE.erl` — common_test wrapper.
