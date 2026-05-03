# `agent_host` example

Demonstrates how `barrel_mcp_agent` aggregates tools across two
federated MCP clients into one namespaced catalog and routes a
call back to the right server.

## What it does

```erlang
{ok, _} = barrel_mcp:start_client(<<"alpha">>, Spec),
{ok, _} = barrel_mcp:start_client(<<"beta">>,  Spec),

Tools = barrel_mcp_agent:to_anthropic(),  %% or :to_openai/0,
                                          %% or :list_tools/0
%% Hand `Tools' to your LLM, capture its tool_use block, then:
{NamespacedName, Args} =
    barrel_mcp_tool_format:from_anthropic_call(Block),
{ok, Result} = barrel_mcp_agent:call_tool(NamespacedName, Args).
```

`barrel_mcp_agent:list_tools/0` returns the union of every
connected client's `tools/list`, with each tool's `name`
rewritten to `<<"ServerId:ToolName">>`. `call_tool/2` parses
the namespaced name and dispatches to the right `ServerId`.

## In production vs in this example

In production the two `start_client/2` calls would point at
**distinct** external MCP servers, each typed by a different
`ServerId`. Each server returns its own catalog and the
aggregator surfaces every tool exactly once.

For a self-contained example we boot one in-process Streamable
HTTP server with a single `echo` tool and connect both clients
to it. The aggregator surfaces `echo` twice (`alpha:echo` and
`beta:echo`) and routing still dispatches deterministically by
prefix — so the round-trip exercises the same code paths a real
multi-server setup would use.

## Run it

```sh
make examples-setup        # creates the _checkouts symlink
cd examples/agent_host
rebar3 ct                  # runs the federation_round_trip case
```

Or interactively:

```sh
cd examples/agent_host
rebar3 shell --eval 'agent_host:run().'
```

## Companion modules

- `barrel_mcp_agent` — the aggregator and router this example
  showcases. See `guides/features.md` and the module's edoc.
- `barrel_mcp_tool_format` — translate the namespaced catalog
  to the Anthropic Messages API or OpenAI Chat Completions tool
  shape, and translate a model's tool-call back to
  `(Name, Args)`.
- `barrel_mcp_clients` — the federation registry that backs
  `barrel_mcp:start_client/2`.
