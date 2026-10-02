# Durable Tasks

When a tool call takes longer than one request, the client gets a task:
a handle it polls until the work ends. By default barrel_mcp keeps tasks
in a node-local ETS table, so a restart or a failover loses every task
id even when the work behind it carries on, and the client is left
holding a handle that answers "Task not found". This guide shows how to
make a task outlive the node. You need it when your tools run work that
survives restarts, or when several nodes serve the same `/mcp` endpoint.

## Choose an approach

| Your situation | Use | You write |
|---|---|---|
| Ordinary tools; you want their tasks kept somewhere durable | a task store | 5 storage callbacks and one setting |
| Your application already runs durable work with its own id (jobs, workflows, agent executions) | a task provider | 3 callbacks, a tool option, and a call on each state change |

With a task store, barrel_mcp still runs the tool, owns the task and
drives it. With a task provider, your application owns the task and
barrel_mcp only speaks MCP for it. You can use both on the same server.

## What the client sees

Either way, a client sees the same protocol. Knowing it helps you check
your integration with `curl` or a test client.

A modern (2026-07-28) client opts into tasks by declaring the extension
in each request:

```json
{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
 "params": {"name": "run_agent", "arguments": {"goal": "triage inbox"},
  "_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {
      "extensions": {"io.modelcontextprotocol/tasks": {}}}}}}
```

If the work ends within the inline window (`task_inline_ms`, 100 ms by
default), the client gets the tool result in place, as for any tool.
Otherwise it gets a task:

```json
{"resultType": "task", "taskId": "exec_9f2c", "status": "working",
 "createdAt": "2026-10-02T09:00:00.000Z",
 "lastUpdatedAt": "2026-10-02T09:00:00.000Z",
 "ttlMs": 3600000, "pollIntervalMs": 2000}
```

From there the client:

- polls `tasks/get` with `{"taskId": "exec_9f2c"}` until `status` is
  `completed`, `failed` or `cancelled`. A completed task carries the
  tool result under `result`.
- may open `subscriptions/listen` with
  `{"notifications": {"taskIds": ["exec_9f2c"]}}` to be told of each
  change instead of polling.
- answers questions: when `status` is `input_required`, the task carries
  `inputRequests` (for example an `elicitation/create`), and the client
  replies with `tasks/update`:
  `{"taskId": "exec_9f2c", "inputResponses": {"approve": {"action": "accept"}}}`.
- may ask to stop with `tasks/cancel`.

A legacy (2025-11-25 and earlier) client gets the task at once, wrapped
as `{"task": {...}}` with `ttl` and `pollInterval`, and may also call
`tasks/list` and the blocking `tasks/result`.

A client that did not declare the extension never gets a task: the tool
answers in place, or is refused if it requires tasks.

What durability adds: the same `taskId` keeps working after a restart,
or on another node behind the same endpoint, for the same caller.

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

3. Register tools as usual. Nothing else changes: tools, `tasks/*`
   methods and notifications read and write through your module.

```erlang
barrel_mcp:reg_tool(<<"reindex">>, my_tools, reindex, #{task_support => optional}).
```

**What a client sees after a restart.**

| Task state before the restart | After |
|---|---|
| `completed`, `failed`, `cancelled` | Same answer from `tasks/get` until the task's ttl ends |
| `working` on the restarted node | `failed`, error `Task interrupted by a restart`: its worker is gone |
| `input_required` (modern client) | Still waiting. The client's `tasks/update` runs the handler again with the answers |
| any legacy task | `Task not found`: it belonged to a session, and sessions end with the node |

**Notes.**

- Every write comes from the `barrel_mcp_tasks` process; reads come from
  request processes, so allow concurrent reads.
- `count/0` and `count_owned/1` are optional. Without them, admission
  limits (`max_tasks_total`, `max_tasks_per_principal`) fold over the
  store on every task creation.
