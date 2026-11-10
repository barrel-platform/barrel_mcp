# Versioning

This page says what a barrel_mcp version number promises: what can change
in a patch, a minor and a major release, and how deprecations are handled.
Read it before you pick a version constraint, or before you open a pull
request that changes public behaviour.

## Version numbers

barrel_mcp follows [Semantic Versioning](https://semver.org). Releases are
published on hex as `barrel_mcp` and tagged `vX.Y.Z` on GitHub, and every
release has a CHANGELOG section.

The public API is what the guides and module docs describe: the `barrel_mcp`
facade, `barrel_mcp_client`, the auth provider and client handler behaviours,
the documented options and return shapes, and the wire behaviour for each
supported protocol revision. Undocumented functions and internal modules can
change in any release.

Pick the range that matches how much change you accept:

```erlang
{barrel_mcp, "~> 4.5"}    %% any 4.x from 4.5.0: features and new revisions
{barrel_mcp, "~> 4.5.0"}  %% 4.5.x only: fixes
```

## What each release can change

| Release | Can contain |
|---|---|
| Patch (`4.5.x`) | Bug fixes, spec fixes that do not refuse a working setup, dependency bumps within the current ranges, docs |
| Minor (`4.x.0`) | New features and options, new MCP protocol revisions (added next to the existing ones), and refusing a setup a specification already disallows, always with an option that restores the old behaviour |
| Major (`x.0.0`) | Removing or renaming a public function, option or callback, changing a documented return shape, dropping a protocol revision, or a dependency change the host has to act on |

A major release lists every breaking change under **Breaking** in the
CHANGELOG, with what to change in your code. A minor release that refuses a
setup lists it under **Changed**, with the option that brings the old
behaviour back (4.5.0 did this for OAuth servers on private addresses and
cleartext listeners with auth).

## Protocol revisions

Every released MCP revision stays negotiable once it is supported. A new
revision is added in a minor release next to the old ones. Dropping one is a
major release.

## Deprecations

When the MCP specification deprecates a feature, barrel_mcp keeps serving it
to clients on the revisions that have it, and lists it under **Deprecated**
in the CHANGELOG. When barrel_mcp deprecates one of its own functions or
options, the module docs and the CHANGELOG say what replaces it, and it keeps
working until the next major release.

## Support

Fixes go to the latest minor release. See [SECURITY.md](../SECURITY.md) for
the supported versions and the OTP releases to run on.
