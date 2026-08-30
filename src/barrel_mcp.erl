%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Main API module for barrel_mcp.
%%%
%%% This module provides the primary public interface for the barrel_mcp
%%% library, implementing the Model Context Protocol (MCP) specification.
%%%
%%% == Overview ==
%%%
%%% barrel_mcp allows you to expose tools, resources, and prompts that
%%% AI assistants (like Claude) can interact with. The library supports
%%% both server mode (exposing your functionality) and client mode
%%% (consuming external MCP servers).
%%%
%%% == Quick Start ==
%%%
%%% ```
%%% %% Start the application
%%% application:ensure_all_started(barrel_mcp).
%%%
%%% %% Register a simple tool
%%% barrel_mcp:reg_tool(<<"greet">>, my_module, greet_handler, #{
%%%     description => <<"Greet someone by name">>
%%% }).
%%%
%%% %% Start HTTP server
%%% {ok, _} = barrel_mcp:start_http(#{port => 9090}).
%%% '''
%%%
%%% == Handler Functions ==
%%%
%%% All handlers (tools, resources, prompts) must be exported functions
%%% with arity 1, receiving a map of arguments:
%%%
%%% ```
%%% -module(my_module).
%%% -export([greet_handler/1]).
%%%
%%% greet_handler(Args) ->
%%%     Name = maps:get(<<"name">>, Args, <<"World">>),
%%%     <<"Hello, ", Name/binary, "!">>.
%%% '''
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp).

-include("barrel_mcp.hrl").

%% Tool API
-export([
    reg_tool/4,
    unreg_tool/1,
    call_tool/2,
    list_tools/0
]).

%% Resource API
-export([
    reg_resource/4,
    unreg_resource/1,
    read_resource/1,
    list_resources/0,
    %% Resource templates (RFC 6570 URI templates).
    reg_resource_template/4,
    unreg_resource_template/1,
    list_resource_templates/0
]).

%% Prompt API
-export([
    reg_prompt/4,
    unreg_prompt/1,
    get_prompt/2,
    list_prompts/0
]).

%% Completion API
-export([
    reg_completion/4,
    unreg_completion/1
]).

%% Server API
-export([
    start_http/1,
    stop_http/0,
    start_http_stream/1,
    stop_http_stream/0,
    start_stdio/0,
    start_stdio_link/0
]).

%% Backward compatible aliases
-export([
    reg/4,
    unreg/1,
    run/2,
    all/0,
    find/1
]).

%% Server-to-client primitives (sampling + resource notifications +
%% progress + list-changed).
-export([
    sampling_create_message/3,
    list_sessions_with_sampling/0,
    elicit_create/3,
    elicit_form/2,
    elicit_url/3,
    elicit_complete/2,
    list_sessions_with_elicitation/0,
    roots_list/1,
    roots_list/2,
    list_sessions_with_roots/0,
    notify_resource_updated/1,
    notify_resource_updated/2,
    notify_progress/3,
    notify_progress/4,
    notify_log/3,
    notify_log/4,
    notify_list_changed/1,
    input/2,
    log/3,
    log/4,
    request_state/1,
    client_supports/2
]).

%% MCP client API (connecting to remote MCP servers).
-export([
    start_client/2,
    stop_client/1,
    whereis_client/1,
    list_clients/0
]).

%%====================================================================
%% Tool API
%%====================================================================

%% @doc Register a tool with the MCP server.
%%
%% Tools are functions that AI assistants can call to perform actions
%% or retrieve information. Each tool has a unique name and a handler
%% function that processes requests.
%%
%% == Options ==
%%
%% <ul>
%%   <li>`description' - Human-readable description of the tool</li>
%%   <li>`input_schema' - JSON Schema defining expected input format</li>
%%   <li>`annotations' - Map of MCP behavioural hints surfaced under
%%       `annotations' on `tools/list'. Spec keys are
%%       `readOnlyHint', `destructiveHint', `idempotentHint',
%%       `openWorldHint' (all booleans). Values pass through verbatim.</li>
%% </ul>
%%
%% == Handler Return Values ==
%%
%% The handler function can return:
%% <ul>
%%   <li>`binary()' - Returned as text content</li>
%%   <li>`map()' - Automatically JSON encoded</li>
%%   <li>`[map()]' - List of content blocks</li>
%% </ul>
%%
%% == Example ==
%%
%% ```
%% barrel_mcp:reg_tool(<<"search">>, my_mod, search, #{
%%     description => <<"Search the database">>,
%%     input_schema => #{
%%         <<"type">> => <<"object">>,
%%         <<"properties">> => #{
%%             <<"query">> => #{<<"type">> => <<"string">>}
%%         },
%%         <<"required">> => [<<"query">>]
%%     }
%% }).
%% '''
%%
%% @param Name Unique tool name (binary)
%% @param Module Module containing the handler function
%% @param Function Handler function name (must be exported with arity 1)
%% @param Opts Registration options
%% @returns `ok' on success, `{error, Reason}' on failure
-spec reg_tool(Name, Module, Function, Opts) -> ok | {error, term()} when
    Name :: binary(),
    Module :: module(),
    Function :: atom(),
    Opts :: #{
        description => binary(),
        input_schema => map(),
        annotations => map(),
        _ => _
    }.
