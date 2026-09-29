%%%-------------------------------------------------------------------
%%% @doc Tasks the application owns rather than barrel_mcp.
%%%
%%% A host that already runs durable work (an execution journaled and
%%% resumed across restarts) implements this behaviour and hands the
%%% work's id back from a tool registered with `task_provider =>
%%% Module'. barrel_mcp stores nothing about the task: `tasks/get',
%%% `tasks/update', `tasks/cancel', `tasks/result' and `tasks/list' look
%%% in the built-in store first, then ask each provider in turn, so the
%%% handle keeps resolving after a restart or on another node.
%%%
%%% barrel_mcp still negotiates the extension, renders the task for the
%%% caller's era, checks the inline window and delivers status
%%% notifications (see `barrel_mcp_tasks:changed/3').
%%%
%%% `Owner' is what `barrel_mcp:task_owner/1' returns for the request.
%%% Store `barrel_mcp_tasks:principal(Owner)' with the task and compare
%%% it on every call: a task held by another principal must answer
%%% `{error, not_found}', exactly like an unknown id.
%%%
%%% Providers are asked in this order: the `task_providers' app env
%%% (edited by `barrel_mcp:register_task_provider/1'), then the modules
%%% named by registered tools. The first answer other than `not_found'
%%% wins. A callback that raises or returns a malformed task is logged
%%% and counts as `not_found'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_task_provider).

-export([
    providers/0,
    register/1,
    unregister/1,
    find/2,
    get/3,
    cancel/2,
    update/3,
    list/1,
    await/4,
    call_outcome/5,
    render/3,
    terminal/1
]).

-export_type([task/0, status/0]).

-type status() :: working | input_required | completed | failed | cancelled.

%% `result' is a CallToolResult, `isError' included. `error' is for a
%% protocol failure only. `input_requests' is published while the task
%% is `input_required', keyed like `inputResponses'. Times are in ms.
-type task() :: #{
    id := binary(),
    status := status(),
    created_at := integer(),
    updated_at := integer(),
    result => map(),
    error => term(),
    input_requests => map(),
    ttl_ms => pos_integer() | undefined,
    poll_interval_ms => pos_integer(),
    method => binary()
}.

-callback get(Owner :: term(), TaskId :: binary()) ->
    {ok, task()} | {error, not_found}.
-callback cancel(Owner :: term(), TaskId :: binary()) ->
    ok | {error, not_found}.
-callback update(Owner :: term(), TaskId :: binary(), Responses :: map()) ->
    ok | {error, not_found}.
-callback list(Owner :: term()) -> [task()].
-callback await(Owner :: term(), TaskId :: binary(), timeout()) ->
    {ok, task()} | {error, not_found | timeout}.

-optional_callbacks([list/1, await/3]).

-define(DEFAULT_POLL_MS, 1000).

%%====================================================================
%% Registration
%%====================================================================

%% @doc Every provider, in the order they are asked.
-spec providers() -> [module()].
providers() ->
    Env = application:get_env(barrel_mcp, task_providers, []),
    dedup(Env ++ barrel_mcp_registry:task_providers(), []).

%% @doc Add a provider to the `task_providers' app env, which outlives a
%% restart of the application.
-spec register(module()) -> ok.
register(Module) when is_atom(Module) ->
    Env = application:get_env(barrel_mcp, task_providers, []),
    case lists:member(Module, Env) of
        true -> ok;
        false -> application:set_env(barrel_mcp, task_providers, Env ++ [Module])
    end.

-spec unregister(module()) -> ok.
unregister(Module) ->
    Env = application:get_env(barrel_mcp, task_providers, []),
    application:set_env(barrel_mcp, task_providers, lists:delete(Module, Env)).

%%====================================================================
%% Routing
%%====================================================================

%% @doc The first provider holding `TaskId' for `Owner'.
-spec find(term(), binary()) -> {ok, module(), task()} | {error, not_found}.
find(Owner, TaskId) ->
    find(providers(), Owner, TaskId).

find([], _Owner, _TaskId) ->
    {error, not_found};
find([Mod | Rest], Owner, TaskId) ->
    case get(Mod, Owner, TaskId) of
        {ok, T} -> {ok, Mod, T};
        {error, not_found} -> find(Rest, Owner, TaskId)
    end.

%% @doc Read one task from one provider.
-spec get(module(), term(), binary()) -> {ok, task()} | {error, not_found}.
get(Mod, Owner, TaskId) ->
    case safe(Mod, get, [Owner, TaskId]) of
        {ok, T} -> checked(Mod, T);
        _ -> {error, not_found}
    end.

-spec cancel(term(), binary()) -> ok | {error, not_found}.
cancel(Owner, TaskId) ->
    act(Owner, TaskId, cancel, [Owner, TaskId]).

