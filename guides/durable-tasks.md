# Durable Tasks

A task is the handle a client polls when a tool call takes longer than
one request. By default barrel_mcp keeps tasks in a node-local ETS
table, so a restart or a failover loses every task id even when the
work behind it carries on. This guide shows the two ways to make a task
outlive the node: keep barrel_mcp's own tasks in a store you provide,
or let your application own the task outright. You need one of them
when your tools run work that survives restarts, or when several nodes
serve the same `/mcp` endpoint.

| You want | Use |
|---|---|
| barrel_mcp's tasks kept somewhere durable | a task store (`task_store`) |
| a task whose id and state your application already holds | a task provider (`task_provider`) |

## Keep built-in tasks in your own store

**What it is.** A module implementing `barrel_mcp_task_store`. barrel_mcp
still runs the worker, the lifecycle and the input rounds; your module
only stores the records.

**When to use it.** Your tools are ordinary `task_support` tools and you
want their tasks to be found after a restart.

**How.**

1. Implement the behaviour. Values are opaque maps: store them whole.

```erlang
-module(my_task_store).
-behaviour(barrel_mcp_task_store).

-export([init/1, get/1, put/2, delete/1, fold/2]).

init(_Opts) -> ok.

get(TaskId) ->
    case my_db:read(tasks, TaskId) of
        {ok, Bin} -> {ok, binary_to_term(Bin)};
        not_found -> not_found
    end.

put(TaskId, Stored) ->
    my_db:write(tasks, TaskId, term_to_binary(Stored)).

delete(TaskId) ->
    my_db:delete(tasks, TaskId).

fold(Fun, Acc) ->
    my_db:fold(tasks, fun(Id, Bin, A) -> Fun(Id, binary_to_term(Bin), A) end, Acc).
```

2. Configure it before `barrel_mcp` starts:

```erlang
{barrel_mcp, [
    {task_store, my_task_store},
    {task_store_opts, #{}}
]}.
```

3. Nothing else changes. Tools, `tasks/*` methods and notifications read
   and write through your module.

**Notes.**

- Every write comes from the `barrel_mcp_tasks` process; reads come from
  request processes, so allow concurrent reads.
- `count/0` and `count_owned/1` are optional. Without them, admission
  limits (`max_tasks_total`, `max_tasks_per_principal`) fold over the
  store on every task creation.
- After a restart, a task that was `working` on this node has lost its
  worker. It comes back `failed` with `Task interrupted by a restart`.
  Terminal tasks are served until their ttl. A modern `input_required`
  task resumes when the client answers through `tasks/update`, so keep
  MRTR handler state to plain data.
- Legacy tasks belong to their session, and sessions do not survive a
  restart. Only modern (principal-owned) tasks are reachable afterwards.
- With a store shared by several nodes, each node sweeps the live tasks
  it started, and takes over those of a node that is gone. Status
  notifications and `tasks/result` wake-ups stay on the node where the
  change happens.

## Hand back a task your application owns

**What it is.** A module implementing `barrel_mcp_task_provider`. Your
application holds the task's id, state, input rounds and cancel.
barrel_mcp stores nothing: it negotiates the extension, renders the task
for the client's era, applies the inline window, routes `tasks/*` by id
and delivers notifications.

**When to use it.** Your application already runs durable work, such as
a journaled execution that resumes after a restart or fails over to a
replica, and has its own id for it.

**How.**

1. Implement the provider. Store the caller's principal with the task
   and compare it on every call.

```erlang
-module(my_task_provider).
-behaviour(barrel_mcp_task_provider).

-export([get/2, cancel/2, update/3]).

get(Owner, TaskId) ->
    case my_executions:lookup(TaskId) of
        {ok, #{principal := P} = Exec} ->
            case barrel_mcp_tasks:principal(Owner) of
                P -> {ok, to_task(Exec)};
                _ -> {error, not_found}
            end;
        not_found ->
            {error, not_found}
    end.

cancel(Owner, TaskId) ->
    case get(Owner, TaskId) of
        {ok, _} -> my_executions:cancel(TaskId);
        Err -> Err
    end.

update(Owner, TaskId, Responses) ->
    case get(Owner, TaskId) of
        {ok, _} -> my_executions:answer(TaskId, Responses);
        Err -> Err
    end.

to_task(#{id := Id, state := State, started := C, changed := U} = Exec) ->
    #{
        id => Id,
        status => State,
        created_at => C,
        updated_at => U,
        result => maps:get(result, Exec, #{<<"content">> => []}),
        input_requests => maps:get(questions, Exec, #{}),
        poll_interval_ms => 2000
    }.
```

2. Register the tool with the provider and let the handler start the
   work and return its id.

```erlang
barrel_mcp:reg_tool(<<"run_agent">>, my_tools, run_agent, #{
    task_support => optional,
    task_provider => my_task_provider
}).
```

```erlang
run_agent(Args, Ctx) ->
    case barrel_mcp:task_allowed(Ctx) of
        true ->
            Owner = barrel_mcp:task_owner(Ctx),
            {ok, Id} = my_executions:start(Args, barrel_mcp_tasks:principal(Owner), Owner),
            {task, Id};
        false ->
            %% The client cannot follow a task: answer the old way.
            {ok, Id} = my_executions:start(Args, undefined, undefined),
            {structured, #{<<"execution_id">> => Id}}
    end.
```

3. Announce every change so listeners and waiters see it:

```erlang
ok = barrel_mcp_tasks:changed(my_task_provider, Owner, TaskId).
```

**Notes.**

- `Owner` is the term `barrel_mcp:task_owner/1` returned. Keep it with
  the task if you call `changed/3`: a modern owner is plain data.
- A task another principal holds must answer `{error, not_found}`, the
  same as an unknown id. `barrel_mcp_tasks:principal/1` is stable across
  restarts and token refreshes, and `undefined` for an unauthenticated
  caller.
- Status is one of `working`, `input_required`, `completed`, `failed`,
  `cancelled`. `result` is the CallToolResult (with `isError` for a tool
  failure); `error` is for a protocol failure only.
- A modern client gets the result in place when the task ends within the
  inline window (`task_inline_ms`), and the task otherwise. A legacy
  client gets the task at once. A handler that returns a plain result is
  answered in place.
- `tasks/update` calls `update/3` and acknowledges. Your provider decides
  when the task leaves `input_required`; publish the questions through
  `input_requests`.
- `tasks/cancel` calls `cancel/2`. Cancellation is cooperative: the task
  may stay `working`, or still end `completed` or `failed`.
- Export `list/1` to include your tasks in legacy `tasks/list`, and
  `await/3` to replace the polling behind `tasks/result`.
- Provider tasks do not count against `max_tasks_per_principal` or
  `max_tasks_total`: bound them in your application.
- Providers are asked in order: the `task_providers` application env
  (`barrel_mcp:register_task_provider/1`), then the modules named by
  registered tools. A provider that raises is logged and skipped.
