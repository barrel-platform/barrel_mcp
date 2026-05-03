%%%-------------------------------------------------------------------
%%% @doc Translators between MCP tool shapes and LLM provider tool
%%% shapes (Anthropic Messages API, OpenAI Chat Completions / Responses).
%%%
%%% Use this module to bridge an MCP server's `tools/list' response
%%% into the tool definitions a provider expects, and to translate a
%%% provider's tool-call back into the `(Name, Arguments)' pair you
%%% feed to {@link barrel_mcp_client:call_tool/4}.
%%%
%%% The MCP shape (one entry from `tools/list') is:
%%% ```
%%% #{
%%%   <<"name">>        := binary(),
%%%   <<"description">> => binary(),
%%%   <<"inputSchema">> => map(),
%%%   <<"title">>       => binary(),     %% optional
%%%   <<"annotations">> => map(),        %% optional
%%%   ...                                 %% other MCP keys ignored
%%% }
%%% '''
%%%
%%% The Anthropic shape (Messages API `tools' array entry) is:
%%% ```
%%% #{
%%%   <<"name">>         := binary(),
%%%   <<"description">>  := binary(),
%%%   <<"input_schema">> := map()
%%% }
%%% '''
%%%
%%% The OpenAI shape (Chat Completions `tools' array entry) is:
%%% ```
%%% #{
%%%   <<"type">>     := <<"function">>,
%%%   <<"function">> := #{
%%%     <<"name">>        := binary(),
%%%     <<"description">> := binary(),
%%%     <<"parameters">>  := map()
%%%   }
%%% }
%%% '''
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_tool_format).

-export([
    to_anthropic/1,
    to_openai/1,
    from_anthropic_call/1,
    from_openai_call/1
]).

-type mcp_tool() :: map().
-type provider_tool() :: map().
-type tool_call() :: {Name :: binary(), Args :: map()}.

-export_type([mcp_tool/0, provider_tool/0, tool_call/0]).

%%====================================================================
%% MCP -> provider
%%====================================================================

%% @doc Translate one MCP tool, or a list of MCP tools, into the
%% Anthropic Messages API tool format. Unknown MCP keys are ignored;
%% missing `description' becomes an empty binary.
-spec to_anthropic(mcp_tool() | [mcp_tool()]) ->
    provider_tool() | [provider_tool()].
to_anthropic(Tools) when is_list(Tools) ->
    [to_anthropic(T) || T <- Tools];
to_anthropic(Tool) when is_map(Tool) ->
    Schema = maps:get(<<"inputSchema">>, Tool,
                      #{<<"type">> => <<"object">>}),
    #{
        <<"name">>         => maps:get(<<"name">>, Tool),
        <<"description">>  => maps:get(<<"description">>, Tool, <<>>),
        <<"input_schema">> => Schema
    }.

%% @doc Translate one MCP tool, or a list of MCP tools, into the OpenAI
%% Chat Completions tool format. Wraps each tool in the
%% `{type: "function", function: {...}}' envelope OpenAI requires.
-spec to_openai(mcp_tool() | [mcp_tool()]) ->
    provider_tool() | [provider_tool()].
to_openai(Tools) when is_list(Tools) ->
    [to_openai(T) || T <- Tools];
to_openai(Tool) when is_map(Tool) ->
    Schema = maps:get(<<"inputSchema">>, Tool,
                      #{<<"type">> => <<"object">>}),
    #{
        <<"type">>     => <<"function">>,
        <<"function">> => #{
            <<"name">>        => maps:get(<<"name">>, Tool),
            <<"description">> => maps:get(<<"description">>, Tool, <<>>),
            <<"parameters">>  => Schema
        }
    }.

%%====================================================================
%% Provider -> MCP
%%====================================================================

%% @doc Translate a single Anthropic `tool_use' content block into the
%% `(Name, Arguments)' pair you can feed to
%% {@link barrel_mcp_client:call_tool/4}. Accepts both the canonical
%% binary-keyed map and the camelCase variant some clients emit.
-spec from_anthropic_call(map()) -> tool_call().
from_anthropic_call(#{<<"name">> := Name, <<"input">> := Input}) ->
    {Name, Input};
from_anthropic_call(#{<<"toolName">> := Name, <<"input">> := Input}) ->
    {Name, Input}.

%% @doc Translate a single OpenAI `tool_call' object into the
%% `(Name, Arguments)' pair. Accepts both the parsed-arguments shape
%% (`arguments' is already a map) and the wire shape (`arguments' is a
%% JSON string that needs decoding).
-spec from_openai_call(map()) -> tool_call().
from_openai_call(#{<<"function">> := Fn}) ->
    Name = maps:get(<<"name">>, Fn),
    Args = decode_args(maps:get(<<"arguments">>, Fn, <<"{}">>)),
    {Name, Args}.

decode_args(Args) when is_map(Args) -> Args;
decode_args(Args) when is_binary(Args) ->
    case json:decode(Args) of
        Map when is_map(Map) -> Map;
        _ -> #{}
    end.
