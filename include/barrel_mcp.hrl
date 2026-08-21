%%%-------------------------------------------------------------------
%%% @doc barrel_mcp shared types and macros
%%% @end
%%%-------------------------------------------------------------------

-ifndef(BARREL_MCP_HRL).
-define(BARREL_MCP_HRL, true).

%% Protocol version registry.
%%
%% MCP has two eras. "Modern" revisions (2026-07-28 and later) are
%% stateless: every request carries its own protocol version, client
%% capabilities and identity in `_meta', and there is no handshake.
%% "Legacy" revisions (2025-11-25 and earlier) establish that state
%% with an `initialize' handshake. This library serves both, and the
%% era is decided per request, not per deployment.
%%
%% The roles below mirror the reference Python SDK's version module,
%% which splits the same way (its `HANDSHAKE_PROTOCOL_VERSIONS' is our
%% legacy list). The vocabulary here follows the specification, which
%% calls those revisions "Legacy".
%%
%% Revisions are an enumerated set, not an ordered scalar. They happen
%% to be date-shaped today and so happen to sort, but a future
%% identifier need not be, and an unrecognised peer string must not
%% accidentally compare as newer than everything. Nothing here orders
%% versions by comparing them; use `barrel_mcp_version:is_at_least/2'.

%% Every released revision, oldest to newest.
-define(MCP_KNOWN_VERSIONS, [
    <<"2024-11-05">>,
    <<"2025-03-26">>,
    <<"2025-06-18">>,
    <<"2025-11-25">>,
    <<"2026-07-28">>
]).

%% Modern (per-request metadata) revisions, newest first.
-define(MCP_MODERN_VERSIONS, [<<"2026-07-28">>]).
%% Legacy (handshake-based) revisions, newest first.
-define(MCP_LEGACY_VERSIONS, [
    <<"2025-11-25">>, <<"2025-06-18">>, <<"2025-03-26">>, <<"2024-11-05">>
]).
%% Every revision this library speaks, newest first. Advertised by
%% `server/discover' and listed as `supported' on an
%% UnsupportedProtocolVersion error only when the `advertise_versions'
%% env is `all'; see `barrel_mcp_protocol:advertised_versions/0'.
-define(MCP_ALL_VERSIONS, ?MCP_MODERN_VERSIONS ++ ?MCP_LEGACY_VERSIONS).

%% Newest revision of any era.
-define(MCP_LATEST_VERSION, <<"2026-07-28">>).
%% Newest revision reachable through the handshake: the client's
%% `initialize' offer and the server's counter-offer when it cannot
%% honour what was asked for. Must stay a legacy revision, since a
%% modern one cannot be negotiated that way.
-define(MCP_LATEST_LEGACY_VERSION, <<"2025-11-25">>).
%% Newest stateless revision: the `server/discover' probe default.
-define(MCP_LATEST_MODERN_VERSION, <<"2026-07-28">>).
%% Oldest revision still negotiable through the handshake.
-define(MCP_OLDEST_VERSION, <<"2024-11-05">>).

%% Revisions the client accepts back from an `initialize' response.
-define(MCP_CLIENT_SUPPORTED_VERSIONS, ?MCP_LEGACY_VERSIONS).
%% Revisions the server accepts on the `MCP-Protocol-Version' header of
%% a legacy request.
-define(MCP_SUPPORTED_VERSIONS, ?MCP_LEGACY_VERSIONS).

%% Methods the 2026-07-28 revision removed. They stay available to
%% legacy clients and are simply unknown to modern ones: `ping' and
%% `logging/setLevel' have no replacement, `resources/subscribe' is
%% subsumed by `subscriptions/listen', and the blocking task methods
%% are replaced by the tasks extension.
-define(LEGACY_ONLY_METHODS, [
    <<"initialize">>,
    <<"ping">>,
    <<"logging/setLevel">>,
    <<"resources/subscribe">>,
    <<"resources/unsubscribe">>,
    <<"tasks/list">>,
    <<"tasks/result">>
]).

%% Methods this revision introduced. They have no meaning to a client
%% that negotiated an older one, which has `resources/subscribe' and
%% the standalone GET stream instead.
-define(MODERN_ONLY_METHODS, [
    <<"subscriptions/listen">>,
    %% From the tasks extension, which replaced the blocking
    %% `tasks/result' with polling plus this.
    <<"tasks/update">>
]).

%% Reserved `_meta' keys (MCP 2026-07-28).
-define(MCP_META_PROTOCOL_VERSION, <<"io.modelcontextprotocol/protocolVersion">>).
-define(MCP_META_CLIENT_INFO, <<"io.modelcontextprotocol/clientInfo">>).
-define(MCP_META_CLIENT_CAPABILITIES, <<"io.modelcontextprotocol/clientCapabilities">>).
-define(MCP_META_LOG_LEVEL, <<"io.modelcontextprotocol/logLevel">>).
-define(MCP_META_SERVER_INFO, <<"io.modelcontextprotocol/serverInfo">>).
-define(MCP_META_SUBSCRIPTION_ID, <<"io.modelcontextprotocol/subscriptionId">>).

%% Official extension identifiers, negotiated through the `extensions'
%% field of client and server capabilities.
-define(MCP_EXT_TASKS, <<"io.modelcontextprotocol/tasks">>).

%% JSON-RPC Error Codes
-define(JSONRPC_PARSE_ERROR, -32700).
-define(JSONRPC_INVALID_REQUEST, -32600).
-define(JSONRPC_METHOD_NOT_FOUND, -32601).
-define(JSONRPC_INVALID_PARAMS, -32602).
-define(JSONRPC_INTERNAL_ERROR, -32603).

%% MCP-specific error codes.
%%
%% `-32002' is not ours to allocate: it has meant "resource not found"
%% since 2024-11-05, so it keeps that meaning here. A crashed prompt
%% handler is an internal error and uses `?JSONRPC_INTERNAL_ERROR'.
%%
%% `-32000' / `-32001' predate the 2026-07-28 error-code allocation
%% policy and are grandfathered by it, so they keep their values and
%% existing clients matching on them are unaffected.
-define(MCP_TOOL_ERROR, -32000).
-define(MCP_RESOURCE_ERROR, -32001).
%% Resource not found, per MCP 2025-11-25 and earlier. The 2026-07-28
%% revision replaces this with `?JSONRPC_INVALID_PARAMS'.
-define(MCP_RESOURCE_NOT_FOUND, -32002).

%% Error codes defined by MCP 2026-07-28. That revision reserves
%% -32020..-32099 for the specification: never emit a code in this
%% range that the spec does not define.
-define(MCP_HEADER_MISMATCH, -32020).
-define(MCP_MISSING_CLIENT_CAPABILITY, -32021).
-define(MCP_UNSUPPORTED_PROTOCOL_VERSION, -32022).

%% Handler types
-type handler_type() ::
    tool
    | resource
    | prompt
    | resource_template
    | completion.

%% Tool definition
-type tool_def() :: #{
    module := module(),
    function := atom(),
    description => binary(),
    input_schema => map()
}.

%% Resource definition
-type resource_def() :: #{
    module := module(),
    function := atom(),
    name := binary(),
    uri := binary(),
    description => binary(),
    mime_type => binary()
}.

%% Prompt definition
-type prompt_def() :: #{
    module := module(),
    function := atom(),
    name := binary(),
    description => binary(),
    arguments => [prompt_arg()]
}.

-type prompt_arg() :: #{
    name := binary(),
    description => binary(),
    required => boolean()
}.

%% MCP Content types
-type text_content() :: #{
    % <<"text">>
    type := binary(),
    text := binary()
}.

-type image_content() :: #{
    % <<"image">>
    type := binary(),
    data := binary(),
    mimeType := binary()
}.

-type resource_content() :: #{
    % <<"resource">>
    type := binary(),
    resource := #{
        uri := binary(),
        text => binary(),
        blob => binary(),
        mimeType => binary()
    }
}.

-type mcp_content() :: text_content() | image_content() | resource_content().

%% Registry key for persistent_term
-define(REGISTRY_KEY, barrel_mcp_handlers).
%% Union of the `Mcp-Param-{Name}' headers registered tools ask for,
%% kept in step with the registry so CORS can enumerate them without
%% walking every handler on every response.
-define(PARAM_HEADERS_KEY, barrel_mcp_param_headers).

%% ETS table name
-define(REGISTRY_TABLE, barrel_mcp_registry).

-endif.
