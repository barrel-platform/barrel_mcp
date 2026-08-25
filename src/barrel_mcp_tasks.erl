%%%-------------------------------------------------------------------
%%% @doc Long-running operation registry (MCP tasks).
%%%
%%% Tools registered with `long_running => true' return immediately
%%% with a `taskId' instead of synchronously producing a result. The
%%% worker continues in the background; clients poll via
%%% `tasks/get', enumerate via `tasks/list', and abort via
%%% `tasks/cancel'. State transitions emit
%%% `notifications/tasks/status' on the session's SSE channel.
%%%
%%% Tasks live in a `protected' ETS table keyed by `TaskId', which is
%%% crypto-random and so unique on its own. Who owns a task is a field
%%% rather than part of the key: a task id is the durable handle a
%%% client holds, and it has to be resolvable without knowing what
%%% created it.
%%%
%%% The owner is opaque here, and differs by era. A legacy task is
%%% owned by its session id; a modern one has no session, so it is
%%% owned by the authenticated principal. Either way every lookup
%%% matches on it, so one owner cannot reach another's tasks.
%%%
%%% A periodic sweep evicts terminal tasks (success / error /
%%% cancelled) older than `?TASK_TTL'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_tasks).

-behaviour(gen_server).

-export([
    start_link/0,
    create/3,
    get/2,
    get/3,
    list/2,
    cancel/2,
    finish/3,
    fail/3,
    set_worker/3,
    update/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(TABLE, barrel_mcp_tasks_table).
%% 1 hour
-define(TASK_TTL, 3600 * 1000).
%% 1 minute
-define(SWEEP_INTERVAL, 60 * 1000).
%% How long a terminal record outlives its ttl, so a late poll sees the
%% outcome rather than a bare not-found.
-define(TERMINAL_RETENTION, 60 * 1000).

-record(task, {
    id :: binary(),
    %% A session id (legacy) or `{principal, AuthInfo}' (modern).
    owner :: term(),
    method :: binary(),
    %% Spec vocabulary (MCP 2025-11-25):
    %%   submitted | working | completed | failed | cancelled
    %% We don't model `submitted' today (workers start immediately),
    %% so the initial state is `working' and terminal states are
    %% `completed', `failed', `cancelled'.
    %% `input_required' is 2025-11-25 core, not something the 2026
    %% extension added: both eras have it, and reach it differently.
    status :: working | input_required | completed | failed | cancelled,
    result :: term(),
    error :: term(),
    created_at :: integer(),
    updated_at :: integer(),
    %% Retention this task was actually granted, which is what a
    %% requestor is told and what expiry is computed from. A requested
    %% value may be clamped, and the answer must report what was
    %% granted rather than what was asked for.
    ttl_ms :: pos_integer() | undefined,
    %% Bumped whenever the task is re-driven, so a result from a worker
    %% that has been superseded or expired can be told apart from the
    %% current one and discarded.
    generation = 0 :: non_neg_integer(),
    worker_pid :: pid() | undefined,
    request_id :: integer() | binary() | undefined,
    %% Answers a client supplied through `tasks/update'. Recorded even
    %% when nothing is waiting on them, since the extension has the
    %% server ignore responses it does not need rather than reject
    %% them.
    input_responses = #{} :: map()
}).

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Create a new running task. Returns the task id.
-spec create(
    SessionId :: binary() | undefined,
    Method :: binary(),
    Opts :: map()
) -> {ok, binary()}.
create(Owner, Method, Opts) ->
    gen_server:call(?MODULE, {create, Owner, Method, Opts}).

%% @doc Read a task, rendered for the handshake era.
-spec get(SessionId :: binary() | undefined, TaskId :: binary()) ->
    {ok, map()} | {error, not_found}.
get(SessionId, TaskId) ->
    get(SessionId, TaskId, legacy).

%% @doc Read a task rendered for a given era. The retention field is
%% named `ttl' through 2025-11-25 and `ttlMs' in the extension.
-spec get(binary() | undefined, binary(), legacy | modern) ->
    {ok, map()} | {error, not_found}.
get(SessionId, TaskId, Era) ->
    case lookup(SessionId, TaskId) of
        {ok, Task} -> {ok, task_to_map(Task, Era)};
        {error, not_found} -> {error, not_found}
    end.

