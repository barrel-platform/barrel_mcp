-module(barrel_mcp_agent_tests).

-include_lib("eunit/include/eunit.hrl").

%% These tests exercise the parts of barrel_mcp_agent that don't need
%% live MCP transports: namespace splitting, error reporting, and
%% empty-registry behaviour.

agent_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"call_tool with no separator returns no_separator",
             fun test_call_no_separator/0},
            {"call_tool with unknown server returns unknown_server",
             fun test_call_unknown_server/0},
            {"custom separator is honoured",
             fun test_custom_separator/0},
            {"empty registry yields empty tool list",
             fun test_empty_list_tools/0},
            {"empty registry produces empty Anthropic / OpenAI lists",
             fun test_empty_provider_lists/0}
        ]
    end}.

setup() ->
    catch application:stop(barrel_mcp),
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok.

teardown(_) ->
    application:stop(barrel_mcp),
    ok.

test_call_no_separator() ->
    ?assertEqual({error, no_separator},
                 barrel_mcp_agent:call_tool(<<"plain_name">>, #{})).

test_call_unknown_server() ->
    ?assertEqual({error, unknown_server},
                 barrel_mcp_agent:call_tool(<<"ghost:tool">>, #{})).

test_custom_separator() ->
    ?assertEqual({error, no_separator},
                 barrel_mcp_agent:call_tool(<<"ghost:tool">>, #{},
                                            #{separator => <<"::">>})),
    ?assertEqual({error, unknown_server},
                 barrel_mcp_agent:call_tool(<<"ghost::tool">>, #{},
                                            #{separator => <<"::">>})).

test_empty_list_tools() ->
    ?assertEqual([], barrel_mcp_agent:list_tools()).

test_empty_provider_lists() ->
    ?assertEqual([], barrel_mcp_agent:to_anthropic()),
    ?assertEqual([], barrel_mcp_agent:to_openai()).
