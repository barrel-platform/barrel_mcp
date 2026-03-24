# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
