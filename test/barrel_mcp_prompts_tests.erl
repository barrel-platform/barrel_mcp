%%%-------------------------------------------------------------------
%%% @doc Prompts tests for barrel_mcp.
%%% Tests based on official MCP Python SDK test patterns.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_prompts_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test handlers
-export([
    simple_prompt/1,
    parameterized_prompt/1,
    multi_message_prompt/1
]).

%%====================================================================
%% Test Fixtures
%%====================================================================

prompts_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        {"List prompts returns registered prompts", fun test_list_prompts/0},
        {"List prompts returns empty when none registered", fun test_list_prompts_empty/0},
        {"Get prompt returns messages", fun test_get_prompt/0},
        {"Get prompt with arguments", fun test_get_prompt_with_args/0},
        {"Get prompt returns multiple messages", fun test_get_prompt_multi_message/0},
        {"Get non-existent prompt returns error", fun test_get_prompt_not_found/0},
        {"Prompt with arguments is listed correctly", fun test_prompt_arguments/0}
     ]
    }.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    lists:foreach(fun({Name, _}) ->
        barrel_mcp_registry:unreg(prompt, Name)
    end, barrel_mcp_registry:all(prompt)),
    ok.

%%====================================================================
%% Test Handlers
%%====================================================================

simple_prompt(_Args) ->
    #{
        description => <<"A simple prompt">>,
        messages => [
            #{
                role => <<"user">>,
                content => #{
                    type => <<"text">>,
                    text => <<"Hello, please help me.">>
                }
            }
        ]
    }.

parameterized_prompt(Args) ->
    Topic = maps:get(<<"topic">>, Args, <<"general">>),
    #{
        description => <<"A parameterized prompt">>,
        messages => [
            #{
                role => <<"user">>,
                content => #{
                    type => <<"text">>,
                    text => <<"Tell me about ", Topic/binary>>
                }
            }
        ]
    }.

multi_message_prompt(_Args) ->
    #{
        description => <<"Multi-turn conversation">>,
        messages => [
            #{
                role => <<"user">>,
                content => #{type => <<"text">>, text => <<"First message">>}
            },
            #{
                role => <<"assistant">>,
                content => #{type => <<"text">>, text => <<"Response">>}
            },
            #{
                role => <<"user">>,
                content => #{type => <<"text">>, text => <<"Follow up">>}
            }
        ]
    }.

%%====================================================================
%% Tests
%%====================================================================

test_list_prompts() ->
    ok = barrel_mcp_registry:reg(prompt, <<"prompt1">>, ?MODULE, simple_prompt, #{
        description => <<"First prompt">>
    }),
    ok = barrel_mcp_registry:reg(prompt, <<"prompt2">>, ?MODULE, parameterized_prompt, #{
        description => <<"Second prompt">>,
        arguments => [
            #{name => <<"topic">>, description => <<"The topic">>, required => true}
        ]
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"prompts/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Prompts = maps:get(<<"prompts">>, Result),

    ?assertEqual(2, length(Prompts)),

    %% Check prompt structure
    [Prompt1 | _] = Prompts,
    ?assert(maps:is_key(<<"name">>, Prompt1)),
    ?assert(maps:is_key(<<"description">>, Prompt1)),
    ?assert(maps:is_key(<<"arguments">>, Prompt1)),

    barrel_mcp_registry:unreg(prompt, <<"prompt1">>),
    barrel_mcp_registry:unreg(prompt, <<"prompt2">>).

test_list_prompts_empty() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"prompts/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Prompts = maps:get(<<"prompts">>, Result),
    ?assertEqual([], Prompts).

test_get_prompt() ->
    ok = barrel_mcp_registry:reg(prompt, <<"simple">>, ?MODULE, simple_prompt, #{
        description => <<"Simple prompt">>
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"prompts/get">>,
        <<"params">> => #{
            <<"name">> => <<"simple">>,
            <<"arguments">> => #{}
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),

    ?assert(maps:is_key(<<"description">>, Result)),
    ?assert(maps:is_key(<<"messages">>, Result)),
    Messages = maps:get(<<"messages">>, Result),
    ?assertEqual(1, length(Messages)),

    barrel_mcp_registry:unreg(prompt, <<"simple">>).

test_get_prompt_with_args() ->
    ok = barrel_mcp_registry:reg(prompt, <<"param">>, ?MODULE, parameterized_prompt, #{
        description => <<"Parameterized prompt">>,
        arguments => [
            #{name => <<"topic">>, description => <<"The topic">>, required => true}
        ]
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"prompts/get">>,
        <<"params">> => #{
            <<"name">> => <<"param">>,
            <<"arguments">> => #{<<"topic">> => <<"Erlang">>}
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Messages = maps:get(<<"messages">>, Result),

    [Message] = Messages,
    Content = maps:get(content, Message),
    Text = maps:get(text, Content),
    ?assertEqual(<<"Tell me about Erlang">>, Text),

    barrel_mcp_registry:unreg(prompt, <<"param">>).

test_get_prompt_multi_message() ->
    ok = barrel_mcp_registry:reg(prompt, <<"multi">>, ?MODULE, multi_message_prompt, #{
        description => <<"Multi-message prompt">>
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"prompts/get">>,
        <<"params">> => #{
            <<"name">> => <<"multi">>,
            <<"arguments">> => #{}
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Messages = maps:get(<<"messages">>, Result),

    ?assertEqual(3, length(Messages)),

    barrel_mcp_registry:unreg(prompt, <<"multi">>).

test_get_prompt_not_found() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"prompts/get">>,
        <<"params">> => #{
            <<"name">> => <<"nonexistent">>,
            <<"arguments">> => #{}
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    ?assert(maps:is_key(<<"error">>, Response)),
    Error = maps:get(<<"error">>, Response),
    ?assertEqual(-32601, maps:get(<<"code">>, Error)).

test_prompt_arguments() ->
    ok = barrel_mcp_registry:reg(prompt, <<"with_args">>, ?MODULE, parameterized_prompt, #{
        description => <<"Prompt with args">>,
        arguments => [
            #{name => <<"topic">>, description => <<"The topic to discuss">>, required => true},
            #{name => <<"style">>, description => <<"Response style">>, required => false}
        ]
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"prompts/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    [Prompt] = maps:get(<<"prompts">>, Result),

    Arguments = maps:get(<<"arguments">>, Prompt),
    ?assertEqual(2, length(Arguments)),

    [Arg1, Arg2] = Arguments,
    ?assertEqual(<<"topic">>, maps:get(<<"name">>, Arg1)),
    ?assertEqual(true, maps:get(<<"required">>, Arg1)),
    ?assertEqual(<<"style">>, maps:get(<<"name">>, Arg2)),
    ?assertEqual(false, maps:get(<<"required">>, Arg2)),

    barrel_mcp_registry:unreg(prompt, <<"with_args">>).
