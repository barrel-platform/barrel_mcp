# MCP wire-schema vectors

Vendored, not fetched: the build must not depend on the network, and a
schema that changed under us would turn an unrelated commit red.

- Source: https://github.com/modelcontextprotocol/modelcontextprotocol
- Commit: `b0f60ba5409db7a6582440a7b473cc0398890f15`
- Contents: `2026-07-28/schema.json` is that repo's
  `schema/2026-07-28/schema.json`; `2026-07-28/examples/` is its
  `schema/2026-07-28/examples/`, one directory per message type, each
  file a canonical instance of that type.

Only `2026-07-28` ships examples; the legacy revisions have none.

## The tasks extension

- Source: https://github.com/modelcontextprotocol/ext-tasks
- Commit: `e4345978be1f602f1fc48d89051e8559dd5302a6`
- Contents: `ext-tasks/schema.json` is that repository's
  `schema/draft/schema.json`. SEP-2663 moved `CreateTaskResult` out of
  the core schema and into this one, so it is what the conformance
  runner has to validate a task handle against
  (`test/conformance/patch-runner.js`).

## Updating

Deliberate, never automatic:

```sh
git clone --depth 1 https://github.com/modelcontextprotocol/modelcontextprotocol /tmp/mcp-spec
cd /tmp/mcp-spec && git rev-parse HEAD          # record this above
cp /tmp/mcp-spec/schema/2026-07-28/schema.json test/schema_vectors/2026-07-28/
rm -rf test/schema_vectors/2026-07-28/examples
cp -R /tmp/mcp-spec/schema/2026-07-28/examples test/schema_vectors/2026-07-28/
```

Then run `rebar3 ct --suite=test/barrel_mcp_schema_vectors_SUITE`. A
vector our validator refuses is either a validator bug or a schema
feature we do not implement; the second needs a skip with a reason,
never a silent pass.
