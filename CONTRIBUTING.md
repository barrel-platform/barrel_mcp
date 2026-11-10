# Contributing

This page is for people changing barrel_mcp itself. For using the library, start with [guides/getting-started.md](guides/getting-started.md). For finding your way around the source, read [guides/internals.md](guides/internals.md) and [guides/server-internals.md](guides/server-internals.md), and keep [guides/glossary.md](guides/glossary.md) open for the terms.

## Write for the person who reads it

Every issue, pull request and comment is read by a person. Make it easy for
them.

- Read what you send before you send it. You are responsible for every line,
  whether you wrote it or a tool did.
- Use plain English and short sentences. Say what happens, what you
  expected, and how to reproduce it. Explain any term a reader may not know.
- Don't inflate it. No buzzwords, no severity scores, CVSS or CWE labels, no
  "critical" for a bug, no long generated write-ups. If it takes a page to
  explain, cut it down until it doesn't.
- A bug report gives: the barrel_mcp and OTP versions, server or client,
  the transport (Streamable HTTP or stdio), the protocol revision
  negotiated, the options you set, the peer (Claude Code, an SDK and its
  version, the conformance runner), a minimal reproduction, what you got
  and what you expected. The JSON-RPC messages exchanged help most.
- A pull request says what was wrong and why it matters, the fix in a few
  lines, and any breaking change. Link the issue. Don't walk through the diff
  file by file; the reviewer reads the code.
- A fix comes with a test that fails without it.

AI tools are fine to use. Before you open anything, you must have read the
change, run the tests, and be able to answer questions about it yourself.

Maintainers read every issue and pull request before acting on it. We close
without further review:

- text we cannot understand after one request to clarify;
- descriptions that don't match the code or the reproduction;
- reports that cannot be reproduced;
- submissions opened by an automated agent that no person has read.

## Security issues and specification bugs