reg_tool(Name, Module, Function, Opts) ->
    barrel_mcp_registry:reg(tool, Name, Module, Function, Opts).

%% @doc Unregister a tool.
%%
%% Removes a previously registered tool from the MCP server.
%% After unregistration, the tool will no longer appear in
%% `tools/list' responses.
%%
%% @param Name The tool name to unregister
%% @returns `ok'
-spec unreg_tool(Name :: binary()) -> ok.
unreg_tool(Name) ->
    barrel_mcp_registry:unreg(tool, Name).

%% @doc Call a tool locally.
%%
%% Executes a registered tool handler with the given arguments.
%% Useful for testing tools without going through the MCP protocol.
%%
%% == Example ==
%%
%% ```
%% {ok, Result} = barrel_mcp:call_tool(<<"search">>, #{
%%     <<"query">> => <<"erlang">>
%% }).
%% '''
%%
%% @param Name Tool name to call
%% @param Args Map of arguments to pass to the handler
%% @returns `{ok, Result}' on success, `{error, Reason}' on failure
-spec call_tool(Name :: binary(), Args :: map()) -> {ok, term()} | {error, term()}.
call_tool(Name, Args) ->
    barrel_mcp_registry:run(tool, Name, Args).

%% @doc List all registered tools.
%%
%% Returns a list of tuples containing tool names and their metadata.
%%
%% == Example ==
%%
%% ```
%% Tools = barrel_mcp:list_tools(),
%% %% Returns: [{<<"search">>, #{description => ...}}, ...]
%% '''
%%
%% @returns List of `{Name, Metadata}' tuples
-spec list_tools() -> [{binary(), map()}].
list_tools() ->
    barrel_mcp_registry:all(tool).

%%====================================================================
%% Resource API
%%====================================================================

