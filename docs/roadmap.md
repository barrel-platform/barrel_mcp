# Roadmap

This page lists the work planned for barrel_mcp, so you can see what is
coming and what a newer specification version will change. Each item is a
concrete piece of work with the version of the spec it moves to. The
specification list itself, with the version the code follows today, is in
[AGENTS.md](../AGENTS.md#specifications).

barrel_mcp implements every released MCP revision from `2024-11-05` through
`2026-07-28`, server and client, including the optional client features
(sampling, elicitation, roots) and the tasks extension. Conformance results
are published by the
[Conformance workflow](https://github.com/barrel-platform/barrel_mcp/actions/workflows/conformance.yml)
on every change to `main`.

## Specification updates

| Item | From | To | What changes |
|---|---|---|---|
| Tasks extension | `specification/draft` at `e4345978` | `specification/2026-07-28` | Diff the released text against the draft the code follows and apply every method, field and status change |
| JWT client assertion audience | RFC 7521, RFC 7523 | RFC 10070 | The `aud` of a `private_key_jwt` assertion; today it falls back to the token endpoint when the authorization server publishes no issuer |
| Client ID metadata documents | draft-ietf-oauth-client-id-metadata-document-00 | -03 | Document fields, fetch and validation rules |
| Next MCP revision | `2026-07-28` | the revision now in the spec repository's `draft` directory | Implemented as the draft settles, aiming to ship with the revision's release |

## Testing

| Item | Status |
|---|---|
| Bump the conformance runner from `0.2.0-alpha.11` to `0.2.0-alpha.12` | Planned |
| Land the upstream runner fix for task results ([conformance#473](https://github.com/modelcontextprotocol/conformance/pull/473)) and drop the local patch | Waiting on review |

## How items move

Each specification update is its own pull request, following "Keeping the
specifications current" in [AGENTS.md](../AGENTS.md#keeping-the-specifications-current).
When an item ships, it moves to the CHANGELOG and leaves this page.
