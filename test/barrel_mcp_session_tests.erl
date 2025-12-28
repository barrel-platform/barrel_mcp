%%%-------------------------------------------------------------------
%%% @doc Session tests for barrel_mcp.
%%% Tests based on official MCP Python SDK test patterns.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_session_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test handlers
-export([sample_tool/1, sample_resource/1, sample_prompt/1]).

%%====================================================================
%% Test Fixtures
%%====================================================================

session_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        {"Initialize returns protocol version and capabilities", fun test_initialize/0},
        {"Initialize returns server info", fun test_initialize_server_info/0},
        {"Server capabilities reflect registered handlers", fun test_server_capabilities/0},
        {"Ping request works", fun test_ping_request/0},
        {"Unknown method returns error", fun test_unknown_method/0},
        {"Invalid JSON returns parse error", fun test_invalid_json/0},
        {"Missing method returns invalid request", fun test_missing_method/0},
        {"Notification has no response", fun test_notification_no_response/0}
     ]
    }.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    %% Clean up handlers
    lists:foreach(fun({Name, _}) ->
        barrel_mcp_registry:unreg(tool, Name)
    end, barrel_mcp_registry:all(tool)),
    lists:foreach(fun({Name, _}) ->
        barrel_mcp_registry:unreg(resource, Name)
    end, barrel_mcp_registry:all(resource)),
    lists:foreach(fun({Name, _}) ->
        barrel_mcp_registry:unreg(prompt, Name)
    end, barrel_mcp_registry:all(prompt)),
    ok.

%%====================================================================
%% Test Handlers
%%====================================================================

sample_tool(_Args) ->
    <<"tool result">>.

sample_resource(_Args) ->
    <<"resource content">>.

sample_prompt(_Args) ->
    #{
        description => <<"Test prompt">>,
        messages => [
            #{role => <<"user">>, content => #{type => <<"text">>, text => <<"Hello">>}}
        ]
    }.

%%====================================================================
%% Tests
%%====================================================================

test_initialize() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2024-11-05">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{
                <<"name">> => <<"test_client">>,
                <<"version">> => <<"1.0.0">>
            }
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Response)),
    ?assertEqual(1, maps:get(<<"id">>, Response)),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(<<"2024-11-05">>, maps:get(<<"protocolVersion">>, Result)),
    ?assert(maps:is_key(<<"capabilities">>, Result)).

test_initialize_server_info() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{}
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    ServerInfo = maps:get(<<"serverInfo">>, Result),
    ?assert(maps:is_key(<<"name">>, ServerInfo)),
    ?assert(maps:is_key(<<"version">>, ServerInfo)).

test_server_capabilities() ->
    %% Register handlers of each type
    ok = barrel_mcp_registry:reg(tool, <<"test_tool">>, ?MODULE, sample_tool, #{}),
    ok = barrel_mcp_registry:reg(resource, <<"test_resource">>, ?MODULE, sample_resource, #{
        uri => <<"file:///test">>
    }),
    ok = barrel_mcp_registry:reg(prompt, <<"test_prompt">>, ?MODULE, sample_prompt, #{}),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{}
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Capabilities = maps:get(<<"capabilities">>, Result),

    %% Should have tools, resources, prompts capabilities
    ?assert(maps:is_key(<<"tools">>, Capabilities)),
    ?assert(maps:is_key(<<"resources">>, Capabilities)),
    ?assert(maps:is_key(<<"prompts">>, Capabilities)),

    %% Cleanup
    barrel_mcp_registry:unreg(tool, <<"test_tool">>),
    barrel_mcp_registry:unreg(resource, <<"test_resource">>),
    barrel_mcp_registry:unreg(prompt, <<"test_prompt">>).

test_ping_request() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Response)),
    ?assertEqual(1, maps:get(<<"id">>, Response)),
    ?assertEqual(#{}, maps:get(<<"result">>, Response)).

test_unknown_method() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"unknown/method">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    ?assert(maps:is_key(<<"error">>, Response)),
    Error = maps:get(<<"error">>, Response),
    ?assertEqual(-32601, maps:get(<<"code">>, Error)).

test_invalid_json() ->
    {error, parse_error} = barrel_mcp_protocol:decode(<<"not valid json">>),
    {error, parse_error} = barrel_mcp_protocol:decode(<<"{incomplete">>).

test_missing_method() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1
    },
    Response = barrel_mcp_protocol:handle(Request),
    ?assert(maps:is_key(<<"error">>, Response)),
    Error = maps:get(<<"error">>, Response),
    ?assertEqual(-32600, maps:get(<<"code">>, Error)).

test_notification_no_response() ->
    %% Notifications have no id
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"initialized">>,
        <<"params">> => #{}
    },
    Response = barrel_mcp_protocol:handle(Request),
    ?assertEqual(no_response, Response).