%% @doc Register a resource with the MCP server.
%%
%% Resources expose data that AI assistants can read, such as
%% configuration files, database records, or dynamic content.
%%
%% == Options ==
%%
%% <ul>
%%   <li>`name' - Human-readable resource name</li>
%%   <li>`uri' - Unique resource URI (e.g., `<<"file:///config">>')</li>
%%   <li>`description' - Resource description</li>
%%   <li>`mime_type' - MIME type (default: `<<"text/plain">>')</li>
%% </ul>
%%
%% == Handler Return Values ==
%%
%% <ul>
%%   <li>`binary()' - Text content</li>
%%   <li>`map()' - JSON content (auto-encoded)</li>
%%   <li>`#{blob => binary(), mimeType => binary()}' - Binary content</li>
%% </ul>
%%
%% == Example ==
%%
%% ```
%% barrel_mcp:reg_resource(<<"config">>, my_mod, get_config, #{
%%     name => <<"App Configuration">>,
%%     uri => <<"config://app/settings">>,
%%     description => <<"Current application settings">>,
%%     mime_type => <<"application/json">>
%% }).
%% '''
%%
%% @param Name Internal resource identifier
%% @param Module Module containing the handler function
%% @param Function Handler function name
%% @param Opts Registration options
%% @returns `ok' on success, `{error, Reason}' on failure
-spec reg_resource(Name, Module, Function, Opts) -> ok | {error, term()} when
    Name :: binary(),
    Module :: module(),
    Function :: atom(),
    Opts :: #{
        name => binary(),
        uri => binary(),
        description => binary(),
        mime_type => binary()
    }.
reg_resource(Name, Module, Function, Opts) ->
    barrel_mcp_registry:reg(resource, Name, Module, Function, Opts).

%% @doc Unregister a resource.
%%
%% @param Name The resource identifier to unregister
%% @returns `ok'
-spec unreg_resource(Name :: binary()) -> ok.
unreg_resource(Name) ->
    barrel_mcp_registry:unreg(resource, Name).

%% @doc Read a resource locally.
%%
%% Executes the resource handler and returns its content.
%%
%% @param Name Resource identifier
%% @returns `{ok, Content}' on success, `{error, Reason}' on failure
-spec read_resource(Name :: binary()) -> {ok, term()} | {error, term()}.
read_resource(Name) ->
    barrel_mcp_registry:run(resource, Name, #{}).

%% @doc List all registered resources.
%%
%% @returns List of `{Name, Metadata}' tuples
-spec list_resources() -> [{binary(), map()}].
list_resources() ->
    barrel_mcp_registry:all(resource).

%% @doc Register a resource template (RFC 6570 URI template).
%%
%% Resource templates surface as `resources/templates/list' on the
%% wire and let clients discover URI patterns the server can serve
%% via `resources/read'.
%%
%% Options:
%% <ul>
%%   <li>`name': display name.</li>
%%   <li>`uri_template': RFC 6570 URI template (e.g.
%%       `<<"file:///{path}">>').</li>
%%   <li>`description': human-readable description.</li>
%%   <li>`mime_type': content type (default `<<"text/plain">>').</li>
%% </ul>
-spec reg_resource_template(Name, Module, Function, Opts) -> ok | {error, term()} when
    Name :: binary(),
    Module :: module(),
    Function :: atom(),
    Opts :: #{
        name => binary(),
        uri_template => binary(),
        description => binary(),
        mime_type => binary()
    }.
reg_resource_template(Name, Module, Function, Opts) ->
    barrel_mcp_registry:reg(resource_template, Name, Module, Function, Opts).

%% @doc Unregister a resource template.
-spec unreg_resource_template(Name :: binary()) -> ok.
unreg_resource_template(Name) ->
    barrel_mcp_registry:unreg(resource_template, Name).

%% @doc List all registered resource templates.
-spec list_resource_templates() -> [{binary(), map()}].
list_resource_templates() ->
    barrel_mcp_registry:all(resource_template).

%%====================================================================
%% Prompt API
%%====================================================================

%% @doc Register a prompt with the MCP server.
%%
%% Prompts are pre-defined conversation templates that AI assistants
%% can use. They support arguments for dynamic content generation.
%%
%% == Options ==
%%
%% <ul>
%%   <li>`description' - Prompt description</li>
%%   <li>`arguments' - List of argument definitions</li>
%% </ul>
%%
%% Each argument definition is a map with:
%% <ul>
%%   <li>`name' - Argument name (binary)</li>
%%   <li>`description' - Argument description</li>
%%   <li>`required' - Whether the argument is required (boolean)</li>
%% </ul>
%%
%% == Handler Return Value ==
%%
%% The handler must return a map with:
%% <ul>
%%   <li>`description' - Prompt description</li>
%%   <li>`messages' - List of message maps with `role' and `content'</li>
%% </ul>
%%
%% == Example ==
%%
%% ```
%% barrel_mcp:reg_prompt(<<"summarize">>, my_mod, summarize, #{
%%     description => <<"Summarize content">>,
%%     arguments => [
%%         #{name => <<"content">>, description => <<"Text to summarize">>, required => true},
%%         #{name => <<"style">>, description => <<"Summary style">>, required => false}
%%     ]
%% }).
%% '''
%%
%% @param Name Unique prompt name
%% @param Module Module containing the handler
%% @param Function Handler function name
%% @param Opts Registration options
%% @returns `ok' on success, `{error, Reason}' on failure
-spec reg_prompt(Name, Module, Function, Opts) -> ok | {error, term()} when
    Name :: binary(),
    Module :: module(),
    Function :: atom(),
    Opts :: #{
        description => binary(),
        arguments => [#{name := binary(), description => binary(), required => boolean()}]
    }.
reg_prompt(Name, Module, Function, Opts) ->
    barrel_mcp_registry:reg(prompt, Name, Module, Function, Opts).

%% @doc Unregister a prompt.
%%
%% @param Name The prompt name to unregister
%% @returns `ok'
-spec unreg_prompt(Name :: binary()) -> ok.
unreg_prompt(Name) ->
    barrel_mcp_registry:unreg(prompt, Name).

%% @doc Get a prompt with arguments filled in.
%%
%% Executes the prompt handler with the provided arguments and
%% returns the generated messages.
%%
%% @param Name Prompt name
%% @param Args Map of argument values
%% @returns `{ok, PromptResult}' on success, `{error, Reason}' on failure
-spec get_prompt(Name :: binary(), Args :: map()) -> {ok, term()} | {error, term()}.
get_prompt(Name, Args) ->
    barrel_mcp_registry:run(prompt, Name, Args).

