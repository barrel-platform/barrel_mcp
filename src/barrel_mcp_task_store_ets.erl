%%%-------------------------------------------------------------------
%%% @doc The default task store: a node-local ETS table.
%%%
%%% `protected' and owned by `barrel_mcp_tasks', which calls `init/1'
%%% from its own `init/1': only that process writes, and the table goes
%%% with it, so nothing here survives a restart.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_task_store_ets).

-behaviour(barrel_mcp_task_store).

-export([init/1, get/1, put/2, delete/1, fold/2, count/0]).

-define(TABLE, barrel_mcp_tasks_table).

init(_Opts) ->
    _ =
        case ets:whereis(?TABLE) of
            undefined ->
                ets:new(?TABLE, [named_table, protected, set, {read_concurrency, true}]);
            _ ->
                ok
        end,
    ok.

get(TaskId) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, Stored}] -> {ok, Stored};
        [] -> not_found
    end.

put(TaskId, Stored) ->
    true = ets:insert(?TABLE, {TaskId, Stored}),
    ok.

delete(TaskId) ->
    true = ets:delete(?TABLE, TaskId),
    ok.

fold(Fun, Acc) ->
    ets:foldl(fun({Id, S}, A) -> Fun(Id, S, A) end, Acc, ?TABLE).

count() ->
    ets:info(?TABLE, size).
