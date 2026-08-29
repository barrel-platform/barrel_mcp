-module(barrel_mcp_task_relay_tests).

-include_lib("eunit/include/eunit.hrl").

%% The worker finished and the relay ended before the request process
%% asked it to hold: hold/1 must return, with the result already in
%% the mailbox, not wait forever.
hold_after_relay_ended_test() ->
    Relay = barrel_mcp_task_relay:start(),
    Worker = spawn(fun() -> Relay ! {tool_result, 1, <<"done">>} end),
    barrel_mcp_task_relay:worker(Relay, Worker),
    wait_dead(Relay, 50),
    ?assertEqual(ok, barrel_mcp_task_relay:hold(Relay)),
    receive
        {tool_result, 1, <<"done">>} -> ok
    after 1000 -> error(result_lost)
    end.

%% A message in flight when the hold lands is released on redirect.
held_message_released_on_redirect_test() ->
    Relay = barrel_mcp_task_relay:start(),
    ok = barrel_mcp_task_relay:hold(Relay),
    Relay ! {tool_result, 2, <<"late">>},
    Self = self(),
    Collector = spawn(fun() ->
        receive
            M -> Self ! {collected, M}
        end
    end),
    Relay ! {redirect, Collector},
    receive
        {collected, {tool_result, 2, <<"late">>}} -> ok
    after 1000 -> error(held_message_lost)
    end,
    barrel_mcp_task_relay:stop(Relay).

wait_dead(_Pid, 0) ->
    error(still_alive);
wait_dead(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(20),
            wait_dead(Pid, N - 1)
    end.