%% @doc List all registered prompts.
%%
%% @returns List of `{Name, Metadata}' tuples
-spec list_prompts() -> [{binary(), map()}].
list_prompts() ->
    barrel_mcp_registry:all(prompt).

%%====================================================================
%% Completion API
%%====================================================================

%% @doc Register a completion handler for a prompt argument or a
%% resource-template argument. Handlers receive `(PartialValue, Ctx)'
%% and return `{ok, [Suggestion]}' or
%% `{ok, [Suggestion], #{has_more => true}}'.
-spec reg_completion(Ref, Module, Function, Opts) -> ok | {error, term()} when
    Ref ::
        {prompt, binary(), binary()}
        | {resource_template, binary(), binary()},
    Module :: module(),
    Function :: atom(),
    Opts :: map().
reg_completion({prompt, PromptName, ArgName}, Module, Function, Opts) when
    is_binary(PromptName), is_binary(ArgName)
->
    Key = completion_key(prompt, PromptName, ArgName),
    barrel_mcp_registry:reg(completion, Key, Module, Function, Opts);
reg_completion({resource_template, TemplateUri, ArgName}, Module, Function, Opts) when
    is_binary(TemplateUri), is_binary(ArgName)
->
    Key = completion_key(resource_template, TemplateUri, ArgName),
    barrel_mcp_registry:reg(completion, Key, Module, Function, Opts).

-spec unreg_completion(term()) -> ok.
unreg_completion({prompt, PromptName, ArgName}) ->
    barrel_mcp_registry:unreg(
        completion,
        completion_key(prompt, PromptName, ArgName)
    );
unreg_completion({resource_template, TemplateUri, ArgName}) ->
    barrel_mcp_registry:unreg(
        completion,
        completion_key(
            resource_template,
            TemplateUri,
            ArgName
        )
    ).

completion_key(Kind, Outer, Arg) ->
    K =
        case Kind of
            prompt -> <<"prompt">>;
            resource_template -> <<"resource_template">>
        end,
    <<K/binary, ":", Outer/binary, ":", Arg/binary>>.

%%====================================================================
%% Server API
%%====================================================================

%% @doc Start the HTTP server for MCP.
%%
%% Starts a Cowboy HTTP server that handles MCP JSON-RPC requests.
%% The server listens for POST requests at `/mcp' and `/'.
%%
%% == Options ==
%%
%% <ul>
%%   <li>`port' - Port number (default: 9090)</li>
%%   <li>`ip' - IP address to bind (default: `{127, 0, 0, 1}')</li>
%%   <li>`auth' - Authentication configuration (see {@link barrel_mcp_auth})</li>
%% </ul>
%%
%% == Authentication Example ==
%%
%% ```
%% barrel_mcp:start_http(#{
%%     port => 9090,
%%     auth => #{
%%         provider => barrel_mcp_auth_bearer,
%%         provider_opts => #{
%%             secret => <<"your-jwt-secret">>,
%%             audience => <<"https://mcp.example.com">>
%%         }
%%     }
%% }).
%% '''
%%
%% @param Opts Server options
%% @returns `{ok, Pid}' on success, `{error, Reason}' on failure
%% @see barrel_mcp_http
%% @see barrel_mcp_auth
-spec start_http(Opts) -> {ok, pid()} | {error, term()} when
    Opts :: #{
        port => pos_integer(),
        ip => inet:ip_address(),
        auth => map(),
        acceptors => pos_integer(),
        max_connections => pos_integer(),
        max_requests => pos_integer() | infinity,
        max_body_bytes => pos_integer(),
        _ => _
    }.
start_http(Opts) ->
    barrel_mcp_http:start(Opts).

%% @doc Stop the HTTP server.
%%
%% Stops the MCP HTTP server if running.
%%
%% @returns `ok' on success, `{error, not_found}' if not running
-spec stop_http() -> ok | {error, not_found}.
stop_http() ->
    barrel_mcp_http:stop().

%% @doc Start the Streamable HTTP server for MCP.
%%
%% Starts an HTTP/1.1 and HTTP/2 listener (the `h1' and `h2' libraries)
%% implementing the MCP Streamable HTTP transport, serving every
%% revision from 2025-03-26 to 2026-07-28.
%% This transport supports:
%% - POST for client requests with JSON or SSE streaming responses
%% - GET for server-to-client notification streams (SSE)
%% - DELETE for session termination
%% - Session management via Mcp-Session-Id header
%%
%% This is the transport expected by Claude Code's `--transport http` option.
%%
%% == Options ==
%%
%% <dl>
%%   <dt>port</dt><dd>Port number (default: 9090)</dd>
%%   <dt>ip</dt><dd>IP address to bind (default: {127, 0, 0, 1}). A public bind needs allowed_origins.</dd>
%%   <dt>auth</dt><dd>Authentication configuration (see {@link barrel_mcp_auth})</dd>
%%   <dt>session_enabled</dt><dd>Enable session management (default: true)</dd>
%%   <dt>ssl</dt><dd>SSL/TLS configuration for HTTPS: certfile, keyfile, cacertfile (optional)</dd>
%%   <dt>acceptors</dt><dd>Accept loops (default: max(2, schedulers))</dd>
%%   <dt>max_connections</dt><dd>Established connections per listener (default: 16384)</dd>
%%   <dt>max_requests</dt><dd>Requests in flight per listener, 503 past it (default: 10000)</dd>
%%   <dt>max_body_bytes</dt><dd>Request body cap, 413 past it (default: 16 MiB)</dd>
%% </dl>
%%
%% == Example ==
%%
%% ```
%% %% Start with API key authentication
%% barrel_mcp:start_http_stream(#{
%%     port => 9090,
%%     auth => #{
%%         provider => barrel_mcp_auth_apikey,
%%         provider_opts => #{keys => [<<"my-api-key">>]}
%%     }
%% }).
%%
%% %% Start with HTTPS
%% barrel_mcp:start_http_stream(#{
%%     port => 9443,
%%     ssl => #{
%%         certfile => "/path/to/cert.pem",
%%         keyfile => "/path/to/key.pem"
%%     }
%% }).
%% '''
%%
%% == Claude Code Integration ==
%%
%% After starting the server, add it to Claude Code:
%% ```
%% claude mcp add my-server --transport http http://localhost:9090/mcp \
%%   --header "X-API-Key: my-api-key"
%% '''
%%
%% @param Opts Server options
%% @returns `{ok, Pid}' on success, `{error, Reason}' on failure
%% @see barrel_mcp_http_stream
%% @see barrel_mcp_auth
-spec start_http_stream(Opts) -> {ok, pid()} | {error, term()} when
    Opts :: #{
        port => pos_integer(),
        ip => inet:ip_address(),
        auth => map(),
        session_enabled => boolean(),
        ssl => #{
            certfile := string(),
            keyfile := string(),
            cacertfile => string()
        },
        acceptors => pos_integer(),
        max_connections => pos_integer(),
        max_requests => pos_integer() | infinity,
        max_body_bytes => pos_integer(),
        _ => _
    }.
