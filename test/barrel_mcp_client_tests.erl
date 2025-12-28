%%%-------------------------------------------------------------------
%%% @doc Tests for barrel_mcp_client module.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test handlers (exported for MCP registry)
-export([test_handler/1]).

%%====================================================================
%% Test Fixtures
%%====================================================================

client_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        {"Connect HTTP client", fun test_connect_http/0},
        {"Close HTTP client", fun test_close_http/0}
     ]
    }.

%% Integration tests requiring running server
integration_test_() ->
    {setup,
     fun setup_integration/0,
     fun cleanup_integration/1,
     {timeout, 30, [
        {"Initialize client", fun test_initialize/0},
        {"List tools", fun test_list_tools/0},
        {"Call tool", fun test_call_tool/0},
        {"List resources", fun test_list_resources/0},
        {"List prompts", fun test_list_prompts/0}
     ]}
    }.

setup() ->
    ok.

cleanup(_) ->
    ok.

setup_integration() ->
    %% Start the barrel_mcp application (which starts registry)
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),

    %% Register a test tool
    barrel_mcp_registry:reg(tool, <<"test_tool">>, ?MODULE, test_handler, #{
        description => <<"Test tool">>
    }),

    %% Start HTTP server
    {ok, _} = barrel_mcp_http:start(#{port => 19090}),
    timer:sleep(100),
    ok.

cleanup_integration(_) ->
    barrel_mcp_http:stop(),
    barrel_mcp_registry:unreg(tool, <<"test_tool">>),
    ok.

%%====================================================================
%% Test Helpers
%%====================================================================

test_handler(_Args) ->
    <<"test result">>.

get_test_client() ->
    {ok, Client} = barrel_mcp_client:connect(#{
        transport => {http, <<"http://localhost:19090/mcp">>}
    }),
    Client.

%%====================================================================
%% Unit Tests
%%====================================================================

test_connect_http() ->
    {ok, _Client} = barrel_mcp_client:connect(#{
        transport => {http, <<"http://localhost:9090/mcp">>}
    }),
    ok.

test_close_http() ->
    {ok, Client} = barrel_mcp_client:connect(#{
        transport => {http, <<"http://localhost:9090/mcp">>}
    }),
    ?assertEqual(ok, barrel_mcp_client:close(Client)).

%%====================================================================
%% Integration Tests
%%====================================================================

test_initialize() ->
    Client = get_test_client(),
    {ok, Result, Client1} = barrel_mcp_client:initialize(Client),
    ?assert(maps:is_key(<<"protocolVersion">>, Result)),
    ?assert(maps:is_key(<<"capabilities">>, Result)),
    barrel_mcp_client:close(Client1).

test_list_tools() ->
    Client = get_test_client(),
    {ok, _, Client1} = barrel_mcp_client:initialize(Client),
    {ok, Tools, Client2} = barrel_mcp_client:list_tools(Client1),
    ?assert(is_list(Tools)),
    ?assert(length(Tools) >= 1),
    barrel_mcp_client:close(Client2).

test_call_tool() ->
    Client = get_test_client(),
    {ok, _, Client1} = barrel_mcp_client:initialize(Client),
    {ok, Result, Client2} = barrel_mcp_client:call_tool(Client1, <<"test_tool">>, #{}),
    ?assert(maps:is_key(<<"content">>, Result)),
    barrel_mcp_client:close(Client2).

test_list_resources() ->
    Client = get_test_client(),
    {ok, _, Client1} = barrel_mcp_client:initialize(Client),
    {ok, Resources, Client2} = barrel_mcp_client:list_resources(Client1),
    ?assert(is_list(Resources)),
    barrel_mcp_client:close(Client2).

test_list_prompts() ->
    Client = get_test_client(),
    {ok, _, Client1} = barrel_mcp_client:initialize(Client),
    {ok, Prompts, Client2} = barrel_mcp_client:list_prompts(Client1),
    ?assert(is_list(Prompts)),
    barrel_mcp_client:close(Client2).
