%%%-------------------------------------------------------------------
%%% @doc Task storage invariants.
%%%
%%% Tasks are keyed by task id alone, so the isolation that a compound
%%% `{SessionId, TaskId}' key used to give for free is now explicit
%%% code. These cases pin it: naming the right task from the wrong
%%% session must be indistinguishable from naming one that does not
%%% exist.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_tasks_tests).

-include_lib("eunit/include/eunit.hrl").

-export([slow_tool/1, killable_tool/1]).

tasks_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"A task is readable by its owner", fun own_session_reads/0},
        {"Another session cannot read it", fun other_session_cannot_read/0},
        {"Another session cannot mutate it", fun other_session_cannot_mutate/0},
        {"list/2 only returns the session's own", fun list_is_scoped/0},
        {"Sessionless tasks are isolated too", fun undefined_session/0},
        {"Ids are unique across sessions", fun ids_unique/0},
        {"Terminal transitions are idempotent", fun terminal_idempotent/0}
    ]}.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    ok.

%%====================================================================
%% Cases
%%====================================================================

own_session_reads() ->
    {ok, TaskId} = barrel_mcp_tasks:create(<<"s1">>, <<"tools/call">>, #{}),
    {ok, Task} = barrel_mcp_tasks:get(<<"s1">>, TaskId),
    ?assertEqual(TaskId, maps:get(<<"taskId">>, Task)),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, Task)),
    ?assertEqual(<<"s1">>, maps:get(<<"sessionId">>, Task)).

other_session_cannot_read() ->
    {ok, TaskId} = barrel_mcp_tasks:create(<<"owner">>, <<"tools/call">>, #{}),
    ?assertEqual({error, not_found}, barrel_mcp_tasks:get(<<"intruder">>, TaskId)),
    %% Knowing the id is not enough even when it plainly exists.
    ?assertMatch({ok, _}, barrel_mcp_tasks:get(<<"owner">>, TaskId)).

other_session_cannot_mutate() ->
    {ok, TaskId} = barrel_mcp_tasks:create(<<"owner2">>, <<"tools/call">>, #{}),
    ?assertEqual(
        {error, not_found},
        barrel_mcp_tasks:cancel(<<"intruder">>, TaskId)
    ),
    ?assertEqual(
        {error, not_found},
        barrel_mcp_tasks:finish(<<"intruder">>, TaskId, #{<<"content">> => []})
    ),
    ?assertEqual(
        {error, not_found},
        barrel_mcp_tasks:fail(<<"intruder">>, TaskId, boom)
    ),
    ?assertEqual(
        {error, not_found},
        barrel_mcp_tasks:set_worker(<<"intruder">>, TaskId, #{worker => self()})
    ),
    %% Still untouched for its owner.
    {ok, Task} = barrel_mcp_tasks:get(<<"owner2">>, TaskId),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, Task)).

list_is_scoped() ->
    {ok, A} = barrel_mcp_tasks:create(<<"list-a">>, <<"tools/call">>, #{}),
    {ok, _B} = barrel_mcp_tasks:create(<<"list-b">>, <<"tools/call">>, #{}),
    {ok, Own} = barrel_mcp_tasks:list(<<"list-a">>, #{}),
    Ids = [maps:get(<<"taskId">>, T) || T <- Own],
    ?assertEqual([A], Ids).

%% stdio has no sessions, so tasks there carry `undefined'. That still
%% has to be a real scope, not a wildcard.
undefined_session() ->
    {ok, TaskId} = barrel_mcp_tasks:create(undefined, <<"tools/call">>, #{}),
    ?assertMatch({ok, _}, barrel_mcp_tasks:get(undefined, TaskId)),
    ?assertEqual({error, not_found}, barrel_mcp_tasks:get(<<"s1">>, TaskId)),
    %% And a session-owned task is not visible to the sessionless scope.
    {ok, Owned} = barrel_mcp_tasks:create(<<"s-owned">>, <<"tools/call">>, #{}),
    ?assertEqual({error, not_found}, barrel_mcp_tasks:get(undefined, Owned)).

ids_unique() ->
    Ids = [
        begin
            {ok, Id} = barrel_mcp_tasks:create(<<"uniq">>, <<"tools/call">>, #{}),
            Id
        end
     || _ <- lists:seq(1, 50)
    ],
    ?assertEqual(50, length(lists:usort(Ids))).

terminal_idempotent() ->
    {ok, TaskId} = barrel_mcp_tasks:create(<<"term">>, <<"tools/call">>, #{}),
    ok = barrel_mcp_tasks:finish(<<"term">>, TaskId, #{<<"content">> => []}),
    %% A second transition is accepted but does not change the outcome.
    ok = barrel_mcp_tasks:fail(<<"term">>, TaskId, boom),
    {ok, Task} = barrel_mcp_tasks:get(<<"term">>, TaskId),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Task)),
    ?assertNot(maps:is_key(<<"error">>, Task)).

%%====================================================================
%% Long-running tools away from the streamable HTTP transport
%%
%% stdio and the simple HTTP transport both drive a tool call through
%% barrel_mcp_protocol:drive_async_plan/2,3. Until the long-running
%% decision moved into the protocol core they ignored `long_running'
%% entirely and blocked for up to 60 seconds instead.
%%====================================================================

slow_tool(_Args) ->
    timer:sleep(50),
    <<"finished">>.

%% Publishes itself so the test can kill it mid-flight, standing in for
%% a worker that dies without reporting: an exit signal from a
%% supervisor, an OOM kill, a node-local brutal shutdown.
killable_tool(_Args) ->
    persistent_term:put({?MODULE, killable}, self()),
    timer:sleep(60000),
    <<"never">>.

drive_async_plan_test_() ->
    {setup, fun setup_slow/0, fun cleanup_slow/1, [
        {"A modern caller gets a task", fun drive_returns_task/0},
        {"Without the extension it runs inline", fun drive_runs_inline/0},
        {"A legacy caller gets the wrapped shape", fun drive_legacy_shape/0},
        {"A killed worker fails its task", fun killed_worker_fails_task/0}
    ]}.

setup_slow() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp_registry:reg(tool, <<"slow_stdio">>, ?MODULE, slow_tool, #{
        long_running => true
    }),
    ok = barrel_mcp_registry:reg(tool, <<"killable">>, ?MODULE, killable_tool, #{
        long_running => true
    }),
    ok.

cleanup_slow(_) ->
    barrel_mcp_registry:unreg(tool, <<"slow_stdio">>),
    barrel_mcp_registry:unreg(tool, <<"killable">>),
    ok.

call_request(Meta) ->
    call_request(<<"slow_stdio">>, Meta).

call_request(Tool, Meta) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{
            <<"name">> => Tool,
            <<"arguments">> => #{},
            <<"_meta">> => Meta
        }
    }.

modern_meta(Capabilities) ->
    #{
        <<"io.modelcontextprotocol/protocolVersion">> => <<"2026-07-28">>,
        <<"io.modelcontextprotocol/clientCapabilities">> => Capabilities
    }.

drive(Request) ->
    {async, Plan} = barrel_mcp_protocol:handle(Request),
    barrel_mcp_protocol:drive_async_plan(Plan, 5000).

drive_returns_task() ->
    Caps = #{
        <<"extensions">> => #{<<"io.modelcontextprotocol/tasks">> => #{}}
    },
    Resp = drive(call_request(modern_meta(Caps))),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(<<"task">>, maps:get(<<"resultType">>, Result)),
    TaskId = maps:get(<<"taskId">>, Result),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, Result)),
    %% The worker reports into the task rather than back to the caller.
    Owner = {principal, undefined},
    wait_for_status(Owner, TaskId, <<"completed">>, 40),
    {ok, Task} = barrel_mcp_tasks:get(Owner, TaskId),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Task)),
    ?assertEqual(<<"finished">>, maps:get(<<"text">>, Block)).

drive_runs_inline() ->
    Resp = drive(call_request(modern_meta(#{}))),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"finished">>, maps:get(<<"text">>, Block)).

%% No _meta at all is a legacy call, which negotiated the core task
%% methods and expects the wrapped handle.
%% A worker killed without reporting used to leave the task `working'
%% forever: nothing was watching it, the collector blocked on a message
%% that never came, and the sweep skips working tasks by design.
killed_worker_fails_task() ->
    Caps = #{
        <<"extensions">> => #{<<"io.modelcontextprotocol/tasks">> => #{}}
    },
    Resp = drive(call_request(<<"killable">>, modern_meta(Caps))),
    Result = maps:get(<<"result">>, Resp),
    TaskId = maps:get(<<"taskId">>, Result),
    Owner = {principal, undefined},
    Worker = wait_for_worker(40),
    true = exit(Worker, kill),
    wait_for_status(Owner, TaskId, <<"failed">>, 40),
    {ok, Task} = barrel_mcp_tasks:get(Owner, TaskId),
    ?assertMatch(#{<<"error">> := _}, Task).

wait_for_worker(0) ->
    error(worker_never_started);
wait_for_worker(N) ->
    case persistent_term:get({?MODULE, killable}, undefined) of
        Pid when is_pid(Pid) ->
            _ = persistent_term:erase({?MODULE, killable}),
            Pid;
        undefined ->
            timer:sleep(25),
            wait_for_worker(N - 1)
    end.

drive_legacy_shape() ->
    Resp = drive(call_request(#{})),
    Result = maps:get(<<"result">>, Resp),
    ?assert(maps:is_key(<<"task">>, Result)),
    ?assertNot(maps:is_key(<<"resultType">>, Result)).

wait_for_status(_Owner, _TaskId, _Status, 0) ->
    error(task_never_settled);
wait_for_status(Owner, TaskId, Status, N) ->
    {ok, Task} = barrel_mcp_tasks:get(Owner, TaskId),
    case maps:get(<<"status">>, Task) of
        Status ->
            ok;
        _ ->
            timer:sleep(25),
            wait_for_status(Owner, TaskId, Status, N - 1)
    end.
