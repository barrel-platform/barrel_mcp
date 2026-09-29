%%%-------------------------------------------------------------------
%%% @doc Where barrel_mcp keeps the tasks it owns.
%%%
%%% A backend stores task records by id. The default,
%%% {@link barrel_mcp_task_store_ets}, is a node-local ETS table; a
%%% deployment that needs tasks to outlive the node configures another:
%%%
%%% ```
%%% {barrel_mcp, [
%%%     {task_store, my_task_store},
%%%     {task_store_opts, #{}}
%%% ]}
%%% '''
%%%
%%% The setting is read once, when `barrel_mcp_tasks' starts.
%%%
%%% Every write comes from the `barrel_mcp_tasks' process, so a backend
%%% sees one writer per node. Reads come from request processes, so a
%%% backend must allow concurrent reads. A stored value is an opaque
%%% term: keep it whole (`term_to_binary/1' for anything off-heap) and
%%% never interpret it. `count_owned/1' is the one exception, which may
%%% read the owner through {@link owner/1}.
%%%
%%% Tasks hosted by the application itself, rather than by barrel_mcp,
%%% use {@link barrel_mcp_task_provider} instead.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_task_store).

-export([
    start/0,
    stop/0,
    backend/0,
    get/1,
    put/2,
    delete/1,
    fold/2,
    count/0,
    count_owned/1,
    owner/1
]).

-export_type([stored/0]).

%% A versioned map built by `barrel_mcp_tasks'. Treat it as opaque.
-type stored() :: #{v := pos_integer(), atom() => term()}.

-callback init(Opts :: map()) -> ok | {error, term()}.
-callback get(TaskId :: binary()) -> {ok, stored()} | not_found.
-callback put(TaskId :: binary(), stored()) -> ok.
-callback delete(TaskId :: binary()) -> ok.
-callback fold(fun((binary(), stored(), Acc) -> Acc), Acc) -> Acc.
-callback count() -> non_neg_integer().
-callback count_owned(Owner :: term()) -> non_neg_integer().
-callback terminate() -> ok.

-optional_callbacks([count/0, count_owned/1, terminate/0]).

-define(KEY, {?MODULE, backend}).

%% @doc Initialise the configured backend and remember it. Called from
%% `barrel_mcp_tasks:init/1', so whatever the backend creates is owned
%% by that process.
-spec start() -> ok | {error, term()}.
start() ->
    Mod = application:get_env(barrel_mcp, task_store, barrel_mcp_task_store_ets),
    Opts = application:get_env(barrel_mcp, task_store_opts, #{}),
    case Mod:init(Opts) of
        ok ->
            %% Written only when the backend changes: a persistent_term
            %% update is a global GC.
            _ =
                persistent_term:get(?KEY, undefined) =:= Mod orelse
                    persistent_term:put(?KEY, Mod),
            ok;
        {error, _} = Err ->
            Err
    end.

-spec stop() -> ok.
stop() ->
    Mod = backend(),
    case exported(Mod, terminate, 0) of
        true -> Mod:terminate();
        false -> ok
    end.

-spec backend() -> module().
backend() ->
    persistent_term:get(?KEY, barrel_mcp_task_store_ets).

-spec get(binary()) -> {ok, stored()} | not_found.
get(TaskId) ->
    (backend()):get(TaskId).

-spec put(binary(), stored()) -> ok.
put(TaskId, Stored) ->
    (backend()):put(TaskId, Stored).

-spec delete(binary()) -> ok.
delete(TaskId) ->
    (backend()):delete(TaskId).

-spec fold(fun((binary(), stored(), Acc) -> Acc), Acc) -> Acc.
fold(Fun, Acc) ->
    (backend()):fold(Fun, Acc).

-spec count() -> non_neg_integer().
count() ->
    Mod = backend(),
    case exported(Mod, count, 0) of
        true -> Mod:count();
        false -> Mod:fold(fun(_, _, N) -> N + 1 end, 0)
    end.

-spec count_owned(term()) -> non_neg_integer().
count_owned(Owner) ->
    Mod = backend(),
    case exported(Mod, count_owned, 1) of
        true ->
            Mod:count_owned(Owner);
        false ->
            Mod:fold(
                fun(_, S, N) ->
                    case owner(S) =:= Owner of
                        true -> N + 1;
                        false -> N
                    end
                end,
                0
            )
    end.

%% @doc The owner a stored task belongs to, for a backend that indexes
%% it.
-spec owner(stored()) -> term().
owner(#{owner := Owner}) -> Owner.

exported(Mod, Fun, Arity) ->
    _ = code:ensure_loaded(Mod),
    erlang:function_exported(Mod, Fun, Arity).
