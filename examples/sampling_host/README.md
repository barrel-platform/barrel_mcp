# sampling_host

End-to-end example of the server-to-client sampling round-trip. The
host:

- declares `sampling` capability when it connects;
- implements `barrel_mcp_client_handler` to answer
  `sampling/createMessage` with a canned reply;
- calls a server-side tool that asks the connected client to sample a
  message and wraps the reply.

## Run it

```
cd examples/sampling_host
rebar3 shell
1> sampling_host:run().
<<"got: a canned reply">>
```

## Run the test

```
cd examples/sampling_host
rebar3 ct
```

## What to read

- `src/sampling_host.erl` — the full flow. The
  `barrel_mcp_client_handler` callbacks are at the bottom of the
  module; the server-side tool is `ask_sampler/1`.
- `test/sampling_host_SUITE.erl` — common_test wrapper.

## Why this matters

A real LLM agent host implements `handle_request/3` to call the LLM
provider's API. The pattern shown here is the same shape — replace
`{reply, Result, State}` with an HTTP call to Anthropic, OpenAI, a
local Hermes model, or anything else.