- An `input_required` task resumes from its stored state, so keep the
  handler state of `{input_required, Requests, State}` to plain data
  (no pids, refs or funs).
- With a store shared by several nodes, each node sweeps the live tasks
  it started, and takes over those of a node that is gone. Status
  notifications and `tasks/result` wake-ups stay on the node where the
  change happens: a client listening on another node polls instead.

## Hand back a task your application owns

**What it is.** A module implementing `barrel_mcp_task_provider`. Your
application holds the task's id, state, input rounds and cancel.
barrel_mcp stores nothing: it negotiates the extension, renders the task
for the client's era, applies the inline window, routes `tasks/*` by id
and delivers notifications.

**When to use it.** Your application already runs durable work, such as
a journaled execution that resumes after a restart or fails over to a
replica, and has its own id for it. The task id is that id.

The steps below use a hypothetical `my_executions` module standing for
your application: it starts work, stores it durably, and calls you back
when it changes.

### 1. Map your work to a task

`get/2` returns your work in this shape:

| Field | Required | What to put |
|---|---|---|
| `id` | yes | your work id, a binary; it is the `taskId` the client holds |
| `status` | yes | `working`, `input_required`, `completed`, `failed` or `cancelled` |
| `created_at`, `updated_at` | yes | milliseconds since the epoch |
| `result` | when `completed` | the CallToolResult, for example `#{<<"content">> => [...]}`; add `<<"isError">> => true` for a tool-level failure |
| `error` | when `failed` | why it failed at protocol level; a binary or `#{<<"code">>, <<"message">>}` |
| `input_requests` | when `input_required` | the questions, keyed: `#{Key => #{<<"method">> => ..., <<"params">> => ...}}` |
| `ttl_ms` | no | how long the client may keep polling |
| `poll_interval_ms` | no | how often the client should poll |

Decide how your own states map to these five. For example, a job that
is queued, running or retrying is `working`; one waiting on an operator
is `input_required`.

### 2. Implement the provider

Store the caller's principal with the work, and check it on every call.
A task held by someone else must answer `{error, not_found}`, exactly
like an unknown id, so a caller cannot probe for other people's ids.

```erlang
-module(my_task_provider).
-behaviour(barrel_mcp_task_provider).

-export([get/2, cancel/2, update/3]).

get(Owner, TaskId) ->
    case held(Owner, TaskId) of
        {ok, Exec} -> {ok, to_task(Exec)};
        not_found -> {error, not_found}
    end.

cancel(Owner, TaskId) ->
    case held(Owner, TaskId) of
        {ok, _} -> my_executions:cancel(TaskId);
        not_found -> {error, not_found}
    end.

update(Owner, TaskId, Responses) ->
    case held(Owner, TaskId) of
        {ok, _} -> my_executions:answer(TaskId, Responses);
        not_found -> {error, not_found}
    end.

held(Owner, TaskId) ->
    Principal = barrel_mcp_tasks:principal(Owner),
    case my_executions:lookup(TaskId) of
        {ok, #{principal := Principal} = Exec} -> {ok, Exec};
        _ -> not_found
    end.

to_task(#{id := Id, state := State, started := C, changed := U} = Exec) ->
    Base = #{
        id => Id,
        status => State,
        created_at => C,
        updated_at => U,
        poll_interval_ms => 2000
    },
    maps:merge(Base, maps:with([result, error, input_requests], Exec)).
```

`my_executions:cancel/1` and `my_executions:answer/2` return `ok`.

### 3. Register the tool and start the work

```erlang
barrel_mcp:reg_tool(<<"run_agent">>, my_tools, run_agent, #{
    task_support => optional,
    task_provider => my_task_provider
}).
```

The handler starts the work and returns `{task, Id}` at once. It keeps
the owner with the work, for step 4:

