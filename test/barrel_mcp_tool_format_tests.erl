-module(barrel_mcp_tool_format_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% MCP -> Anthropic
%%====================================================================

to_anthropic_single_test() ->
    Mcp = #{<<"name">> => <<"search">>,
            <<"description">> => <<"Search the index">>,
            <<"inputSchema">> => #{<<"type">> => <<"object">>,
                                    <<"required">> => [<<"q">>]}},
    ?assertEqual(#{<<"name">> => <<"search">>,
                   <<"description">> => <<"Search the index">>,
                   <<"input_schema">> => #{<<"type">> => <<"object">>,
                                            <<"required">> => [<<"q">>]}},
                 barrel_mcp_tool_format:to_anthropic(Mcp)).

to_anthropic_list_test() ->
    Mcp = [#{<<"name">> => <<"a">>}, #{<<"name">> => <<"b">>}],
    Result = barrel_mcp_tool_format:to_anthropic(Mcp),
    ?assertEqual(2, length(Result)),
    ?assertEqual(<<"a">>, maps:get(<<"name">>, hd(Result))).

to_anthropic_defaults_test() ->
    %% Missing description and inputSchema: filled with empty defaults.
    Result = barrel_mcp_tool_format:to_anthropic(#{<<"name">> => <<"x">>}),
    ?assertEqual(<<>>, maps:get(<<"description">>, Result)),
    ?assertEqual(#{<<"type">> => <<"object">>},
                 maps:get(<<"input_schema">>, Result)).

to_anthropic_drops_extras_test() ->
    %% Extra MCP keys (title, annotations) are not surfaced.
    Mcp = #{<<"name">> => <<"x">>,
            <<"title">> => <<"X">>,
            <<"annotations">> => #{<<"readOnlyHint">> => true}},
    Result = barrel_mcp_tool_format:to_anthropic(Mcp),
    ?assertNot(maps:is_key(<<"title">>, Result)),
    ?assertNot(maps:is_key(<<"annotations">>, Result)).

%%====================================================================
%% MCP -> OpenAI
%%====================================================================

to_openai_single_test() ->
    Mcp = #{<<"name">> => <<"search">>,
            <<"description">> => <<"Search">>,
            <<"inputSchema">> => #{<<"type">> => <<"object">>}},
    Out = barrel_mcp_tool_format:to_openai(Mcp),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Out)),
    Fn = maps:get(<<"function">>, Out),
    ?assertEqual(<<"search">>, maps:get(<<"name">>, Fn)),
    ?assertEqual(<<"Search">>, maps:get(<<"description">>, Fn)),
    ?assertEqual(#{<<"type">> => <<"object">>},
                 maps:get(<<"parameters">>, Fn)).

to_openai_list_test() ->
    [Out] = barrel_mcp_tool_format:to_openai([#{<<"name">> => <<"x">>}]),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Out)).

%%====================================================================
%% Anthropic -> MCP
%%====================================================================

from_anthropic_canonical_test() ->
    Block = #{<<"type">> => <<"tool_use">>,
              <<"id">> => <<"abc">>,
              <<"name">> => <<"search">>,
              <<"input">> => #{<<"q">> => <<"hello">>}},
    ?assertEqual({<<"search">>, #{<<"q">> => <<"hello">>}},
                 barrel_mcp_tool_format:from_anthropic_call(Block)).

from_anthropic_camel_test() ->
    Block = #{<<"toolName">> => <<"x">>, <<"input">> => #{}},
    ?assertEqual({<<"x">>, #{}},
                 barrel_mcp_tool_format:from_anthropic_call(Block)).

%%====================================================================
%% OpenAI -> MCP
%%====================================================================

from_openai_parsed_args_test() ->
    Call = #{<<"id">> => <<"call_1">>,
             <<"type">> => <<"function">>,
             <<"function">> => #{<<"name">> => <<"search">>,
                                 <<"arguments">> => #{<<"q">> => <<"hi">>}}},
    ?assertEqual({<<"search">>, #{<<"q">> => <<"hi">>}},
                 barrel_mcp_tool_format:from_openai_call(Call)).

from_openai_string_args_test() ->
    Call = #{<<"function">> =>
                #{<<"name">> => <<"search">>,
                  <<"arguments">> => <<"{\"q\": \"hi\"}">>}},
    ?assertEqual({<<"search">>, #{<<"q">> => <<"hi">>}},
                 barrel_mcp_tool_format:from_openai_call(Call)).

from_openai_missing_args_defaults_to_empty_test() ->
    Call = #{<<"function">> => #{<<"name">> => <<"x">>}},
    ?assertEqual({<<"x">>, #{}},
                 barrel_mcp_tool_format:from_openai_call(Call)).