start_http_stream(Opts) ->
    barrel_mcp_http_stream:start(Opts).

%% @doc Stop the Streamable HTTP server.
%%
%% Stops the MCP Streamable HTTP server if running.
%%
%% @returns `ok' on success, `{error, not_found}' if not running
-spec stop_http_stream() -> ok | {error, not_found}.
stop_http_stream() ->
    barrel_mcp_http_stream:stop().

%% @doc Start the stdio server for MCP.
%%
%% Starts an MCP server that communicates over stdin/stdout.
%% This is the transport used for Claude Desktop integration.
%%
%% <strong>Warning:</strong> This function blocks and runs the
%% read-handle-respond loop until the input stream closes.
%%
%% == Claude Desktop Configuration ==
%%
%% Configure your `claude_desktop_config.json':
%%
%% ```
%% {
%%%   "mcpServers": {
%%     "my-server": {
%%       "command": "/path/to/my_app",
%%       "args": ["mcp"]
%%     }
%%   }
%% }
%% '''
%%
%% @returns `ok' when the loop terminates
%% @see barrel_mcp_stdio
%% @see start_stdio_link/0
-spec start_stdio() -> ok.
start_stdio() ->
    barrel_mcp_stdio:start().

%% @doc Start the stdio server as a supervised gen_server.
%%
%% Starts an MCP stdio server that can be supervised. Unlike
%% {@link start_stdio/0}, this function returns immediately after
%% spawning the server process.
%%
%% The server registers locally as `barrel_mcp_stdio'.
%%
%% == Example ==
%%
%% ```
%% %% In your supervisor:
%% init([]) ->
%%     SupFlags = #{strategy => one_for_one},
%%     Children = [
%%         #{id => mcp_stdio,
%%           start => {barrel_mcp, start_stdio_link, []},
%%           restart => permanent,
%%           type => worker}
%%     ],
%%     {ok, {SupFlags, Children}}.
%% '''
%%
%% @returns `{ok, Pid}' on success, or `{error, Reason}' on failure
%% @see barrel_mcp_stdio
%% @see start_stdio/0
-spec start_stdio_link() -> {ok, pid()} | {error, term()}.
start_stdio_link() ->
    barrel_mcp_stdio:start_link().

%%====================================================================
%% Backward Compatible Aliases
%%====================================================================

%% @doc Register a tool (alias for {@link reg_tool/4}).
%% @deprecated Use {@link reg_tool/4} instead.
-spec reg(binary(), module(), atom(), map()) -> ok | {error, term()}.
reg(Name, Module, Function, Opts) ->
    reg_tool(Name, Module, Function, Opts).

%% @doc Unregister a tool (alias for {@link unreg_tool/1}).
%% @deprecated Use {@link unreg_tool/1} instead.
-spec unreg(binary()) -> ok.
unreg(Name) ->
    unreg_tool(Name).

%% @doc Call a tool (alias for {@link call_tool/2}).
%% @deprecated Use {@link call_tool/2} instead.
-spec run(binary(), map()) -> {ok, term()} | {error, term()}.
run(Name, Args) ->
    call_tool(Name, Args).

%% @doc List all tools (alias for {@link list_tools/0}).
%% @deprecated Use {@link list_tools/0} instead.
-spec all() -> [{binary(), map()}].
all() ->
    list_tools().

