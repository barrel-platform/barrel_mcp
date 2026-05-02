# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Spec-conformant MCP client** (`barrel_mcp_client`)
  - Rewritten as a `gen_statem` (`connecting` → `initializing` → `ready` → `closing`).
  - Async transports forward inbound JSON-RPC envelopes as `{mcp_in, _, _}` messages.
  - Streamable HTTP client transport (`barrel_mcp_client_http`): POST with `application/json, text/event-stream`, parses SSE from POST and from a long-lived GET stream, captures `Mcp-Session-Id`, sends `MCP-Protocol-Version` after init, DELETE on close, 401 retry through pluggable auth.
  - Stdio client transport (`barrel_mcp_client_stdio`) extracted into its own gen_server.
  - Targets MCP `2025-11-25` and negotiates downward through `2025-06-18`, `2025-03-26`, `2024-11-05`.
  - Server-initiated requests/notifications routed through a `barrel_mcp_client_handler` behaviour with sync, error, and async reply forms; default no-op handler ships in `barrel_mcp_client_handler_default`.
  - Capability-shaped initialize payload (booleans become spec objects on the wire).
  - Resource subscription notifications routed back to the subscribing process.
  - Pagination, cancellation, and progress-token plumbing on `tools/call`.
- **Federation registry** (`barrel_mcp_clients`): one supervised connection per server id, looked up via `barrel_mcp:start_client/2`, `whereis_client/1`, `list_clients/0`, `stop_client/1`.
- **Auth behaviour** (`barrel_mcp_client_auth`) with a static-bearer implementation; OAuth 2.1 + PKCE planned for a follow-up.
- **JSON-RPC envelope helpers** (`encode_request/3`, `encode_notification/2`, `encode_response/2`, `encode_error/3`, `decode_envelope/1`) shared between client and server.
- New tests: `barrel_mcp_client_tests` (loopback handshake / call_tool / version downgrade), `barrel_mcp_client_handler_tests`, `barrel_mcp_clients_tests`, `barrel_mcp_protocol_envelope_tests`.
- New doc: `guides/features.md` summarising the client surface and roadmap.

### Changed

- `notifications/initialized` is now the spec name; legacy bare `initialized` still accepted for one release.
- CORS on `barrel_mcp_http_stream` exposes `mcp-protocol-version` and `last-event-id`.

### Added (ergonomics)

- `barrel_mcp_pagination:walk/1,2`: cursor walker shared by every `*/list` paged helper, with a configurable max-pages guard.
- `barrel_mcp_client:list_tools_all/1`, `list_resources_all/1`, `list_resource_templates_all/1`, `list_prompts_all/1`: walk every page and return the union.
- `barrel_mcp_schema:validate/2`: minimal JSON Schema validator covering type/properties/required/enum/items/oneOf/anyOf/allOf/min-max-length/pattern/min-max-items/uniqueItems/min-max/exclusive bounds. Returns `ok` or `{error, [{Path, Reason}]}`. Hosts use it to pre-flight LLM-generated tool args before calling the server.

### Added (control plane)

- Progress dispatch: when a caller passes `progress_token` to `call_tool/4`, the client registers the caller pid against that token and routes inbound `notifications/progress` to it as `{mcp_progress, Token, Params}`. The mapping clears automatically when the request settles, is cancelled, or times out.
- Periodic ping: `ping_interval` (default `infinity`, opt-in) sends `ping` while in `ready`. After `ping_failure_threshold` consecutive failures (default `3`), the connection closes with reason `ping_failed`.

### Added (auth)

