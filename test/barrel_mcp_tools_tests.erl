%%%-------------------------------------------------------------------
%%% @doc Tools tests for barrel_mcp.
%%% Tests based on official MCP Python SDK test patterns.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_tools_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test handlers
-export([
    echo_tool/1,
    error_tool/1,
    map_result_tool/1,
    list_result_tool/1
]).

%%====================================================================
%% Test Fixtures
%%====================================================================

tools_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        {"List tools returns registered tools", fun test_list_tools/0},
        {"List tools returns empty when none registered", fun test_list_tools_empty/0},
        {"Call tool returns text result", fun test_call_tool_text/0},
        {"Call tool returns map result as JSON", fun test_call_tool_map/0},
        {"Call tool returns list of content blocks", fun test_call_tool_list/0},
        {"Call non-existent tool returns error", fun test_call_tool_not_found/0},
        {"Call tool with error returns error response", fun test_call_tool_error/0},
        {"Tool with input schema is listed correctly", fun test_tool_input_schema/0},
        {"Tool annotations are surfaced in tools/list",
         fun test_tool_annotations/0}
     ]
    }.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    lists:foreach(fun({Name, _}) ->
        barrel_mcp_registry:unreg(tool, Name)
    end, barrel_mcp_registry:all(tool)),
    ok.

%%====================================================================
%% Test Handlers
%%====================================================================

echo_tool(Args) ->
    Input = maps:get(<<"input">>, Args, <<"default">>),
    <<"Echo: ", Input/binary>>.

error_tool(_Args) ->
    error(intentional_error).

map_result_tool(_Args) ->
    #{<<"key">> => <<"value">>, <<"number">> => 42}.

list_result_tool(_Args) ->
    [
        #{<<"type">> => <<"text">>, <<"text">> => <<"First">>},
        #{<<"type">> => <<"text">>, <<"text">> => <<"Second">>}
    ].

%%====================================================================
%% Tests
%%====================================================================

test_list_tools() ->
    ok = barrel_mcp_registry:reg(tool, <<"tool1">>, ?MODULE, echo_tool, #{
        description => <<"First tool">>
    }),
    ok = barrel_mcp_registry:reg(tool, <<"tool2">>, ?MODULE, map_result_tool, #{
        description => <<"Second tool">>
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Tools = maps:get(<<"tools">>, Result),

    ?assertEqual(2, length(Tools)),

    %% Check tool structure
    [Tool1 | _] = Tools,
    ?assert(maps:is_key(<<"name">>, Tool1)),
    ?assert(maps:is_key(<<"description">>, Tool1)),
    ?assert(maps:is_key(<<"inputSchema">>, Tool1)),

    barrel_mcp_registry:unreg(tool, <<"tool1">>),
    barrel_mcp_registry:unreg(tool, <<"tool2">>).

test_list_tools_empty() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Tools = maps:get(<<"tools">>, Result),
    ?assertEqual([], Tools).

%% Drive an async tools/call and return either the formatted content
%% blocks (for a result), or the outcome tuple (for failures).
drive_call(Name, Args) ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{<<"name">> => Name, <<"arguments">> => Args}
    },
    {async, Plan} = barrel_mcp_protocol:handle(Request),
    Self = self(),
    Ctx = #{request_id => 1, reply_to => Self,
            session_id => undefined,
            progress_token => undefined,
            emit_progress => fun(_, _, _) -> ok end},
    _Pid = (maps:get(spawn, Plan))(Ctx),
    receive
        {tool_result, 1, Result} ->
            {result, barrel_mcp_protocol:format_tool_result_external(Result)};
        {tool_failed, 1, Reason} -> {failed, Reason};
        {tool_error, 1, Content} -> {tool_error, Content};
        {tool_validation_failed, 1, Errors} -> {validation_failed, Errors}
    after 2000 ->
        timeout
    end.

