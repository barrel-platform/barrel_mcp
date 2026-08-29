%%%-------------------------------------------------------------------
%%% @doc The process a task-supporting tool reports to while it is not
%%% yet known whether its call is answered synchronously or as a task.
%%%
%%% tasks.md "Task Creation": a task-supporting tool may still answer
%%% synchronously when it can, and an MRTR round before the work starts
%%% is synchronous too. So the worker is started before the task, with
%%% this relay as its `reply_to'. Whatever arrives within the inline
%%% window goes to the request process and is answered in place. When
%%% the window closes the request process holds the relay, drains its
%%% own mailbox, and if nothing came creates the task and redirects the
%%% relay to the task's collector. A message in flight at that moment
%%% is held and released on redirect, so none is ever lost between the
%%% two.
%%%
%%% The collector watches the relay rather than the worker: the relay
%%% ends when the worker has, with the worker's reason, after forwarding
%%% everything the worker sent. Being the same sender, its exit can
%%% never overtake a result.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_task_relay).

-export([start/0, worker/2, hold/1, stop/1, escalate/6, inline_ms/0]).

%% @doc Start a relay reporting to the calling process. Linked: a
%% request process that dies takes an unanswered relay with it.
-spec start() -> pid().
start() ->
    Owner = self(),
    spawn_link(fun() ->
        loop(#{owner => Owner, target => Owner, held => [], down => undefined})
    end).

%% @doc Tell the relay which worker to watch. `undefined' when the tool
%% could not be started; its failure is already on its way.
-spec worker(pid(), pid() | undefined) -> ok.
worker(Relay, Worker) ->
    Relay ! {worker, Worker},
    ok.

%% @doc Stop forwarding and wait for the acknowledgement, after which
%% nothing more lands in the caller's mailbox.
-spec hold(pid()) -> ok.
hold(Relay) ->
    Relay ! {hold, self()},
    receive
        {relay_held, Relay} -> ok
    after infinity -> ok
    end.

%% @doc The call was answered in place; the relay is not needed.
-spec stop(pid()) -> ok.
stop(Relay) ->
    Relay ! stop,
    ok.

%% @doc How long a task-supporting tool may take before its call becomes
%% a task.
-spec inline_ms() -> non_neg_integer().
inline_ms() ->
    application:get_env(barrel_mcp, task_inline_ms, 100).

%% @doc Create the task for a held relay's worker and redirect the relay
%% to the task's collector. The task exists before this returns, so a
%% `tasks/get' for the handle resolves at once (tasks.md "Task
%% Creation"). Returns the `CreateTaskResult' for the caller's era.
-spec escalate(pid(), pid() | undefined, term(), binary(), map(), map()) ->
    {ok, map()} | {error, too_many_tasks}.
escalate(Relay, Worker, Owner, ToolName, Params, Ctx) ->
    case barrel_mcp_tasks:create(Owner, ToolName, #{params => Params}) of
        {error, too_many_tasks} ->
            stop(Relay),
            _ = is_pid(Worker) andalso exit(Worker, kill),
            {error, too_many_tasks};
        {ok, TaskId} ->
            {Collector, _} = barrel_mcp_protocol:spawn_task_collector(
                Owner, TaskId, fun(_Collector) -> Relay end
            ),
            Relay ! {redirect, Collector},
            _ =
                case is_pid(Worker) of
                    true ->
                        barrel_mcp_tasks:set_worker(Owner, TaskId, #{
                            worker => Worker, request_id => maps:get(request_id, Ctx, undefined)
                        });
                    false ->
                        ok
                end,
            Task =
                case
                    barrel_mcp_tasks:get(Owner, TaskId, barrel_mcp_ctx:era(maps:get(mcp_ctx, Ctx)))
                of
                    {ok, T} -> T;
                    _ -> #{<<"taskId">> => TaskId, <<"status">> => <<"working">>}
                end,
            {ok, barrel_mcp_protocol:create_task_result(TaskId, Task, maps:get(mcp_ctx, Ctx))}
    end.

%%====================================================================
%% The relay itself
%%====================================================================

loop(#{owner := Owner, target := Target, held := Held, down := Down} = State) ->
    receive
        {worker, Pid} when is_pid(Pid) ->
            _ = monitor(process, Pid),
            loop(State);
        {worker, _} ->
            loop(State);
        {hold, From} ->
            From ! {relay_held, self()},
            loop(State#{target => undefined});
        {redirect, NewTarget} ->
            _ = [NewTarget ! M || M <- lists:reverse(Held)],
            case Down of
                undefined -> loop(State#{target => NewTarget, held => []});
                Reason -> exit(Reason)
            end;
        stop ->
            ok;
        {'DOWN', _Ref, process, _Worker, Reason} when Target =:= undefined ->
            loop(State#{down => worker_reason(Reason)});
        {'DOWN', _Ref, process, _Worker, _Reason} when Target =:= Owner ->
            %% Still linked to the request process: whatever the worker
            %% did has reached it as a message.
            exit(normal);
        {'DOWN', _Ref, process, _Worker, Reason} ->
            exit(worker_reason(Reason));
        Msg when Target =:= undefined ->
            loop(State#{held => [Msg | Held]});
        Msg ->
            Target ! Msg,
            loop(State)
    after infinity ->
        ok
    end.

%% A worker gone before it could be watched had still sent everything
%% it was going to.
worker_reason(noproc) -> normal;
worker_reason(Reason) -> Reason.