- `barrel_mcp_client_auth_oauth`: OAuth 2.1 + PKCE per the MCP authorization spec.
  - Discovery helpers hosts can use during initial token acquisition: `parse_www_authenticate/1`, `discover_protected_resource/1` (RFC 9728), `discover_authorization_server/1` (RFC 8414, with OpenID Connect fallback).
  - PKCE primitives: `gen_code_verifier/0`, `code_challenge/1` (S256), `build_authorization_url/2`.
  - Token endpoint: `exchange_code/2` (authorization-code grant) and `refresh_token/2` (refresh grant). Both honour the RFC 8707 `resource` parameter and support confidential-client HTTP Basic.
  - Behaviour implementation that attaches `Authorization: Bearer ...` and refreshes transparently on 401 when a `refresh_token` was supplied.
- `barrel_mcp_client_auth:new({oauth, Config})` is now wired through; `Config` accepts `access_token` (required), `refresh_token`, `token_endpoint`, `client_id`, `client_secret`, `resource`, `scopes`. The interactive authorization-code redirect step stays a host concern; once the host has tokens it hands them to the client and the library handles refresh.

## [1.1.0] - 2025-01-27

### Added

- **MCP Streamable HTTP Transport** (`barrel_mcp_http_stream`)
  - Protocol version 2025-03-26 support for Claude Code integration
  - POST with JSON or SSE streaming responses
  - GET for server-to-client notification streams (SSE)
  - DELETE for session termination
  - OPTIONS for CORS preflight
  - HTTPS/TLS support
  - See `guides/http-stream.md` for usage

- **Session Management** (`barrel_mcp_session`)
  - ETS-based session tracking for Streamable HTTP transport
  - Sessions identified via `Mcp-Session-Id` header
  - Configurable TTL with automatic cleanup (default: 30 minutes)
  - SSE stream lifecycle management

- **Custom Authentication Provider** (`barrel_mcp_auth_custom`)
  - Simplified interface for custom authentication modules
  - Only requires `init/1` and `authenticate/2` callbacks
  - Automatically extracts tokens from Bearer and X-API-Key headers
  - See `guides/custom-authentication.md` for usage

### Changed

- Protocol version updated to `2025-03-26` for Streamable HTTP transport
- Supervisor now includes session manager child spec
- Added `crypto` to application dependencies

## [1.0.0] - 2025-12-29

Initial release of barrel_mcp, an Erlang implementation of the Model Context Protocol (MCP) 2024-11-05.

### Added

#### Core Features
- **Tools** - Register and call tools with JSON Schema validation
- **Resources** - Register and read resources with URI-based addressing
- **Prompts** - Register and retrieve prompts with argument substitution
- **Registry** - ETS + persistent_term based handler registry for fast lookups

#### Transports
- **HTTP Transport** - Cowboy-based HTTP server for MCP over HTTP
- **stdio Transport** - stdin/stdout transport for Claude Desktop integration
  - Blocking mode via `start_stdio/0`
  - Supervised mode via `start_stdio_link/0`

#### Client
- **MCP Client** - Connect to external MCP servers
  - HTTP transport support via hackney
  - Tool listing and calling
  - Resource listing and reading
  - Prompt listing and retrieval

#### Authentication
- Pluggable authentication system via `barrel_mcp_auth` behaviour
- Built-in providers:
  - `barrel_mcp_auth_none` - No authentication (default)
  - `barrel_mcp_auth_bearer` - JWT/Bearer token authentication (HS256 built-in)
  - `barrel_mcp_auth_apikey` - API key authentication
  - `barrel_mcp_auth_basic` - HTTP Basic authentication
- Scope-based authorization
- Constant-time credential comparison

#### Documentation
- Comprehensive EDoc documentation for all public APIs
- HexDocs integration via rebar3_ex_doc
- Guides:
  - Getting Started
  - stdio Transport
  - Authentication
  - Tools, Resources & Prompts
  - MCP Client

### Protocol Support
- JSON-RPC 2.0
- MCP 2024-11-05 specification
- Methods: initialize, ping, tools/list, tools/call, resources/list, resources/read, prompts/list, prompts/get

[1.0.0]: https://github.com/barrel-db/barrel_mcp/releases/tag/v1.0.0
