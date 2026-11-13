# Dependency Policy

This page lists what barrel_mcp depends on and how those dependencies are
kept current. Read it when you need to know what barrel_mcp brings into your
release, which OTP versions it is tested on, or how quickly an upstream fix
reaches a barrel_mcp release.

## What barrel_mcp depends on

| Dependency | Used for |
|---|---|
| `h1` (hex package `erlang_h1`) | HTTP/1.1 server |
| `h2` | HTTP/2 server |
| `hackney` | HTTP client for MCP servers and OAuth; brings `certifi`, `idna`, `mimerl`, `parse_trans`, `quic`, `ssl_verify_fun`, `webtransport` |

JSON comes from OTP's own `json` module, so there is no JSON dependency.
Test and tooling dependencies (`meck`, `erlfmt`, `rebar3_lint`,
`rebar3_ex_doc`, the conformance runner, the Python MCP SDK) never reach your
release.

## Versions and the lock file

- `rebar.config` pins each runtime dependency to a minor range (`~> 0.11.0`).
- `rebar.lock` is committed. CI keys its build cache on it, so every build
  uses exactly the versions in the lock.
- A dependency bump refreshes the lock in the same commit
  (`rebar3 upgrade --all`) and passes the full checks, the example apps and
  the interop suites before it merges.

## How dependencies are kept current

- Every release starts with a check for newer versions of each dependency.
- A security or protocol fix in a dependency goes into a barrel_mcp patch
  release as soon as the bump passes the checks.
- A dependency moving to a new minor version is read for breaking changes
  before the bump; anything that changes barrel_mcp's behaviour is listed in
  the CHANGELOG.
- The conformance runner (`test/conformance/package.json`) and the Python SDK
  (`test/interop/requirements*.txt`) are pinned and bumped in their own pull
  requests. A new failure after a bump is a defect to fix, not a baseline.

## Erlang/OTP

CI runs every check on the two most recent OTP major releases, currently 28
and 29. Older releases are not tested. Run on a patch release with the
current TLS fixes; [SECURITY.md](../SECURITY.md) names the minimum versions.