-spec update(term(), binary(), map()) -> ok | {error, not_found}.
update(Owner, TaskId, Responses) ->
    act(Owner, TaskId, update, [Owner, TaskId, Responses]).

act(Owner, TaskId, Fun, Args) ->
    case find(Owner, TaskId) of
        {ok, Mod, _} ->
            case safe(Mod, Fun, Args) of
                ok -> ok;
                _ -> {error, not_found}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

%% @doc Every task an owner holds across the providers that export
%% `list/1'. Only the legacy `tasks/list' asks.
-spec list(term()) -> [{module(), task()}].
list(Owner) ->
    lists:flatmap(
        fun(Mod) ->
            case exported(Mod, list, 1) of
                true ->
                    case safe(Mod, list, [Owner]) of
                        L when is_list(L) ->
                            [{Mod, T} || Raw <- L, {ok, T} <- [checked(Mod, Raw)]];
                        _ ->
                            []
                    end;
                false ->
                    []
            end
        end,
        providers()
    ).

%% @doc Wait until a hosted task is terminal.
%%
%% Uses the provider's own `await/3' when it has one. Otherwise polls
%% `get/2' at the task's poll interval, and looks again at once when
%% `barrel_mcp_tasks:changed/3' reports a change on this node.
-spec await(module(), term(), binary(), timeout()) ->
    {ok, task()} | {error, not_found | timeout}.
await(Mod, Owner, TaskId, Timeout) ->
    case exported(Mod, await, 3) of
        true ->
            case safe(Mod, await, [Owner, TaskId, Timeout]) of
                {ok, T} ->
                    checked(Mod, T);
                {error, timeout} ->
                    {error, timeout};
                _ ->
                    {error, not_found}
            end;
        false ->
            poll(Mod, Owner, TaskId, deadline(Timeout))
    end.

poll(Mod, Owner, TaskId, Deadline) ->
    %% Watched before reading, so a change between the read and the wait
    %% still wakes us.
    Ref = barrel_mcp_tasks:watch(TaskId),
    Result =
        case get(Mod, Owner, TaskId) of
            {ok, T} ->
                case {terminal(T), remaining(Deadline)} of
                    {true, _} ->
                        {ok, T};
                    {false, 0} ->
                        {error, timeout};
                    {false, Left} ->
                        Wait = min(maps:get(poll_interval_ms, T, ?DEFAULT_POLL_MS), Left),
                        receive
                            {task_nudge, TaskId, Ref} -> again
                        after Wait -> again
                        end
                end;
            {error, not_found} ->
                {error, not_found}
        end,
    barrel_mcp_tasks:unwatch(TaskId, Ref),
    receive
        {task_nudge, TaskId, Ref} -> ok
    after 0 -> ok
    end,
    case Result of
        again -> poll(Mod, Owner, TaskId, Deadline);
        Done -> Done
    end.

deadline(infinity) -> infinity;
deadline(Ms) -> erlang:monotonic_time(millisecond) + Ms.

remaining(infinity) -> infinity;
remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).

%% @doc How a `tools/call' whose handler named a hosted task is
%% answered.
%%
%% A modern client gets the result in place when the task ends before
%% the inline window does (`WindowEnd', monotonic ms), and the task
%% otherwise. A legacy client gets the task at once, as it would a
%% built-in one. A task the caller cannot see is a tool failure: the
%% handler named an id the provider does not hold for this owner.
-spec call_outcome(module(), term(), binary(), barrel_mcp_ctx:ctx(), integer()) ->
    {task, map()}
    | {call_result, map()}
    | {rpc_error, integer(), binary()}
    | {failed, term()}.
call_outcome(Mod, Owner, TaskId, Ctx, WindowEnd) ->
    Era = barrel_mcp_ctx:era(Ctx),
    Read =
        case Era of
            modern ->
                Left = max(0, WindowEnd - erlang:monotonic_time(millisecond)),
                case await(Mod, Owner, TaskId, Left) of
                    {error, timeout} -> get(Mod, Owner, TaskId);
                    Other -> Other
                end;
            _ ->
                get(Mod, Owner, TaskId)
        end,
    case Read of
        {error, not_found} ->
            logger:warning("Task provider ~p does not hold task ~p", [Mod, TaskId]),
            {failed, {unknown_task, TaskId}};
        {ok, T} ->
            case Era =:= modern andalso terminal(T) of
                true ->
                    in_place(T);
                false ->
                    {task,
                        barrel_mcp_protocol:create_task_result(TaskId, render(T, Owner, Era), Ctx)}
            end
    end.

