%%%-------------------------------------------------------------------
%%% @doc Main API module for barrel_mcp.
%%%
%%% Provides a public facade for registering and managing MCP
%%% tools, resources, and prompts, as well as starting transports.
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
    list_resources/0
]).

%% Prompt API
-export([
    reg_prompt/4,
    unreg_prompt/1,
    get_prompt/2,
    list_prompts/0
]).

%% Server API
-export([
    start_http/1,
    stop_http/0,
    start_stdio/0
]).

%% Backward compatible aliases
-export([
    reg/4,
    unreg/1,
    run/2,
    all/0,
    find/1
]).

%%====================================================================
%% Tool API
%%====================================================================

%% @doc Register a tool.
%% Opts can include:
%%   - description :: binary() - Tool description
%%   - input_schema :: map() - JSON Schema for input validation
-spec reg_tool(binary(), module(), atom(), map()) -> ok | {error, term()}.
reg_tool(Name, Module, Function, Opts) ->
    barrel_mcp_registry:reg(tool, Name, Module, Function, Opts).

%% @doc Unregister a tool.
-spec unreg_tool(binary()) -> ok.
unreg_tool(Name) ->
    barrel_mcp_registry:unreg(tool, Name).

%% @doc Call a tool.
-spec call_tool(binary(), map()) -> {ok, term()} | {error, term()}.
call_tool(Name, Args) ->
    barrel_mcp_registry:run(tool, Name, Args).

%% @doc List all registered tools.
-spec list_tools() -> [{binary(), map()}].
list_tools() ->
    barrel_mcp_registry:all(tool).

%%====================================================================
%% Resource API
%%====================================================================

%% @doc Register a resource.
%% Opts can include:
%%   - name :: binary() - Resource name
%%   - uri :: binary() - Resource URI
%%   - description :: binary() - Resource description
%%   - mime_type :: binary() - MIME type (default: text/plain)
-spec reg_resource(binary(), module(), atom(), map()) -> ok | {error, term()}.
reg_resource(Name, Module, Function, Opts) ->
    barrel_mcp_registry:reg(resource, Name, Module, Function, Opts).

%% @doc Unregister a resource.
-spec unreg_resource(binary()) -> ok.
unreg_resource(Name) ->
    barrel_mcp_registry:unreg(resource, Name).

%% @doc Read a resource by name.
-spec read_resource(binary()) -> {ok, term()} | {error, term()}.
read_resource(Name) ->
    barrel_mcp_registry:run(resource, Name, #{}).

%% @doc List all registered resources.
-spec list_resources() -> [{binary(), map()}].
list_resources() ->
    barrel_mcp_registry:all(resource).

%%====================================================================
%% Prompt API
%%====================================================================

%% @doc Register a prompt.
%% Opts can include:
%%   - name :: binary() - Prompt name
%%   - description :: binary() - Prompt description
%%   - arguments :: [#{name => binary(), description => binary(), required => boolean()}]
-spec reg_prompt(binary(), module(), atom(), map()) -> ok | {error, term()}.
reg_prompt(Name, Module, Function, Opts) ->
    barrel_mcp_registry:reg(prompt, Name, Module, Function, Opts).

%% @doc Unregister a prompt.
-spec unreg_prompt(binary()) -> ok.
unreg_prompt(Name) ->
    barrel_mcp_registry:unreg(prompt, Name).

%% @doc Get a prompt with arguments filled in.
-spec get_prompt(binary(), map()) -> {ok, term()} | {error, term()}.
get_prompt(Name, Args) ->
    barrel_mcp_registry:run(prompt, Name, Args).

%% @doc List all registered prompts.
-spec list_prompts() -> [{binary(), map()}].
list_prompts() ->
    barrel_mcp_registry:all(prompt).

%%====================================================================
%% Server API
%%====================================================================

%% @doc Start HTTP server for MCP.
%% Opts:
%%   - port :: integer() - Port to listen on (default: 9090)
%%   - ip :: inet:ip_address() - IP to bind (default: {0,0,0,0})
-spec start_http(map()) -> {ok, pid()} | {error, term()}.
start_http(Opts) ->
    barrel_mcp_http:start(Opts).

%% @doc Stop the HTTP server.
-spec stop_http() -> ok | {error, not_found}.
stop_http() ->
    barrel_mcp_http:stop().

%% @doc Start stdio server for MCP (blocking).
%% This is typically used for Claude Desktop integration.
-spec start_stdio() -> ok.
start_stdio() ->
    barrel_mcp_stdio:start().

%%====================================================================
%% Backward Compatible Aliases
%%====================================================================

%% @doc Register a tool (alias for reg_tool/4).
-spec reg(binary(), module(), atom(), map()) -> ok | {error, term()}.
reg(Name, Module, Function, Opts) ->
    reg_tool(Name, Module, Function, Opts).

%% @doc Unregister a tool (alias for unreg_tool/1).
-spec unreg(binary()) -> ok.
unreg(Name) ->
    unreg_tool(Name).

%% @doc Call a tool (alias for call_tool/2).
-spec run(binary(), map()) -> {ok, term()} | {error, term()}.
run(Name, Args) ->
    call_tool(Name, Args).

%% @doc List all tools (alias for list_tools/0).
-spec all() -> [{binary(), map()}].
all() ->
    list_tools().

%% @doc Find a tool by name.
-spec find(binary()) -> {ok, map()} | error.
find(Name) ->
    barrel_mcp_registry:find(tool, Name).
