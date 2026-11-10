---
name: spec-compliance
description: Check a change, commit or pull request in barrel_mcp against the spec it claims to follow (an MCP revision from 2024-11-05 to 2026-07-28, the MCP tasks extension, JSON-RPC 2.0, JSON Schema, RFC 6570, or the OAuth and HTTP RFCs such as 9728, 8414, 7591, 7636, 8707, 9449). Use when reviewing a PR, before merging a protocol fix, or when asked whether code complies with the spec.
---

# Spec compliance check

Use this to decide whether a change does what the spec says, no more and no
less. It applies to one commit at a time; a PR with several commits gets one
verdict per commit.

## 1. Get the spec text

Never quote the spec from memory, from an SDK, or from a summary. Clone the
spec repositories once, pin the commit, and grep them:

```bash
cd "$SCRATCH"
[ -d mcp-spec ] || git clone -q https://github.com/modelcontextprotocol/modelcontextprotocol mcp-spec
[ -d ext-tasks ] || git clone -q https://github.com/modelcontextprotocol/ext-tasks
git -C mcp-spec rev-parse --short HEAD
ls mcp-spec/docs/specification/          # 2024-11-05 ... 2026-07-28, draft
grep -rn "MUST respond with HTTP 400" mcp-spec/docs/specification/2025-11-25/basic/
grep -n "interface CallToolResult" -A20 mcp-spec/schema/2026-07-28/schema.ts
```

The `schema.ts` of a revision is normative for message shapes; the prose is
normative for behaviour. Read both. The tasks extension lives in
`ext-tasks/specification/<revision>/`. RFCs come from
`https://www.rfc-editor.org/rfc/rfcNNNN.txt`; drafts from
datatracker.ietf.org, naming the revision checked.

## 2. Check the claim

For each commit:

1. Find every spec sentence the commit message or PR body quotes. Confirm it
   is verbatim, in the section cited, and in the revision cited.
2. Read the whole section around it, not only the sentence: exceptions,
   "unless", and the matching rule for the other role (client and server,
   requester and receiver) are usually a paragraph away.
3. Note the requirement level: MUST / MUST NOT is a fix; SHOULD needs a
   reason not to; MAY is a choice, so the change must say why it is worth
   it.
4. Check the error code, HTTP status and action (JSON-RPC error, `isError`
   result, 400, 401 with `WWW-Authenticate`, 403, 404 on an unknown session,
   ignore) match the text exactly.
5. Check which revisions the rule applies to. A method, field or error code
   that exists in one revision must not leak into another: compare the same
   section across `docs/specification/*/` and decide per revision.
6. Check the code does what the text says on every path that reaches it:
   legacy and modern era, Streamable HTTP and stdio, server and client, POST
   and GET, inside a session and stateless.
7. Check it does not go further than the spec: rejecting what the spec allows
   breaks interop with peers that are allowed to do it.

## 3. Check the test

- The test fails on main without the fix and passes with it. Run it both
  ways.
- It asserts the outcome the spec names (the error code, the status, the
  field), and cannot also pass on a crash or a missing result.
- When the conformance runner has a scenario for the rule, it passes in
  `make conformance`.

## 4. Report

One line per commit:

```
<sha> <subject>
  spec: MCP 2025-11-25 server/tools MUST, quote verified | quote not found | paraphrased
  revisions: applies to 2025-06-18, 2025-11-25; absent before | all
  verdict: compliant | partial (<what is missing>) | wrong (<why>) | not a spec item (<what it is>)
  test: fails before, passes after | does not discriminate | missing
```

Then list anything that needs the maintainer's decision (a SHOULD left out,
a deliberate deviation).