%% A task is only visible to the session that owns it. Naming the right
%% id but the wrong session is indistinguishable from naming an id that
%% does not exist.
lookup(Owner, TaskId) ->
    case ets:lookup(?TABLE, TaskId) of
        [{_, #task{owner = Owner} = Task}] -> {ok, Task};
        _ -> {error, not_found}
    end.

-spec list(SessionId :: binary() | undefined, map()) -> {ok, [map()]}.
list(SessionId, _Opts) ->
    Tasks = ets:foldl(
        fun
            ({_, #task{owner = S} = T}, Acc) when S =:= SessionId ->
                [task_to_map(T) | Acc];
            (_, Acc) ->
                Acc
        end,
        [],
        ?TABLE
    ),
    {ok, Tasks}.

%% @doc Mark a task as cancelled and notify the client. Sends
%% `{cancel, RequestId}' to the worker pid (if recorded) so
%% cooperative arity-2 handlers can abort.
-spec cancel(binary() | undefined, binary()) -> ok | {error, not_found}.
cancel(SessionId, TaskId) ->
    gen_server:call(?MODULE, {cancel, SessionId, TaskId}).

%% @doc Record the worker pid (and optional originating request id)
%% on a running task so a later `tasks/cancel' can stop it.
-spec set_worker(
    binary() | undefined,
    binary(),
    #{
        worker := pid(),
        request_id => integer() | binary()
    }
) ->
    ok | {error, not_found}.
set_worker(SessionId, TaskId, Info) ->
    gen_server:call(?MODULE, {set_worker, SessionId, TaskId, Info}).

%% @doc Record success: store the result and emit notifications/tasks/status.
-spec finish(binary() | undefined, binary(), term()) -> ok | {error, not_found}.
finish(SessionId, TaskId, Result) ->
    gen_server:call(?MODULE, {finish, SessionId, TaskId, Result}).

%% @doc Record failure: store the error and emit notification.
-spec fail(term(), binary(), term()) -> ok | {error, not_found}.
fail(Owner, TaskId, Reason) ->
    gen_server:call(?MODULE, {fail, Owner, TaskId, Reason}).

%% @doc Record answers a client supplied for a task through
%% `tasks/update'. Merged rather than replaced, so a client answering
%% one key at a time does not drop the others.
-spec update(term(), binary(), map()) -> ok | {error, not_found}.
update(Owner, TaskId, Responses) when is_map(Responses) ->
    gen_server:call(?MODULE, {update, Owner, TaskId, Responses}).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = ensure_table(),
    erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {ok, #{}}.

%% What the requestor asked for, clamped to what this server is willing
%% to hold. Reporting the granted value is required; reporting the
%% request back would be a lie whenever it was clamped.
granted_ttl(Opts) ->
    Default = application:get_env(barrel_mcp, task_ttl_ms, ?TASK_TTL),
    Max = application:get_env(barrel_mcp, task_max_ttl_ms, ?TASK_TTL),
    case maps:get(ttl, Opts, undefined) of
        Requested when is_integer(Requested), Requested > 0 -> min(Requested, Max);
        _ -> min(Default, Max)
    end.

ttl_or_null(undefined) -> null;
ttl_or_null(Ttl) -> Ttl.

handle_call({create, Owner, Method, Opts}, _From, State) ->
    Now = erlang:system_time(millisecond),
    TaskId = generate_id(),
    Task = #task{
        id = TaskId,
        owner = Owner,
        method = Method,
        status = working,
        ttl_ms = granted_ttl(Opts),
        created_at = Now,
        updated_at = Now
    },
    true = ets:insert(?TABLE, {TaskId, Task}),
    notify_changed(Owner, Task),
    {reply, {ok, TaskId}, State};
handle_call({cancel, SessionId, TaskId}, _From, State) ->
    %% Best-effort: send the worker a cooperative cancel signal so
    %% arity-2 tool handlers can short-circuit. Then transition
    %% the stored status. Arity-1 handlers run to completion;
    %% their result is dropped because the task is already in a
    %% terminal state.
    _ =
        case lookup(SessionId, TaskId) of
            {ok, #task{worker_pid = Pid, request_id = ReqId}} when is_pid(Pid) ->
                try
                    Pid ! {cancel, ReqId}
                catch
                    _:_ -> ok
                end;
            _ ->
                ok
        end,
    Reply = transition(SessionId, TaskId, cancelled, undefined, undefined),
    {reply, Reply, State};
handle_call({set_worker, SessionId, TaskId, Info}, _From, State) ->
    Reply =
        case lookup(SessionId, TaskId) of
            {ok, Task} ->
                Updated = Task#task{
                    worker_pid = maps:get(worker, Info),
                    request_id = maps:get(request_id, Info, undefined)
                },
                true = ets:insert(?TABLE, {TaskId, Updated}),
                ok;
            {error, not_found} ->
                {error, not_found}
        end,
    {reply, Reply, State};
handle_call({update, Owner, TaskId, Responses}, _From, State) ->
    Reply =
        case lookup(Owner, TaskId) of
            {ok, #task{input_responses = Existing} = Task} ->
                Updated = Task#task{
                    input_responses = maps:merge(Existing, Responses),
                    updated_at = erlang:system_time(millisecond)
                },
                true = ets:insert(?TABLE, {TaskId, Updated}),
                ok;
            {error, not_found} ->
                {error, not_found}
        end,
    {reply, Reply, State};
handle_call({finish, SessionId, TaskId, Result}, _From, State) ->
    Reply = transition(SessionId, TaskId, completed, Result, undefined),
    {reply, Reply, State};
handle_call({fail, SessionId, TaskId, Reason}, _From, State) ->
    Reply = transition(SessionId, TaskId, failed, undefined, Reason),
    {reply, Reply, State};
handle_call(_, _, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(sweep, State) ->
    Now = erlang:system_time(millisecond),
    {Expired, Stranded, Reapable} = ets:foldl(
        fun({TaskId, T}, {E, S, R}) ->
            classify_for_sweep(TaskId, T, Now, {E, S, R})
        end,
        {[], [], []},
        ?TABLE
    ),
    %% Expiry applies in every state. A working or input_required task
    %% past its ttl would otherwise hold its worker and continuation
    %% for the life of the node, since a task that legitimately runs for
    %% hours looks exactly the same.
    lists:foreach(fun(T) -> expire(T) end, Expired),
    lists:foreach(
        fun({TaskId, #task{owner = Owner}}) ->
            _ = transition(Owner, TaskId, failed, undefined, worker_died)
        end,
        Stranded
    ),
    lists:foreach(fun(K) -> ets:delete(?TABLE, K) end, Reapable),
    erlang:send_after(?SWEEP_INTERVAL, self(), sweep),
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

%%====================================================================
%% Internal
%%====================================================================

ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            ets:new(?TABLE, [
                named_table,
                protected,
                set,
                {read_concurrency, true}
            ]);
        _ ->
            ok
    end.

generate_id() ->
    Rand = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(Rand, lowercase),
    <<"task_", Hex/binary>>.

%% Three outcomes: past its ttl in any state, working with a dead worker
%% and nothing reported, or a terminal record whose retention window has
%% also elapsed.
classify_for_sweep(TaskId, #task{status = St} = T, Now, {E, S, R}) ->
    case {expired(T, Now), St} of
        {true, _} ->
            {[T | E], S, R};
        {false, working} ->
            case stranded(T, Now) of
                true -> {E, [{TaskId, T} | S], R};
                false -> {E, S, R}
            end;
        {false, input_required} ->
            {E, S, R};
        {false, _Terminal} ->
            case reapable(T, Now) of
                true -> {E, S, [TaskId | R]};
                false -> {E, S, R}
            end
    end.

%% From creation, not from the last update: ttl is the retention this
%% task was granted, and touching it must not extend that.
expired(#task{ttl_ms = undefined}, _Now) ->
    false;
expired(#task{created_at = C, ttl_ms = Ttl}, Now) ->
    Now > C + Ttl.

%% A terminal record is kept a little past expiry so a late poll sees
%% the outcome rather than a bare not-found.
reapable(#task{created_at = C, ttl_ms = Ttl}, Now) when is_integer(Ttl) ->
    Now > C + Ttl + ?TERMINAL_RETENTION;
reapable(#task{updated_at = U}, Now) ->
    Now > U + ?TASK_TTL.

%% An expired task stops whatever it was doing and is fenced, so a
%% result arriving from the worker afterwards cannot revive it.
expire(#task{id = TaskId, owner = Owner, worker_pid = Worker, generation = G}) ->
    _ =
        case is_pid(Worker) andalso is_process_alive(Worker) of
            true -> exit(Worker, kill);
            false -> ok
        end,
    case lookup(Owner, TaskId) of
        {ok, Current} ->
            true = ets:insert(?TABLE, {TaskId, Current#task{generation = G + 1}}),
            _ = transition(Owner, TaskId, failed, undefined, expired_error()),
            ok;
        {error, not_found} ->
            ok
    end.

expired_error() ->
    #{<<"code">> => -32603, <<"message">> => <<"Task expired">>}.

%% A working task whose worker is gone and which nothing has reported
%% on. The collector normally records the outcome the moment the worker
%% dies; this only catches the case where the collector died with it,
%% which would otherwise leave the task working forever, since the
%% sweep never evicts a working task and a long-running one legitimately
%% stays working for hours.
%%
%% The grace period is what keeps this from racing a collector that is
%% mid-report: a worker that exited a whole sweep interval ago has had
%% its result recorded by now if it produced one.
stranded(#task{worker_pid = Worker, updated_at = U}, Now) when is_pid(Worker) ->
    U < Now - ?SWEEP_INTERVAL andalso not is_process_alive(Worker);
stranded(_Task, _Now) ->
    false.

transition(SessionId, TaskId, Status, Result, Reason) ->
    case lookup(SessionId, TaskId) of
        {ok, #task{status = working} = Task} ->
            Updated = Task#task{
                status = Status,
                result = Result,
                error = Reason,
                updated_at = erlang:system_time(millisecond)
            },
            true = ets:insert(?TABLE, {TaskId, Updated}),
            notify_changed(SessionId, Updated),
            ok;
        {ok, _Terminal} ->
            %% Already terminal — idempotent.
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

%% Only a legacy task has a session channel to notify on. A modern
%% client polls `tasks/get' instead.
notify_changed(SessionId, _Task) when not is_binary(SessionId) ->
    ok;
notify_changed(SessionId, #task{} = Task) ->
    case barrel_mcp_session:get_sse_pid(SessionId) of
        {ok, Pid} when is_pid(Pid) ->
            Pid !
                {sse_send_message, #{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"method">> => <<"notifications/tasks/status">>,
                    <<"params">> => task_to_map(Task)
                }},
            ok;
        _ ->
            ok
    end.

task_to_map(Task) ->
    task_to_map(Task, legacy).

%% The two eras name the retention field differently: `ttl' through
%% 2025-11-25, `ttlMs' in the extension. Both report what was granted,
%% not what was asked for, and both require it.
task_to_map(
    #task{
        id = Id,
        owner = Owner,
        method = M,
        status = St,
        result = R,
        error = E,
        created_at = C,
        updated_at = U,
        ttl_ms = Ttl
    },
    Era
) ->
    TtlKey =
        case Era of
            modern -> <<"ttlMs">>;
            _ -> <<"ttl">>
        end,
    Base = #{
        <<"taskId">> => Id,
        <<"method">> => M,
        <<"status">> => atom_to_binary(St, utf8),
        <<"createdAt">> => to_rfc3339(C),
        <<"lastUpdatedAt">> => to_rfc3339(U),
        TtlKey => ttl_or_null(Ttl)
    },
    Base1 =
        case Owner of
            Sid when is_binary(Sid) -> Base#{<<"sessionId">> => Sid};
            _ -> Base
        end,
    Base2 =
        case St =:= completed of
            true when R =/= undefined -> Base1#{<<"result">> => R};
            _ -> Base1
        end,
    case St =:= failed of
        true when E =/= undefined ->
            Base2#{<<"error">> => format_error(E)};
        _ ->
            Base2
    end.

to_rfc3339(Ms) when is_integer(Ms) ->
    iolist_to_binary(
        calendar:system_time_to_rfc3339(
            Ms,
            [
                {unit, millisecond},
                {offset, "Z"}
            ]
        )
    ).

format_error(B) when is_binary(B) -> B;
format_error(T) -> iolist_to_binary(io_lib:format("~p", [T])).