test_call_tool_text() ->
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{}),
    {result, Content} = drive_call(<<"echo">>, #{<<"input">> => <<"hello">>}),
    ?assertEqual(1, length(Content)),
    [Block] = Content,
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assertEqual(<<"Echo: hello">>, maps:get(<<"text">>, Block)),
    barrel_mcp_registry:unreg(tool, <<"echo">>).

test_call_tool_map() ->
    ok = barrel_mcp_registry:reg(tool, <<"map_tool">>, ?MODULE, map_result_tool, #{}),
    {result, Content} = drive_call(<<"map_tool">>, #{}),
    ?assertEqual(1, length(Content)),
    [Block] = Content,
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ?assert(is_binary(maps:get(<<"text">>, Block))),
    barrel_mcp_registry:unreg(tool, <<"map_tool">>).

test_call_tool_list() ->
    ok = barrel_mcp_registry:reg(tool, <<"list_tool">>, ?MODULE, list_result_tool, #{}),
    {result, Content} = drive_call(<<"list_tool">>, #{}),
    ?assertEqual(2, length(Content)),
    barrel_mcp_registry:unreg(tool, <<"list_tool">>).

test_call_tool_not_found() ->
    %% A missing tool surfaces via the worker as `tool_failed' with
    %% the registry's not_found error.
    {failed, {error, {not_found, tool, <<"nonexistent">>}}} =
        drive_call(<<"nonexistent">>, #{}).

test_call_tool_error() ->
    %% Handler raises an error -> worker reports `tool_failed'.
    ok = barrel_mcp_registry:reg(tool, <<"error_tool">>, ?MODULE, error_tool, #{}),
    {failed, _} = drive_call(<<"error_tool">>, #{}),
    barrel_mcp_registry:unreg(tool, <<"error_tool">>).

test_tool_input_schema() ->
    Schema = #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"query">> => #{<<"type">> => <<"string">>},
            <<"limit">> => #{<<"type">> => <<"integer">>, <<"default">> => 10}
        },
        <<"required">> => [<<"query">>]
    },
    ok = barrel_mcp_registry:reg(tool, <<"search">>, ?MODULE, echo_tool, #{
        description => <<"Search tool">>,
        input_schema => Schema
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    [Tool] = maps:get(<<"tools">>, Result),

    ?assertEqual(<<"search">>, maps:get(<<"name">>, Tool)),
    ?assertEqual(<<"Search tool">>, maps:get(<<"description">>, Tool)),
    InputSchema = maps:get(<<"inputSchema">>, Tool),
    ?assertEqual(<<"object">>, maps:get(<<"type">>, InputSchema)),
    ?assert(maps:is_key(<<"properties">>, InputSchema)),

    barrel_mcp_registry:unreg(tool, <<"search">>).

test_tool_annotations() ->
    Annotations = #{
        <<"readOnlyHint">> => true,
        <<"destructiveHint">> => false,
        <<"idempotentHint">> => true,
        <<"openWorldHint">> => false
    },
    ok = barrel_mcp_registry:reg(tool, <<"reader">>, ?MODULE, echo_tool, #{
        description => <<"Read-only inspector">>,
        annotations => Annotations
    }),
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    [Tool] = maps:get(<<"tools">>, Result),
    ?assertEqual(Annotations, maps:get(<<"annotations">>, Tool)),
    %% Tools without annotations omit the field.
    ok = barrel_mcp_registry:reg(tool, <<"plain">>, ?MODULE, echo_tool, #{}),
    Response2 = barrel_mcp_protocol:handle(Request),
    [_, _] = maps:get(<<"tools">>, maps:get(<<"result">>, Response2)),
    Tools = maps:get(<<"tools">>, maps:get(<<"result">>, Response2)),
    Plain = lists:filter(fun(T) ->
                              maps:get(<<"name">>, T) =:= <<"plain">>
                          end, Tools),
    [PlainTool] = Plain,
    ?assertNot(maps:is_key(<<"annotations">>, PlainTool)),
    barrel_mcp_registry:unreg(tool, <<"reader">>),
    barrel_mcp_registry:unreg(tool, <<"plain">>).