%% The same answers `tasks/result' gives for a terminal task.
in_place(#{status := completed} = T) ->
    {call_result, maps:get(result, T, #{<<"content">> => []})};
in_place(#{status := failed} = T) ->
    #{<<"code">> := Code, <<"message">> := Message} =
        format_error(maps:get(error, T, <<"Task failed">>)),
    {rpc_error, Code, Message};
in_place(#{status := cancelled}) ->
    {rpc_error, -32602, <<"Task cancelled">>}.

-spec terminal(task()) -> boolean().
terminal(#{status := S}) ->
    S =:= completed orelse S =:= failed orelse S =:= cancelled.

%%====================================================================
%% Rendering
%%====================================================================

%% @doc A task as the caller's era names it. Shared with the built-in
%% store, so both render the same.
%%
%% The retention field is `ttl' through 2025-11-25 and `ttlMs' in the
%% extension, and both report what was granted, not what was asked
%% for. The poll hint is `pollInterval' and `pollIntervalMs'.
-spec render(task(), term(), legacy | modern) -> map().
render(#{id := Id, status := St, created_at := C, updated_at := U} = T, Owner, Era) ->
    {TtlKey, PollKey} =
        case Era of
            modern -> {<<"ttlMs">>, <<"pollIntervalMs">>};
            _ -> {<<"ttl">>, <<"pollInterval">>}
        end,
    Base = #{
        <<"taskId">> => Id,
        <<"status">> => atom_to_binary(St, utf8),
        <<"createdAt">> => to_rfc3339(C),
        <<"lastUpdatedAt">> => to_rfc3339(U),
        TtlKey => ttl_or_null(maps:get(ttl_ms, T, undefined))
    },
    Optional = [
        {<<"method">>, maps:get(method, T, undefined)},
        {PollKey, maps:get(poll_interval_ms, T, undefined)},
        {<<"inputRequests">>,
            case St of
                input_required -> maps:get(input_requests, T, undefined);
                _ -> undefined
            end},
        {<<"sessionId">>,
            case Owner of
                Sid when is_binary(Sid) -> Sid;
                _ -> undefined
            end},
        {<<"result">>,
            case St of
                completed -> maps:get(result, T, undefined);
                _ -> undefined
            end},
        {<<"error">>,
            case {St, maps:get(error, T, undefined)} of
                {failed, E} when E =/= undefined -> format_error(E);
                _ -> undefined
            end}
    ],
    lists:foldl(
        fun
            ({_K, undefined}, Acc) -> Acc;
            ({K, V}, Acc) -> Acc#{K => V}
        end,
        Base,
        Optional
    ).

ttl_or_null(undefined) -> null;
ttl_or_null(Ttl) -> Ttl.

to_rfc3339(Ms) when is_integer(Ms) ->
    iolist_to_binary(
        calendar:system_time_to_rfc3339(Ms, [{unit, millisecond}, {offset, "Z"}])
    ).

%% tasks.md "Task Execution Errors": the `error' field is the JSON-RPC
%% error, so a bare reason is wrapped as an internal error.
format_error(#{<<"code">> := _, <<"message">> := _} = E) ->
    E;
format_error(B) when is_binary(B) -> #{<<"code">> => -32603, <<"message">> => B};
format_error(T) ->
    #{<<"code">> => -32603, <<"message">> => iolist_to_binary(io_lib:format("~p", [T]))}.

%%====================================================================
%% Internal
%%====================================================================

%% A task we cannot render is one we cannot answer with, and saying so
%% to the client would tell it the id exists.
checked(Mod, #{id := Id, status := St, created_at := C, updated_at := U} = T) when
    is_binary(Id), is_integer(C), is_integer(U)
->
    case lists:member(St, [working, input_required, completed, failed, cancelled]) of
        true -> {ok, T};
        false -> malformed(Mod, T)
    end;
checked(Mod, Other) ->
    malformed(Mod, Other).

malformed(Mod, Other) ->
    logger:warning("Task provider ~p returned a malformed task: ~p", [Mod, Other]),
    {error, not_found}.

safe(Mod, Fun, Args) ->
    try
        apply(Mod, Fun, Args)
    catch
        Class:Reason:Stack ->
            logger:error(
                "Task provider ~p:~p crashed: ~p:~p ~p",
                [Mod, Fun, Class, Reason, Stack]
            ),
            {error, not_found}
    end.

exported(Mod, Fun, Arity) ->
    _ = code:ensure_loaded(Mod),
    erlang:function_exported(Mod, Fun, Arity).

dedup([], Acc) ->
    lists:reverse(Acc);
dedup([M | Rest], Acc) ->
    case lists:member(M, Acc) of
        true -> dedup(Rest, Acc);
        false -> dedup(Rest, [M | Acc])
    end.
