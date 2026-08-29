# Pending features

Design notes for features that are **not yet implemented** and likely
worth doing. Each entry is sized to be picked up as one focused PR.

**Nothing is pending as of 3.0.0.** The last entry here, Dynamic Client
Registration (RFC 7591), shipped and has since been deprecated by the
specification in favour of Client ID Metadata Documents, which shipped
alongside it. See [Client registration](../guides/authentication.md#client-registration).

Where to look instead:

- **What the library speaks today**, per protocol revision and era:
  [Protocol Versions](../guides/protocol-versions.md).
- **What the specification deprecated**, and what replaces it: the
  Deprecated section of [`CHANGELOG.md`](../CHANGELOG.md).
- **What is deliberately out of scope**: durable multi-node task
  storage. Tasks stay node-local. The JSON Schema validator does not
  implement ECMAScript regex property escapes or `$vocabulary` switching
  keyword sets off; both are recorded in the schema suite's skip list.

If you want something prioritised, open an issue.