%% @doc Find a tool by name.
%%
%% Looks up a tool by name and returns its metadata if found.
%%
%% @param Name Tool name to find
%% @returns `{ok, Metadata}' if found, `error' otherwise
-spec find(Name :: binary()) -> {ok, map()} | error.
find(Name) ->
    barrel_mcp_registry:find(tool, Name).

%%====================================================================
%% Server -> Client primitives
%%
%% Legacy era only. Every function in this section needs a session and
%% an open SSE stream to send a request down, and `2026-07-28' has
%% neither: a server that needs something from the client answers the
%% call with what it needs and the client retries. See
%% {@link input/2} and the tools guide.
%%
%% They keep working for legacy clients and are not going away. A
%% handler that must serve both eras should ask
%% {@link client_supports/2} first and use `{input_required, _, _}'
%% when there is no session to call into.
%%====================================================================

%% @doc Send `sampling/createMessage' to the client behind a session.
%% Requires the client to have declared sampling capability in its
%% `initialize' request and an active SSE stream. Blocks until the
%% client responds or `timeout_ms' (default 30s) elapses.
%%
%% Legacy era only; see the section note above.
-spec sampling_create_message(binary(), map(), map()) ->
    {ok, Result :: map(), Usage :: map()}
    | {error, timeout | not_supported | no_sse | not_found | term()}.
sampling_create_message(SessionId, Params, Opts) ->
    barrel_mcp_session:sampling_create_message(SessionId, Params, Opts).

%% @doc Return the ids of currently connected sessions whose client
%% declared sampling capability.
-spec list_sessions_with_sampling() -> [binary()].
list_sessions_with_sampling() ->
    barrel_mcp_session:list_sampling_capable().

%% @doc Send `elicitation/create' to the client behind a session to
%% request structured user input. Requires the client to have declared
%% elicitation capability in its `initialize' request and an active SSE
%% stream. Blocks until the client responds or `timeout_ms' (default
%% 30s) elapses.
%%
%% Legacy era only; see the section note above.
-spec elicit_create(binary(), map(), map()) ->
    {ok, Result :: map()}
    | {error, timeout | not_supported | no_sse | not_found | term()}.
elicit_create(SessionId, Params, Opts) ->
    barrel_mcp_session:elicit_create(SessionId, Params, Opts).

