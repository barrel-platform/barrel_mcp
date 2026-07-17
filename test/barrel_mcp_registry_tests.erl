%%%-------------------------------------------------------------------
%%% @doc Tests for barrel_mcp_registry module.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_registry_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test handlers (exported for MCP registry)
-export([sample_handler/1, ctx_handler/2]).

%%====================================================================
%% Test Fixtures
%%====================================================================

registry_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"Register and find tool", fun test_register_tool/0},
        {"Register and find resource", fun test_register_resource/0},
        {"Register and find prompt", fun test_register_prompt/0},
        {"Unregister handler", fun test_unregister/0},
        {"Run tool handler", fun test_run_tool/0},
        {"Ctx carries tool_name", fun test_run_tool_ctx_tool_name/0},
        {"One handler serves many tools", fun test_gateway_dispatch_by_tool_name/0},
        {"Run handler not found", fun test_run_not_found/0},
        {"List all handlers", fun test_all/0},
        {"List handlers by type", fun test_all_type/0},
        {"Namespace isolation", fun test_namespace_isolation/0},
        {"Function validation", fun test_function_validation/0}
    ]}.

setup() ->
    %% Start the application (which starts the registry)
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    %% Clean up any registered handlers
    lists:foreach(
        fun({Name, _}) ->
            barrel_mcp_registry:unreg(tool, Name)
        end,
        barrel_mcp_registry:all(tool)
    ),
    lists:foreach(
        fun({Name, _}) ->
            barrel_mcp_registry:unreg(resource, Name)
        end,
        barrel_mcp_registry:all(resource)
    ),
    lists:foreach(
        fun({Name, _}) ->
            barrel_mcp_registry:unreg(prompt, Name)
        end,
        barrel_mcp_registry:all(prompt)
    ),
    ok.

%%====================================================================
%% Test Helpers
%%====================================================================

%% Sample handler function for testing
sample_handler(Args) ->
    #{result => Args}.

%% An arity-2 handler: echoes back the tool it was invoked as. This is the
%% shape an MCP gateway uses to route one handler across many registered
%% tool names.
ctx_handler(Args, Ctx) ->
    #{invoked_as => maps:get(tool_name, Ctx, undefined), args => Args}.

%%====================================================================
%% Tests
%%====================================================================

test_register_tool() ->
    Name = <<"test_tool">>,
    ok = barrel_mcp_registry:reg(tool, Name, ?MODULE, sample_handler, #{
        description => <<"Test tool">>,
        input_schema => #{type => <<"object">>}
    }),
    {ok, Handler} = barrel_mcp_registry:find(tool, Name),
    ?assertEqual(?MODULE, maps:get(module, Handler)),
    ?assertEqual(sample_handler, maps:get(function, Handler)),
    ?assertEqual(<<"Test tool">>, maps:get(description, Handler)),
    barrel_mcp_registry:unreg(tool, Name).

test_register_resource() ->
    Name = <<"test_resource">>,
    ok = barrel_mcp_registry:reg(resource, Name, ?MODULE, sample_handler, #{
        name => <<"Test Resource">>,
        uri => <<"file:///test">>,
        description => <<"A test resource">>,
        mime_type => <<"text/plain">>
    }),
    {ok, Handler} = barrel_mcp_registry:find(resource, Name),
    ?assertEqual(?MODULE, maps:get(module, Handler)),
    ?assertEqual(<<"file:///test">>, maps:get(uri, Handler)),
    ?assertEqual(<<"text/plain">>, maps:get(mime_type, Handler)),
    barrel_mcp_registry:unreg(resource, Name).

test_register_prompt() ->
    Name = <<"test_prompt">>,
    ok = barrel_mcp_registry:reg(prompt, Name, ?MODULE, sample_handler, #{
        name => <<"Test Prompt">>,
        description => <<"A test prompt">>,
        arguments => [
            #{name => <<"arg1">>, description => <<"First arg">>, required => true}
        ]
    }),
    {ok, Handler} = barrel_mcp_registry:find(prompt, Name),
    ?assertEqual(?MODULE, maps:get(module, Handler)),
    ?assertEqual(1, length(maps:get(arguments, Handler))),
    barrel_mcp_registry:unreg(prompt, Name).