```erlang
run_agent(Args, Ctx) ->
    case barrel_mcp:task_allowed(Ctx) of
        true ->
            Owner = barrel_mcp:task_owner(Ctx),
            {ok, Id} = my_executions:start(Args, #{
                principal => barrel_mcp_tasks:principal(Owner),
                owner => Owner
            }),
            {task, Id};
        false ->
            %% This client cannot follow a task: answer the old way.
            {ok, Id} = my_executions:start(Args, #{}),
            {structured, #{<<"execution_id">> => Id}}
    end.
```

`task_allowed/1` is false when the client did not declare the tasks
extension. Returning `{task, Id}` then fails the call, so always check
it.

### 4. Tell barrel_mcp when the work changes

Call `changed/3` on every state change: it pushes the new status to
clients listening on `subscriptions/listen` (and to a legacy session),
and wakes a pending `tasks/result`.

```erlang
on_execution_changed(#{id := Id, owner := Owner}) ->
    _ = barrel_mcp_tasks:changed(my_task_provider, Owner, Id),
    ok.
```

Clients that poll see the change without it; listeners and
`tasks/result` see it sooner with it.

### 5. Ask the user a question

To pause for input, move the work to `input_required`, publish the
question in `input_requests`, and call `changed/3`:

```erlang
#{<<"approve">> => #{
    <<"method">> => <<"elicitation/create">>,
    <<"params">> => #{<<"message">> => <<"Send 12 emails?">>}
}}
```

The client answers with `tasks/update`; barrel_mcp calls your
`update/3` with `#{<<"approve">> => Answer}` and acknowledges. Your
application decides when the work goes back to `working`, then calls
`changed/3` again. barrel_mcp keeps no state for this round.

### 6. Handle cancel

`tasks/cancel` calls your `cancel/2`. Stop the work if you can, then
report the state it really ends in: `cancelled`, or `completed` or
`failed` if it finished first. A cancelled task may also stay `working`
for a while; the client keeps polling.

### 7. Check it works

```erlang
Owner = {principal, {my_auth, undefined, <<"alice">>}},
{ok, Task} = barrel_mcp_tasks:get(Owner, <<"exec_9f2c">>, modern),
<<"working">> = maps:get(<<"status">>, Task),
{error, not_found} = barrel_mcp_tasks:get({principal, other}, <<"exec_9f2c">>, modern).
```

Then restart your node and call `tasks/get` again as the same caller:
the task is still there, because barrel_mcp never held it.

**Notes.**

- `Owner` is plain data for a modern client (`{principal, P}`), so you
  can persist it with the work. A legacy owner is a session id, which
  does not survive a restart; `barrel_mcp_tasks:principal/1` still
  matches the same caller on a new session.
- `barrel_mcp_tasks:principal/1` is stable across restarts and token
  refreshes, and `undefined` for an unauthenticated caller: decide
  whether anonymous callers may share tasks.
- A handler that returns a plain result is answered in place. If the
  task is already `completed` within the inline window, the modern
  client gets its `result` in place too.
- Export `list/1` to include your tasks in legacy `tasks/list`, and
  `await/3` to replace the polling behind `tasks/result`.
- Provider tasks do not count against `max_tasks_per_principal` or
  `max_tasks_total`: bound them in your application.
- Providers are asked in order: the `task_providers` application env
  (`barrel_mcp:register_task_provider/1`), then the modules named by
  registered tools. Register the module in the env if tasks must resolve
  before your tools are registered again after a restart. A provider
  that raises is logged and skipped.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Task not found` for a task you can see in your application | `get/2` compares a different principal: store `barrel_mcp_tasks:principal(Owner)`, not the whole `auth_info` |
| The call answers `Internal tool error` | the handler returned `{task, Id}` when `task_allowed/1` was false, or `get/2` does not find the id it just returned |
| Listeners never hear about changes | `changed/3` is not called, or is called on another node than the listener's |
| A task stays `input_required` after `tasks/update` | your application never moved it back to `working` and called `changed/3` |
| Built-in tasks come back `failed` after a restart | expected: they were `working` and their worker died with the node |