barrel_mcp implements MCP (every revision from `2024-11-05` through
`2026-07-28`), its tasks extension, and the JSON, JSON Schema, HTTP and
OAuth specifications listed in [AGENTS.md](https://github.com/barrel-platform/barrel_mcp/blob/main/AGENTS.md#specifications).

When the fix is to make barrel_mcp do what one of these specifications says,
it is a bug, not a security issue. That includes reports described as
denial of service, memory exhaustion or a remote crash, when they come from:

- input accepted, rejected or framed differently from the specification;
- a wrong error code or HTTP status, a wrong protocol version, a method
  served in a revision that does not have it, or a wrong state transition;
- an OAuth or discovery flow that fails or goes wrong without letting in a
  peer or a token that should have been refused;
- a missing bound that the specification or an option defines.

Report these as a normal bug, in public. Cite the specification section. The
fix goes in a public pull request and in the CHANGELOG under Fixed. We don't
publish advisories or request CVEs for them, and advisories filed for them
are closed with a link to the fix.

Only problems that are not a specification deviation go through
[SECURITY.md](https://github.com/barrel-platform/barrel_mcp/blob/main/SECURITY.md): code execution, a request served without the
authentication or authorization the configuration asks for (auth providers,
token audience, visibility and subscription checks, session and task
ownership, `Origin` checks), one session's or user's data reaching someone
else, credentials or tokens leaking or sent to the wrong server, forged
request state being accepted, or barrel_mcp weakening TLS below what the
configuration allows.

## Keeping the specifications current

The specifications barrel_mcp follows, and the version of each, are listed in
[AGENTS.md](https://github.com/barrel-platform/barrel_mcp/blob/main/AGENTS.md#specifications),
with the newer versions not yet followed under Pending updates. The list is
checked before every release and when a module it names changes.

Moving to a new MCP revision, extension text, RFC or draft revision is its
own pull request: first the list of what changed in the sections the code
uses, then one commit per change with its test, then the conformance runner
at a version that knows the new revision. A new MCP revision is added next
to the old ones; older revisions stay negotiable. The steps are in
[Keeping the specifications current](https://github.com/barrel-platform/barrel_mcp/blob/main/AGENTS.md#keeping-the-specifications-current).
If you notice a spec has a newer version, open an issue naming it; that is
enough to get it on the list.

## Set up

You need Erlang/OTP 28 or later and rebar3. The dependencies (`h1`, `h2`,
`hackney`) come from hex.

```bash
git clone https://github.com/barrel-platform/barrel_mcp.git
cd barrel_mcp
rebar3 compile
```

The interop suites need more: Python 3 for the Python SDK suite and Node.js
for the conformance runner. Both are set up by `make interop-test`.

## Before you commit

Run what CI runs. These are the checks that gate a pull request:

```bash
rebar3 fmt          # format first, then check the rest
rebar3 compile
rebar3 fmt --check
rebar3 lint
rebar3 xref
rebar3 dialyzer
rebar3 eunit
rebar3 ct           # includes doc_snippets_SUITE, see "Documentation" below
make examples-test
make interop-test
```

`rebar.lock` is committed. When you bump a dependency, refresh the lock in
the same commit (`rebar3 upgrade --all`), since CI keys its build cache on
the lock hash.

## Tests

- `test/barrel_mcp_*_tests.erl` are EUnit tests, run by `rebar3 eunit`.
- `test/barrel_mcp_*_SUITE.erl` are Common Test suites, run one at a time
  with `rebar3 ct --suite=test/barrel_mcp_oauth_dcr_SUITE`.
- `barrel_mcp_python_interop_SUITE` runs against the Python MCP SDK, one
  legacy and one modern release. `make interop-python` creates the virtual
  environments and runs it; plain `rebar3 ct` skips it.
- `barrel_mcp_conformance_SUITE` runs the official
  `@modelcontextprotocol/conformance` runner, pinned in
  `test/conformance/package.json`, in server and client modes for every
  revision the runner knows (`2025-03-26` onward). `make conformance` installs it and runs it; plain `rebar3 ct`
  skips it. The suite reports the runner's own unscored scenarios
  separately. `make conformance-report` prints the last run as a
  table. A new failure in either list is a defect to fix; there is no
  expected-failures file.
- `make examples-test` builds every app under `examples/` against this
  checkout and runs its suites.

A test must fail for one reason. A denial test that also passes when the
call crashes, or a test that asserts a value it computed itself, is worse
than no test because it reads as coverage.

## What CI enforces

| Job | What it proves |
|-----|----------------|
| Compile (OTP 28, 29) | `rebar3 compile` with `warnings_as_errors` |
| Tests (OTP 28, 29) | `rebar3 eunit` and `rebar3 ct`, including the doc snippet check |
| Examples (OTP 28, 29) | Every example app builds and its suites pass |
| Python interop (OTP 28) | The Python SDK suite, through `make interop-python` |
| Conformance (OTP 28) | The official conformance runner through `make conformance`; the results table goes to the job summary and the raw results to the `conformance-results` artifact |
| Format, Lint, Xref, Dialyzer | Formatting, Elvis, cross-reference and type checks |

## Documentation

`rebar3 ct` includes `test/doc_snippets_SUITE.erl`, which compiles the
` ```erlang ` blocks in `guides/building-a-client.md`, `guides/internals.md`
and `examples/*/README.md`, so a renamed function fails with the code. Other
guides are not checked; when you rename an option or remove a function,
grep `guides/` and `README.md` for it and fix the docs in the same change.

Write guides in the task-oriented style the existing ones use: say what the
thing is, when you need it, then show the steps with short notes between
code blocks.

## Issue labels

Issues use the MCP project's SDK labels, so triage time and fix time can be
measured the same way across SDKs:

- type: `bug`, `enhancement`, `question`;
- status: `needs confirmation`, `needs repro`, `ready for work`,
  `good first issue`, `help wanted`;
- priority, only when actionable: `P0` (core MCP operations broken, or a
  security issue), `P1` (a bug affecting many users), `P2` (moderate),
  `P3` (nice to have).

A specification deviation is a bug and gets a priority like any other bug;
see [Security issues and specification bugs](#security-issues-and-specification-bugs).

## Pull requests

Branch from `main` using the prefix that fits: `fix/`, `feat/`, `perf/`, `refactor/`, `docs/`, `test/` or `chore/`.

Write the commit subject in the imperative, describing what the code now does rather than what it used to do. Keep the body to short bullets, only for a non-obvious why. Do not add generated-by or co-authored-by trailers.

A change to protocol code passes the three checks in [AGENTS.md](https://github.com/barrel-platform/barrel_mcp/blob/main/AGENTS.md#first-principle-compliance-latest-spec-safety) before it is opened: compliance with the spec section, the spec being the current one, and safety against a hostile peer.

Say what the change is for and how it works. Skip the test inventory: CI reports that. If the change touches the public API, show it in a short code block.

Sync a branch that has fallen behind by merging `main` into it, not by rebasing.

## Releases

Releases follow [docs/versioning.md](docs/versioning.md), and dependency bumps [docs/dependencies.md](docs/dependencies.md). The version lives in `src/barrel_mcp.app.src`. A release is a pull request that bumps it, the install tag in `README.md` and the "Nothing is pending as of" lines in `README.md` and `docs/pending-features.md`, and adds the CHANGELOG entry. After it merges: an annotated tag `vX.Y.Z` on the merge commit, a GitHub release carrying that CHANGELOG section as is, then `rebar3 hex publish`.

Before opening the release pull request, check the specification list as described in [Keeping the specifications current](#keeping-the-specifications-current), and add any newer version found to Pending updates.
