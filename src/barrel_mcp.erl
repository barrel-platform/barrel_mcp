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
    list_sessions_with_elicitation/0,
    notify_resource_updated/1,
    notify_resource_updated/2,
    notify_progress/3,
    notify_progress/4,
    notify_list_changed/1
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
        input_schema => map()
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
%%   <li>`name' — display name.</li>
%%   <li>`uri_template' — RFC 6570 URI template (e.g.
%%       `<<"file:///{path}">>').</li>
%%   <li>`description' — human-readable description.</li>
%%   <li>`mime_type' — content type (default `<<"text/plain">>').</li>
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
    Ref :: {prompt, binary(), binary()}
         | {resource_template, binary(), binary()},
    Module :: module(),
    Function :: atom(),
    Opts :: map().
reg_completion({prompt, PromptName, ArgName}, Module, Function, Opts)
  when is_binary(PromptName), is_binary(ArgName) ->
    Key = completion_key(prompt, PromptName, ArgName),
    barrel_mcp_registry:reg(completion, Key, Module, Function, Opts);
reg_completion({resource_template, TemplateUri, ArgName}, Module, Function, Opts)
  when is_binary(TemplateUri), is_binary(ArgName) ->
    Key = completion_key(resource_template, TemplateUri, ArgName),
    barrel_mcp_registry:reg(completion, Key, Module, Function, Opts).

-spec unreg_completion(term()) -> ok.
unreg_completion({prompt, PromptName, ArgName}) ->
    barrel_mcp_registry:unreg(completion,
                              completion_key(prompt, PromptName, ArgName));
unreg_completion({resource_template, TemplateUri, ArgName}) ->
    barrel_mcp_registry:unreg(completion,
                              completion_key(resource_template,
                                             TemplateUri, ArgName)).

completion_key(Kind, Outer, Arg) ->
    K = case Kind of
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
%%   <li>`ip' - IP address to bind (default: `{0, 0, 0, 0}')</li>
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
%%             secret => <<"your-jwt-secret">>
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
        auth => map()
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

%% @doc Start the Streamable HTTP server for MCP (Protocol 2025-03-26).
%%
%% Starts a Cowboy HTTP server implementing the MCP Streamable HTTP transport.
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
%%   <dt>ip</dt><dd>IP address to bind (default: {0, 0, 0, 0})</dd>
%%   <dt>auth</dt><dd>Authentication configuration (see {@link barrel_mcp_auth})</dd>
%%   <dt>session_enabled</dt><dd>Enable session management (default: true)</dd>
%%   <dt>ssl</dt><dd>SSL/TLS configuration for HTTPS: certfile, keyfile, cacertfile (optional)</dd>
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
        }
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
%%====================================================================

%% @doc Send `sampling/createMessage' to the client behind a session.
%% Requires the client to have declared sampling capability in its
%% `initialize' request and an active SSE stream. Blocks until the
%% client responds or `timeout_ms' (default 30s) elapses.
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
-spec elicit_create(binary(), map(), map()) ->
    {ok, Result :: map()}
  | {error, timeout | not_supported | no_sse | not_found | term()}.
elicit_create(SessionId, Params, Opts) ->
    barrel_mcp_session:elicit_create(SessionId, Params, Opts).

%% @doc Return the ids of currently connected sessions whose client
%% declared elicitation capability.
-spec list_sessions_with_elicitation() -> [binary()].
list_sessions_with_elicitation() ->
    barrel_mcp_session:list_elicitation_capable().

%% @doc Notify all subscribers of a resource that it has changed.
%% The notification body is a JSON-RPC notification with no params; the
%% client is expected to issue a `resources/read' to fetch the new state.
-spec notify_resource_updated(binary()) -> ok.
notify_resource_updated(Uri) ->
    notify_resource_updated(Uri, #{}).

-spec notify_resource_updated(binary(), map()) -> ok.
notify_resource_updated(Uri, Extra) when is_binary(Uri) ->
    Subscribers = barrel_mcp_session:subscribers_for(Uri),
    Notification = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/resources/updated">>,
        <<"params">> => maps:merge(#{<<"uri">> => Uri}, Extra)
    },
    lists:foreach(fun(SessionId) ->
        case barrel_mcp_session:get_sse_pid(SessionId) of
            {ok, Pid} -> Pid ! {sse_send_message, Notification};
            _ -> ok
        end
    end, Subscribers),
    ok.

%% @doc Emit `notifications/progress' to a session. `Total' may be
%% omitted (defaults to `undefined' = absent in the wire payload).
-spec notify_progress(binary(), term(), number()) -> ok.
notify_progress(SessionId, Token, Progress) ->
    notify_progress(SessionId, Token, Progress, undefined).

-spec notify_progress(binary(), term(), number(), number() | undefined) -> ok.
notify_progress(SessionId, Token, Progress, Total) ->
    barrel_mcp_session:notify_progress(SessionId, Token, Progress, Total).

%% @doc Push a `notifications/<kind>/list_changed' envelope to every
%% currently-connected SSE session. Hosts call this when they mutate
%% the catalogue out-of-band (the registry already calls it for
%% `reg/4,5' and `unreg/2').
-spec notify_list_changed(tool | resource | prompt) -> ok.
notify_list_changed(Kind) when Kind =:= tool;
                                Kind =:= resource;
                                Kind =:= prompt ->
    barrel_mcp_session:broadcast_list_changed(Kind).

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
