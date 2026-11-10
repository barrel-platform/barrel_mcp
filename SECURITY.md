# Security Policy

## Supported Versions

Security fixes are applied to the latest minor release on the `main` branch.

| Version | Supported |
| ------- | --------- |
| 4.4.x   | yes       |
| < 4.4   | no        |

## What is a security issue

Private reports are for problems that are not a deviation from a
specification barrel_mcp implements:

- code execution, including a value from the wire reaching a module or
  function call, or creating atoms;
- a request served without the authentication or authorization the
  configuration asks for: an auth provider bypassed, a token accepted for
  another audience or resource, tool, resource or prompt visibility or
  subscription checks skipped, a session or task reachable by an identity
  that did not create it, a request accepted from an `Origin` the
  configuration rejects;
- one session's or user's data (results, notifications, replayed events,
  task results, elicitation answers) reaching someone else;
- credentials, tokens, API keys or the request state key leaking into logs
  or error responses, or the client sending a token to a server it was not
  issued for;
- forged or replayed request state being accepted;
- barrel_mcp weakening TLS below what the configuration allows.

Authentication, authorization, `Origin` checks and token audience stay
security issues even where a specification describes the check.

## What is a bug

When the fix is to make barrel_mcp follow a specification it implements
(MCP, its tasks extension, JSON-RPC, JSON Schema, the OAuth and HTTP RFCs
listed in [AGENTS.md](AGENTS.md#specifications)), it is a bug, even when
described as denial of service, memory exhaustion or a remote crash.
Report it as a public bug and cite the specification section; see
[Security issues and specification bugs](CONTRIBUTING.md#security-issues-and-specification-bugs).
We don't publish advisories or request CVEs for these, and advisories filed
for them are closed as bugs with a link to the fix.

Write the report in plain English, with a minimal reproduction, as described
in [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it).

## Reporting a Vulnerability

Please report suspected vulnerabilities privately through GitHub's
[Private Vulnerability Reporting](https://github.com/barrel-platform/barrel_mcp/security/advisories/new).

Do not open public issues or pull requests for security problems.

When reporting, include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- Affected versions and platform details.
- Any suggested fix or mitigation.

You can expect an initial acknowledgement within 7 days. We will work with
you on a fix and coordinate disclosure once a patched release is available.
Credit will be given in the advisory unless you prefer to remain anonymous.
