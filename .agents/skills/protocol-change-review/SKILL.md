---
name: protocol-change-review
description: Run the three required checks (compliance, latest specification, safety) on a barrel_mcp change, commit or pull request that touches JSON-RPC handling, MCP methods, results or errors, `_meta`, capabilities, protocol version negotiation, sessions, Streamable HTTP or SSE, stdio framing, subscriptions, tasks, MRTR request state, JSON Schema validation, server auth providers or the OAuth client. Use before committing, before opening or merging a PR, when reviewing a contributor PR, and when asked whether code follows a spec.
---

# Protocol change review

barrel_mcp talks to untrusted peers: any client that reaches a server, and
any server or authorization server a client is pointed at. A change is done
when it matches the spec, the spec is the current one, and a hostile peer
cannot use it. Run the three checks below on each commit; a PR with several
commits gets one verdict per commit. The spec list is in
[AGENTS.md](../../../AGENTS.md#specifications).

## 1. Compliance

Follow the [spec-compliance](../spec-compliance/SKILL.md) skill: read the
spec text at a pinned commit, check every quoted sentence and the section
around it, the requirement level, the error code and the action, and every
path that reaches the code (each revision the method exists in, legacy and
modern era, Streamable HTTP and stdio, server and client, a request inside a
session and a stateless one, before and after `initialize`).

Then check the test:

- It fails on main and passes with the change. Use a worktree at the merge
  base, not `git stash`:

```bash
git worktree add ../barrel_mcp_base origin/main
cp test/barrel_mcp_x_tests.erl ../barrel_mcp_base/test/
cd ../barrel_mcp_base && rebar3 eunit --module=barrel_mcp_x_tests
```

- It asserts the outcome the spec names (the error code, the HTTP status,
  the result field, the notification sent) and cannot also pass on a crash
  or a missing result.

Suites to run (commands in [CONTRIBUTING.md](../../../CONTRIBUTING.md)):
`rebar3 eunit`, `rebar3 ct`, `make examples-test`, and `make interop-test`,
which runs the Python SDK suite and the official conformance runner in
server and client modes. A new failure in the conformance report, scored or
unscored, is a defect to fix in the change.

## 2. Latest specification

1. Name the governing document and the revision. For MCP, that is the
   revision directory under `docs/specification/<revision>/` and the
   matching `schema/<revision>/schema.ts` in
   https://github.com/modelcontextprotocol/modelcontextprotocol; check
   whether a newer revision or the `draft` directory changes the rule. For
   tasks, the same in https://github.com/modelcontextprotocol/ext-tasks.
2. For an RFC, check `https://www.rfc-editor.org/rfc/rfcNNNN.json`
   (`obsoleted_by`, `updated_by`) and errata on
   https://www.rfc-editor.org/errata/rfcNNNN. For a draft, check the latest
   revision on `https://datatracker.ietf.org/doc/draft-.../` and read the
   section in that revision.
3. Write the revision or version, the commit or date checked, in the PR
   description.
4. If the latest text disagrees with the code, fix it in the change or say
   in the PR that it is out of scope, and add it under "Pending updates" in
   AGENTS.md. Moving to a new version follows "Keeping the specifications
   current" there.

## 3. Safety

Walk the classes that apply and state which you checked.

- **Resource exhaustion**: request body and message size, stdio line length,
  JSON nesting, per-session state, the SSE replay buffer behind
  `Last-Event-ID`, pending server-to-client requests, progress tokens,
  subscriptions, tasks and their results until TTL, pagination cursors,
  request state size, JSON Schema validation (`$ref` cycles, pattern cost),
  URI template expansion. A peer must not grow any of them without a bound
  set by the spec or an option.
- **Floods**: notifications, cancellations, subscribe and unsubscribe churn,
  task creation and polling, list-changed fan-out, log messages.
- **Session and request integrity**: session ids unguessable and tied to the
  identity that created them, SSE replay only within the session and stream
  it belongs to, request state (MRTR) authenticated with the
  `request_state_key` and bound to its request, cancellation reaching only
  the caller's own request.
- **Authorization**: server auth providers on every entry path (POST, GET,
  DELETE, stdio where configured), token audience and resource (RFC 8707,
  RFC 9728), scopes, `visible/4` filtering listings fail closed,
  `authorize_subscribe/3`, task and session ownership, `Origin` validation
  and the default `127.0.0.1` bind.
- **Client credentials**: PKCE and `state`, issuer check (RFC 9207), tokens
  sent only to the resource they were issued for, redirects and metadata
  URLs not able to steer a token elsewhere, DPoP keys and assertions kept
  out of logs and error terms.
- **Code execution**: no wire value reaching `apply/3`, a module name or
  `binary_to_atom/1`; handlers called only as registered.

Never weaken a limit to let a legitimate peer pass; exclude that case
precisely. A regression test for an attack drives it over a real transport
or through the decoder and asserts the bound or the error.

## Bug or security advisory

Decide this for every finding, from the rule in "Specification issues are
bugs, not security issues" in AGENTS.md:

- **Bug**: the fix is to follow the spec, even when the finding is an
  exhaustion, flood or crash vector. Public PR, CHANGELOG under Fixed with
  the spec section, no advisory, no CVE, no severity, no attack description.
  An advisory filed for it is closed as not a vulnerability with a link to
  the PR.
- **Security issue**: code execution; authentication or authorization
  bypassed (auth providers, token audience, visibility, subscription,
  session or task ownership, `Origin`); one session's or identity's data
  reaching another; credentials or tokens leaking or sent to the wrong
  server; forged request state accepted; TLS weakened. These stay security
  issues even where a spec describes the check. Stop, do not push a public
  fix or describe it in a PR, and hand it to the maintainer through
  [SECURITY.md](../../../SECURITY.md).

When unsure which, ask the maintainer before treating it as a security
issue.

## Report

One block per commit, in the PR description or the hand-off:

```
<sha> <subject>
  spec: MCP 2025-11-25 basic/transports MUST, quote verified | not found | paraphrased
  latest: MCP 2026-07-28 current, draft unchanged (spec repo at <sha>, checked 2026-11-10)
  verdict: compliant | partial (<missing>) | wrong (<why>) | not a spec item
  test: fails before, passes after | does not discriminate | missing
  interop: make interop-test, conformance scored/unscored failures
  safety: <classes checked>, <bounds>, no new unbounded state
  class: bug | security (handed to maintainer) | not applicable
```

Then list what needs the maintainer's decision: a SHOULD left out, a
deliberate deviation, a spec update that is out of scope.
