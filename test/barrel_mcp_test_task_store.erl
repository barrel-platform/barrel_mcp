%%%-------------------------------------------------------------------
%%% @doc A task store over an ETS table held outside the application,
%%% standing in for a durable one. It exports no `count/0' or
%%% `count_owned/1', so admission takes the fold path.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_test_task_store).

-behaviour(barrel_mcp_task_store).

-export([init/1, get/1, put/2, delete/1, fold/2]).
-export([start_table/0, stop_table/1]).

-define(TAB, barrel_mcp_test_task_store_tab).

start_table() ->
    Self = self(),
    Pid = spawn(fun() ->
        _ = ets:new(?TAB, [named_table, public, set]),
        Self ! {table_ready, self()},
        receive
            stop -> ok
        end
    end),
    receive
        {table_ready, Pid} -> Pid
    end.

stop_table(Pid) ->
    Pid ! stop,
    ok.

init(_Opts) ->
    case ets:whereis(?TAB) of
        undefined -> {error, no_table};
        _ -> ok
    end.

%% Stored as a binary, as a store off the heap would.
get(TaskId) ->
    case ets:lookup(?TAB, TaskId) of
        [{_, Bin}] -> {ok, binary_to_term(Bin)};
        [] -> not_found
    end.

put(TaskId, Stored) ->
    true = ets:insert(?TAB, {TaskId, term_to_binary(Stored)}),
    ok.

delete(TaskId) ->
    true = ets:delete(?TAB, TaskId),
    ok.

fold(Fun, Acc) ->
    ets:foldl(fun({Id, Bin}, A) -> Fun(Id, binary_to_term(Bin), A) end, Acc, ?TAB).
