# JSON-Schema-Test-Suite

Vendored, not fetched. The build must not depend on the network, and a
suite that changed under us would turn an unrelated commit red.

- Source: https://github.com/json-schema-org/JSON-Schema-Test-Suite
- Commit: `3c25e5f709192aadf67cf7f2eb19771a57131fec`
- Contents: `tests/` is that repo's `tests/draft2020-12` (without
  `optional/`), `remotes/` is its `remotes/`, `LICENSE` is its licence.

`optional/` is left out: those cover behaviour the spec marks optional
(`format` assertion, bignum arithmetic, ECMAScript regex semantics) and
we do not claim it.

## Updating

Deliberate, never automatic:

```sh
git clone --depth 1 https://github.com/json-schema-org/JSON-Schema-Test-Suite /tmp/jss
cd /tmp/jss && git rev-parse HEAD          # record this below
cp -R /tmp/jss/tests/draft2020-12 test/json_schema_suite/tests
cp -R /tmp/jss/remotes test/json_schema_suite/remotes
cp /tmp/jss/LICENSE test/json_schema_suite/LICENSE
rm -rf test/json_schema_suite/tests/optional
```

Then run `rebar3 ct --suite=test/barrel_mcp_json_schema_SUITE` and deal
with whatever it says. New failures are either a bug in the validator or
a rule we have decided not to implement; the second needs a line in the
suite's skip list with a reason, not a silent pass.

`remotes/` is served from memory by the suite, never over HTTP: the spec
forbids dereferencing a `$ref` over the network, so a test harness that
did would be testing something we must not do.
