%%%-------------------------------------------------------------------
%%% @doc How long a tool call may run: the per-tool `timeout' option,
%%% the `tool_call_timeout' application default, and what happens to
%%% the worker when the time runs out.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_tool_timeout_tests).

-include_lib("eunit/include/eunit.hrl").

-export([sleepy/1]).

-define(MAX, 16#FFFFFFFF).

timeout_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"Plan carries the tool's timeout", fun plan_uses_tool_timeout/0},
        {"Plan falls back to tool_call_timeout, then 60 s", fun plan_uses_app_default/0},
        {"infinity is the largest Erlang timeout", fun infinity_is_max/0},
        {"An invalid app default is ignored", fun invalid_app_default/0},
        {"Registration refuses an invalid timeout", fun registration_validates/0},
        {"A per-tool timeout beats the app default", fun tool_timeout_wins/0},
        {"A call past its timeout is answered as timed out", fun call_times_out/0},
        {"A call past its timeout stops the tool", fun timed_out_tool_is_stopped/0}
    ]}.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    application:unset_env(barrel_mcp, tool_call_timeout),
    [barrel_mcp_registry:unreg(tool, N) || N <- [<<"t">>, <<"plain">>]],
    ok.

%% Sleeps for `ms' then answers.
sleepy(#{<<"ms">> := Ms}) ->
    timer:sleep(Ms),
    <<"done">>.

reg(Name, Opts) ->
    barrel_mcp:reg_tool(Name, ?MODULE, sleepy, Opts).

call(Name, Ms) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{<<"name">> => Name, <<"arguments">> => #{<<"ms">> => Ms}}
    }.

plan_timeout(Name) ->
    {async, Plan} = barrel_mcp_protocol:handle(call(Name, 0)),
    maps:get(timeout, Plan).

plan_uses_tool_timeout() ->
    ok = reg(<<"t">>, #{timeout => 1234}),
    ?assertEqual(1234, plan_timeout(<<"t">>)).

plan_uses_app_default() ->
    ok = reg(<<"plain">>, #{}),
    application:unset_env(barrel_mcp, tool_call_timeout),
    ?assertEqual(60000, plan_timeout(<<"plain">>)),
    application:set_env(barrel_mcp, tool_call_timeout, 75),
    ?assertEqual(75, plan_timeout(<<"plain">>)),
    application:unset_env(barrel_mcp, tool_call_timeout).

infinity_is_max() ->
    ok = reg(<<"t">>, #{timeout => infinity}),
    ?assertEqual(?MAX, plan_timeout(<<"t">>)),
    ok = reg(<<"t">>, #{timeout => ?MAX}),
    ?assertEqual(?MAX, plan_timeout(<<"t">>)),
    ok = reg(<<"plain">>, #{}),
    application:set_env(barrel_mcp, tool_call_timeout, infinity),
    ?assertEqual(?MAX, plan_timeout(<<"plain">>)),
    application:unset_env(barrel_mcp, tool_call_timeout).

invalid_app_default() ->
    ok = reg(<<"plain">>, #{}),
    [
        begin
            application:set_env(barrel_mcp, tool_call_timeout, Bad),
            ?assertEqual(60000, plan_timeout(<<"plain">>))
        end
     || Bad <- [0, -5, ?MAX + 1, <<"60">>]
    ],
    application:unset_env(barrel_mcp, tool_call_timeout).

registration_validates() ->
    [
        ?assertEqual({error, {invalid_timeout, Bad}}, reg(<<"t">>, #{timeout => Bad}))
     || Bad <- [0, -1, ?MAX + 1, <<"x">>]
    ].

tool_timeout_wins() ->
    ok = reg(<<"t">>, #{timeout => 2000}),
    application:set_env(barrel_mcp, tool_call_timeout, 50),
    {async, Plan} = barrel_mcp_protocol:handle(call(<<"t">>, 300)),
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, maps:get(timeout, Plan)),
    application:unset_env(barrel_mcp, tool_call_timeout),
    ?assertMatch(#{<<"result">> := #{<<"content">> := [#{<<"text">> := <<"done">>}]}}, Resp).

call_times_out() ->
    ok = reg(<<"t">>, #{timeout => 50}),
    {async, Plan} = barrel_mcp_protocol:handle(call(<<"t">>, 5000)),
    T0 = erlang:monotonic_time(millisecond),
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, maps:get(timeout, Plan)),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assertMatch(#{<<"error">> := #{<<"message">> := <<"Tool timed out">>}}, Resp),
    ?assert(Elapsed < 1000).

timed_out_tool_is_stopped() ->
    ok = reg(<<"t">>, #{timeout => 50}),
    {async, Plan} = barrel_mcp_protocol:handle(call(<<"t">>, 5000)),
    Self = self(),
    _ = barrel_mcp_protocol:drive_async_plan(
        Plan, maps:get(timeout, Plan), undefined, fun(W) -> Self ! {worker, W} end
    ),
    Worker =
        receive
            {worker, W} -> W
        after 1000 -> error(no_worker)
        end,
    ?assert(is_pid(Worker)),
    ?assertNot(is_process_alive(Worker)).
