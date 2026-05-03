%%%-------------------------------------------------------------------
%%% @doc Multi-server tool aggregator for agent hosts.
%%%
%%% Sits on top of {@link barrel_mcp_clients} and turns the set of
%%% connected MCP clients into a single namespaced tool catalog the
%%% host can hand to an LLM, plus a router that dispatches a model's
%%% tool call back to the right MCP server.
%%%
%%% Tool names are namespaced as `<<"ServerId<Sep>ToolName">>'. The
%%% default separator is `<<":">>'; override with the `separator'
%%% option on every call. Hosts that allow `:' in tool names should
%%% pick a separator that does not appear in any registered tool.
%%%
%%% Typical agent loop:
%%% ```
%%% Tools = barrel_mcp_agent:to_anthropic(),
%%% %% ... ask the model with Tools, receive a tool_use block ...
%%% {Name, Args} = barrel_mcp_tool_format:from_anthropic_call(Block),
%%% {ok, Result} = barrel_mcp_agent:call_tool(Name, Args).
%%% '''
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_agent).

-export([
    list_tools/0,
    list_tools/1,
    to_anthropic/0,
    to_anthropic/1,
    to_openai/0,
    to_openai/1,
    call_tool/2,
    call_tool/3
]).

-type opts() :: #{separator => binary(), timeout => timeout()}.

-export_type([opts/0]).

-define(DEFAULT_SEP, <<":">>).

%%====================================================================
%% Listing
%%====================================================================

%% @doc Return every tool from every registered client, with each
%% tool's `<<"name">>' rewritten to `<<"ServerId<Sep>ToolName">>'.
%% Servers that error out are skipped (with a `logger:warning').
-spec list_tools() -> [map()].
list_tools() -> list_tools(#{}).

-spec list_tools(opts()) -> [map()].
list_tools(Opts) ->
    Sep = sep(Opts),
    Servers = barrel_mcp_clients:list_clients(),
    lists:flatmap(fun({ServerId, Pid}) ->
        case fetch_tools(Pid) of
            {ok, Tools} ->
                [namespace_tool(ServerId, Sep, T) || T <- Tools];
            {error, Reason} ->
                logger:warning("barrel_mcp_agent: list_tools ~p failed: ~p",
                               [ServerId, Reason]),
                []
        end
    end, Servers).

fetch_tools(Pid) ->
    barrel_mcp_client:list_tools_all(Pid).

namespace_tool(ServerId, Sep, Tool) ->
    Original = maps:get(<<"name">>, Tool),
    Tool#{<<"name">> => <<(to_bin(ServerId))/binary, Sep/binary,
                          Original/binary>>}.

%%====================================================================
%% Provider formats
%%====================================================================

%% @doc Aggregated tools in Anthropic Messages API format.
-spec to_anthropic() -> [map()].
to_anthropic() -> to_anthropic(#{}).

-spec to_anthropic(opts()) -> [map()].
to_anthropic(Opts) ->
    barrel_mcp_tool_format:to_anthropic(list_tools(Opts)).

%% @doc Aggregated tools in OpenAI Chat Completions tool format.
-spec to_openai() -> [map()].
to_openai() -> to_openai(#{}).

-spec to_openai(opts()) -> [map()].
to_openai(Opts) ->
    barrel_mcp_tool_format:to_openai(list_tools(Opts)).

%%====================================================================
%% Routing
%%====================================================================

%% @doc Route a model's tool call back to the right MCP server.
%% `NamespacedName' is `<<"ServerId<Sep>ToolName">>'; the `ServerId'
%% prefix selects the client and the `ToolName' suffix is forwarded.
%% Errors:
%% <ul>
%%   <li>`{error, no_separator}' — the name does not contain the
%%       configured separator.</li>
%%   <li>`{error, unknown_server}' — no client is registered under
%%       the parsed `ServerId'.</li>
%%   <li>Any error returned by
%%       {@link barrel_mcp_client:call_tool/4}.</li>
%% </ul>
-spec call_tool(binary(), map()) ->
    {ok, map()} | {error, term()}.
call_tool(NsName, Args) ->
    call_tool(NsName, Args, #{}).

-spec call_tool(binary(), map(), opts()) ->
    {ok, map()} | {error, term()}.
call_tool(NsName, Args, Opts) ->
    Sep = sep(Opts),
    case split_ns(NsName, Sep) of
        {error, _} = E -> E;
        {ServerId, ToolName} ->
            case barrel_mcp_clients:whereis_client(ServerId) of
                undefined -> {error, unknown_server};
                Pid ->
                    Timeout = maps:get(timeout, Opts, 30000),
                    barrel_mcp_client:call_tool(
                      Pid, ToolName, Args, #{timeout => Timeout})
            end
    end.

%%====================================================================
%% Helpers
%%====================================================================

sep(Opts) -> maps:get(separator, Opts, ?DEFAULT_SEP).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

split_ns(Bin, Sep) when is_binary(Bin), is_binary(Sep) ->
    case binary:split(Bin, Sep) of
        [_] -> {error, no_separator};
        [Server, Tool] -> {Server, Tool}
    end.