%% @doc Build the params for a form-mode `elicitation/create'. Pass the
%% result as an `{input_required, Requests, State}' entry, or as the
%% `Params' of {@link elicit_create/3}.
%%
%% Never for secrets; use {@link elicit_url/3}.
-spec elicit_form(binary(), map()) -> map().
elicit_form(Message, Schema) ->
    barrel_mcp_elicitation:form(Message, Schema).

%% @doc Build the params for a URL-mode `elicitation/create', the mode
%% for anything the client must not see. `Ctx' is the tool handler's
%% context. See {@link barrel_mcp_elicitation:url/4} for what is
%% checked and what stays yours to honour.
-spec elicit_url(binary(), binary(), map()) -> {ok, map()} | {error, term()}.
elicit_url(Message, Url, Ctx) ->
    case maps:get(mcp_ctx, Ctx, undefined) of
        undefined -> {error, no_request_context};
        McpCtx -> barrel_mcp_elicitation:url(Message, Url, McpCtx)
    end.

%% @doc Mark a URL-mode elicitation complete, notifying the client that
%% started it. Call it from whatever handles your redirect; completion
%% is authorised against the owning principal.
%%
%% 2025-11-25 only.
-spec elicit_complete(binary(), map() | term()) ->
    ok | {error, not_found | already_complete}.
elicit_complete(ElicitationId, Ctx) ->
    barrel_mcp_elicitation:complete(ElicitationId, Ctx).

%% @doc Return the ids of currently connected sessions whose client
%% declared elicitation capability.
-spec list_sessions_with_elicitation() -> [binary()].
list_sessions_with_elicitation() ->
    barrel_mcp_session:list_elicitation_capable().

%% @doc Send `roots/list' to the client behind a session to enumerate
%% the host's available roots (typically filesystem or workspace roots
%% the host has authorised the server to operate on). Requires the
%% client to have declared roots capability in its `initialize' request
%% and an active SSE stream. Blocks until the client responds or
%% `timeout_ms' (default 30s) elapses.
%%
%% Legacy era only, and Roots itself was removed by `2026-07-28'; see
%% the section note above.
-spec roots_list(binary()) ->
    {ok, [map()]}
    | {error, timeout | not_supported | no_sse | not_found | term()}.
roots_list(SessionId) ->
    roots_list(SessionId, #{}).

-spec roots_list(binary(), map()) ->
    {ok, [map()]}
    | {error, timeout | not_supported | no_sse | not_found | term()}.
roots_list(SessionId, Opts) ->
    barrel_mcp_session:roots_list(SessionId, Opts).

%% @doc Return the ids of currently connected sessions whose client
%% declared roots capability.
-spec list_sessions_with_roots() -> [binary()].
list_sessions_with_roots() ->
    barrel_mcp_session:list_roots_capable().

%% @doc Notify all subscribers of a resource that it has changed.
%% The notification body is a JSON-RPC notification with no params; the
%% client is expected to issue a `resources/read' to fetch the new state.
-spec notify_resource_updated(binary()) -> ok.
notify_resource_updated(Uri) ->
    notify_resource_updated(Uri, #{}).

-spec notify_resource_updated(binary(), map()) -> ok.
notify_resource_updated(Uri, Extra) when is_binary(Uri) ->
    %% Modern subscribers named this URI in a `subscriptions/listen'
    %% filter; legacy ones subscribed with `resources/subscribe'.
    barrel_mcp_subscriptions:resource_updated(Uri, Extra),
    Subscribers = barrel_mcp_session:subscribers_for(Uri),
    Notification = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/resources/updated">>,
        <<"params">> => maps:merge(#{<<"uri">> => Uri}, Extra)
    },
    lists:foreach(
        fun(SessionId) ->
            case barrel_mcp_session:get_sse_pid(SessionId) of
                {ok, Pid} -> Pid ! {sse_send_message, Notification};
                _ -> ok
            end
        end,
        Subscribers
    ),
    ok.

%% @doc Emit `notifications/progress' to a session. `Total' may be
%% omitted (defaults to `undefined' = absent in the wire payload).
-spec notify_progress(binary(), term(), number()) -> ok.
notify_progress(SessionId, Token, Progress) ->
    notify_progress(SessionId, Token, Progress, undefined).

-spec notify_progress(binary(), term(), number(), number() | undefined) -> ok.
notify_progress(SessionId, Token, Progress, Total) ->
    barrel_mcp_session:notify_progress(SessionId, Token, Progress, Total).

%% @doc Emit `notifications/message' (the MCP server log stream) to a
%% session. The notification is dropped silently when `Level' is below
%% the session's configured level (`logging/setLevel'). `Logger' is an
%% optional component name; pass `undefined' to omit it. `Data' is the
%% structured payload, typically a string or a map.
%%
%% Legacy era only. `2026-07-28' deprecated logging and removed
%% `logging/setLevel'; a modern client opts in per request instead, by
%% naming a level in `_meta'. This keeps serving legacy sessions.
-spec notify_log(binary(), atom() | binary(), term()) -> ok.
notify_log(SessionId, Level, Data) ->
    notify_log(SessionId, Level, undefined, Data).

-spec notify_log(
    binary(),
    atom() | binary(),
    binary() | undefined,
    term()
) -> ok.
notify_log(SessionId, Level, Logger, Data) ->
    case barrel_mcp_session:log_level_priority(Level) of
        %% invalid level, drop
        error ->
            ok;
        EventPrio ->
            ConfigPrio =
                case barrel_mcp_session:get_log_level(SessionId) of
                    {ok, L} -> barrel_mcp_session:log_level_priority(L);
                    %% default `info'
                    _ -> 1
                end,
            case EventPrio >= ConfigPrio of
                false ->
                    ok;
                true ->
                    case barrel_mcp_session:get_sse_pid(SessionId) of
                        {ok, Pid} when is_pid(Pid) ->
                            Pid ! {sse_send_message, log_envelope(Level, Logger, Data)},
                            ok;
                        _ ->
                            ok
                    end
            end
    end.

log_envelope(Level, Logger, Data) ->
    LevelBin = level_to_binary(Level),
    Params0 = #{<<"level">> => LevelBin, <<"data">> => Data},
    Params =
        case Logger of
            undefined -> Params0;
            _ -> Params0#{<<"logger">> => Logger}
        end,
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/message">>,
        <<"params">> => Params
    }.

level_to_binary(L) when is_atom(L) -> atom_to_binary(L, utf8);
level_to_binary(L) when is_binary(L) -> L.

%% @doc Push a `notifications/<kind>/list_changed' envelope to every
%% currently-connected SSE session. Hosts call this when they mutate
%% the catalogue out-of-band (the registry already calls it for
%% `reg/4,5' and `unreg/2').
-spec notify_list_changed(tool | resource | prompt) -> ok.
notify_list_changed(Kind) when
    Kind =:= tool;
    Kind =:= resource;
    Kind =:= prompt
->
    barrel_mcp_session:broadcast_list_changed(Kind),
    barrel_mcp_subscriptions:list_changed(Kind).

%%====================================================================
%% Multi round-trip requests (tool handler side)
%%====================================================================