test_unregister() ->
    Name = <<"unreg_test">>,
    ok = barrel_mcp_registry:reg(tool, Name, ?MODULE, sample_handler, #{}),
    {ok, _} = barrel_mcp_registry:find(tool, Name),
    ok = barrel_mcp_registry:unreg(tool, Name),
    ?assertEqual(error, barrel_mcp_registry:find(tool, Name)).

test_run_tool() ->
    Name = <<"run_test">>,
    ok = barrel_mcp_registry:reg(tool, Name, ?MODULE, sample_handler, #{}),
    Args = #{<<"key">> => <<"value">>},
    {ok, Result} = barrel_mcp_registry:run(tool, Name, Args),
    ?assertEqual(#{result => Args}, Result),
    barrel_mcp_registry:unreg(tool, Name).

%% Drive the real wire path: run_tool/3 spawns a worker that replies to
%% `reply_to'. This is what barrel_mcp_http_engine does.
run_tool_sync(Name, Args) ->
    RequestId = erlang:unique_integer([positive]),
    Ctx = #{reply_to => self(), request_id => RequestId},
    {ok, _Pid} = barrel_mcp_registry:run_tool(Name, Args, Ctx),
    receive
        {tool_result, RequestId, Result} -> {ok, Result};
        {tool_failed, RequestId, Reason} -> {error, Reason}
    after 5000 -> {error, timeout}
    end.

test_run_tool_ctx_tool_name() ->
    Name = <<"ctx_test">>,
    ok = barrel_mcp_registry:reg(tool, Name, ?MODULE, ctx_handler, #{}),
    Args = #{<<"key">> => <<"value">>},
    %% wire path
    {ok, Result} = run_tool_sync(Name, Args),
    ?assertEqual(Name, maps:get(invoked_as, Result)),
    ?assertEqual(Args, maps:get(args, Result)),
    %% local-invoke path (barrel_mcp:call_tool/2) must agree
    {ok, Local} = barrel_mcp_registry:run(tool, Name, Args),
    ?assertEqual(Name, maps:get(invoked_as, Local)),
    barrel_mcp_registry:unreg(tool, Name).

%% The gateway contract: many tool names, one Module:Function. Each call
%% must report the name it was invoked under, or a gateway cannot route
%% upstream.
test_gateway_dispatch_by_tool_name() ->
    Names = [<<"srv_a:do_thing">>, <<"srv_b:other_thing">>],
    [ok = barrel_mcp_registry:reg(tool, N, ?MODULE, ctx_handler, #{}) || N <- Names],
    Seen = [
        begin
            {ok, R} = run_tool_sync(N, #{}),
            maps:get(invoked_as, R)
        end
     || N <- Names
    ],
    ?assertEqual(Names, Seen),
    %% arity-1 handlers keep working alongside arity-2 ones
    ok = barrel_mcp_registry:reg(tool, <<"plain">>, ?MODULE, sample_handler, #{}),
    ?assertEqual({ok, #{result => #{}}}, run_tool_sync(<<"plain">>, #{})),
    [barrel_mcp_registry:unreg(tool, N) || N <- [<<"plain">> | Names]],
    ok.

test_run_not_found() ->
    {error, {not_found, tool, <<"nonexistent">>}} =
        barrel_mcp_registry:run(tool, <<"nonexistent">>, #{}).

test_all() ->
    ok = barrel_mcp_registry:reg(tool, <<"t1">>, ?MODULE, sample_handler, #{}),
    ok = barrel_mcp_registry:reg(resource, <<"r1">>, ?MODULE, sample_handler, #{}),
    All = barrel_mcp_registry:all(),
    ?assert(maps:is_key(tool, All)),
    ?assert(maps:is_key(resource, All)),
    barrel_mcp_registry:unreg(tool, <<"t1">>),
    barrel_mcp_registry:unreg(resource, <<"r1">>).

test_all_type() ->
    ok = barrel_mcp_registry:reg(tool, <<"t1">>, ?MODULE, sample_handler, #{}),
    ok = barrel_mcp_registry:reg(tool, <<"t2">>, ?MODULE, sample_handler, #{}),
    Tools = barrel_mcp_registry:all(tool),
    ?assertEqual(2, length(Tools)),
    barrel_mcp_registry:unreg(tool, <<"t1">>),
    barrel_mcp_registry:unreg(tool, <<"t2">>).

test_namespace_isolation() ->
    Name = <<"same_name">>,
    ok = barrel_mcp_registry:reg(tool, Name, ?MODULE, sample_handler, #{
        description => <<"Tool">>
    }),
    ok = barrel_mcp_registry:reg(resource, Name, ?MODULE, sample_handler, #{
        description => <<"Resource">>
    }),
    {ok, ToolHandler} = barrel_mcp_registry:find(tool, Name),
    {ok, ResourceHandler} = barrel_mcp_registry:find(resource, Name),
    ?assertEqual(<<"Tool">>, maps:get(description, ToolHandler)),
    ?assertEqual(<<"Resource">>, maps:get(description, ResourceHandler)),
    barrel_mcp_registry:unreg(tool, Name),
    barrel_mcp_registry:unreg(resource, Name).

test_function_validation() ->
    %% Tool registration accepts arity 1 (legacy) or arity 2 (new
    %% Ctx-aware shape); the error reports the highest arity it
    %% checked.
    {error, {function_not_exported, ?MODULE, nonexistent_function, 2}} =
        barrel_mcp_registry:reg(tool, <<"bad">>, ?MODULE, nonexistent_function, #{}).