%% @doc Read the client's answer to one of the input requests this tool
%% asked for on a previous attempt.
%%
%% The shapes match the blocking calls they replace, so porting a
%% handler is a matter of moving the call rather than rewriting what it
%% returns:
%%
%% <ul>
%%   <li>`elicitation/create': `{ok, ElicitResult}', the raw result
%%       with its `action' and `content', as
%%       {@link elicit_create/3}.</li>
%%   <li>`sampling/createMessage': `{ok, Result, Usage}', as
%%       {@link sampling_create_message/3}.</li>
%%   <li>`roots/list': `{ok, Roots}', already unwrapped, as
%%       {@link roots_list/2}.</li>
%% </ul>
%%
%% `none' means the client has not answered this key: either the first
%% attempt, or it chose not to. Ask again or give up; do not assume.
-spec input(map(), binary()) ->
    {ok, term()} | {ok, term(), map()} | none.
input(Ctx, Key) when is_map(Ctx), is_binary(Key) ->
    Mrtr = maps:get(mrtr, Ctx, #{}),
    case maps:get(Key, maps:get(responses, Mrtr, #{}), undefined) of
        Response when is_map(Response) ->
            decode_input(maps:get(Key, maps:get(methods, Mrtr, #{}), undefined), Response);
        _ ->
            none
    end.

%% Unwrap exactly as far as the equivalent blocking call does, and no
%% further: containers come off, leaves stay as they arrived.
decode_input(<<"sampling/createMessage">>, Response) ->
    {ok, Response, maps:get(<<"usage">>, Response, #{})};
decode_input(<<"roots/list">>, Response) ->
    {ok, maps:get(<<"roots">>, Response, [])};
decode_input(_Method, Response) ->
    {ok, Response}.

%% @doc Emit `notifications/message' for the request this tool is
%% serving. `Logger' is optional; pass `undefined' to omit it.
%%
%% Modern: on this request's own response stream, and only if it named
%% `io.modelcontextprotocol/logLevel' in its `_meta'. Legacy: on the
%% session's SSE channel, filtered by `logging/setLevel'. Silent when
%% there is nowhere to deliver.
-spec log(map(), atom() | binary(), term()) -> ok.
log(Ctx, Level, Data) ->
    log(Ctx, Level, undefined, Data).

-spec log(map(), atom() | binary(), binary() | undefined, term()) -> ok.
log(Ctx, Level, Logger, Data) when is_map(Ctx) ->
    Emit = maps:get(emit_log, Ctx, fun(_, _, _) -> ok end),
    _ = Emit(Level, Logger, Data),
    ok.

%% @doc The term this tool passed as the state of its previous attempt,
%% verified and deserialised.
%%
%% `none' on a first attempt. A state that failed verification never
%% reaches the handler: the request is rejected before it runs.
-spec request_state(map()) -> {ok, term()} | none.
request_state(Ctx) when is_map(Ctx) ->
    case maps:get(state, maps:get(mrtr, Ctx, #{}), undefined) of
        undefined -> none;
        State -> {ok, State}
    end.

%% @doc Whether the client declared a capability, before asking it for
%% something that needs one.
%%
%% A server must not send an input request for a capability the client
%% did not declare, so a tool that would returns an error to the client
%% instead. Checking first lets the tool degrade on its own terms.
-spec client_supports(map(), elicitation | sampling | roots | binary()) ->
    boolean().
client_supports(Ctx, Feature) when is_map(Ctx) ->
    case maps:get(mcp_ctx, Ctx, undefined) of
        undefined -> false;
        McpCtx -> barrel_mcp_ctx:supports(McpCtx, Feature)
    end.

%%====================================================================
%% MCP client API
%%====================================================================

%% @doc Start a supervised MCP client connecting to a remote server.
%%
%% `ServerId' is any term the host uses to identify the connection
%% (typically a binary). `Spec' is a `barrel_mcp_client:connect_spec()':
%%
%% ```
%% barrel_mcp:start_client(<<"github">>, #{
%%     transport => {http, <<"https://mcp.github.com/">>},
%%     handler => {my_handler_mod, []},
%%     auth => {bearer, <<"ghp_xxx">>},
%%     capabilities => #{sampling => true}
%% }).
%% '''
-spec start_client(term(), barrel_mcp_client:connect_spec()) ->
    {ok, pid()} | {error, term()}.
start_client(ServerId, Spec) ->
    barrel_mcp_clients:start_client(ServerId, Spec).

%% @doc Stop a previously-started client.
-spec stop_client(term()) -> ok | {error, not_found}.
stop_client(ServerId) ->
    barrel_mcp_clients:stop_client(ServerId).

%% @doc Look up the pid of a connected client by `ServerId'.
-spec whereis_client(term()) -> pid() | undefined.
whereis_client(ServerId) ->
    barrel_mcp_clients:whereis_client(ServerId).

%% @doc List all currently connected clients as `[{ServerId, Pid}]'.
-spec list_clients() -> [{term(), pid()}].
list_clients() ->
    barrel_mcp_clients:list_clients().
