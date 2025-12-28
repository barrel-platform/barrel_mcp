%%%-------------------------------------------------------------------
%%% @doc Handler registry for MCP tools, resources, and prompts.
%%%
%%% Uses a gen_statem to own the ETS table and handle registration
%%% atomically. Reads use persistent_term for fast O(1) lookups
%%% without going through the process.
%%%
%%% States:
%%%   - not_ready: Initial state, waiting for external process or signal
%%%   - ready: Registry is ready to accept registrations
%%%
%%% Configuration:
%%%   {barrel_mcp, [{wait_for_proc, ProcessName}]}
%%%   If wait_for_proc is set, registry waits for that process to be
%%%   registered before becoming ready. Otherwise, becomes ready immediately.
%%%
%%% Inspired by the hooks library pattern.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_registry).
-behaviour(gen_statem).

-include("barrel_mcp.hrl").

%% API
-export([
    start_link/0,
    wait_for_ready/0,
    wait_for_ready/1,
    reg/4,
    reg/5,
    unreg/2,
    %% Read operations (no process call, use persistent_term)
    run/3,
    find/2,
    all/0,
    all/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    not_ready/3,
    ready/3,
    terminate/3
]).

-define(SERVER, ?MODULE).
-define(DEFAULT_TIMEOUT, 5000).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the registry server.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Wait for the registry to be ready.
-spec wait_for_ready() -> ok | {error, timeout}.
wait_for_ready() ->
    wait_for_ready(?DEFAULT_TIMEOUT).

%% @doc Wait for the registry to be ready with timeout.
-spec wait_for_ready(timeout()) -> ok | {error, timeout}.
wait_for_ready(Timeout) ->
    try
        gen_statem:call(?SERVER, wait_for_ready, Timeout)
    catch
        exit:{timeout, _} ->
            {error, timeout};
        exit:{noproc, _} ->
            {error, not_started}
    end.

%% @doc Register a handler with default options.
-spec reg(handler_type(), binary(), module(), atom()) -> ok | {error, term()}.
reg(Type, Name, Module, Function) ->
    reg(Type, Name, Module, Function, #{}).

%% @doc Register a handler with options.
%% This is an atomic operation handled by the state machine.
-spec reg(handler_type(), binary(), module(), atom(), map()) ->
    ok | {error, term()}.
reg(Type, Name, Module, Function, Opts) when is_atom(Type), is_binary(Name) ->
    gen_statem:call(?SERVER, {reg, Type, Name, Module, Function, Opts}).

%% @doc Unregister a handler.
%% This is an atomic operation handled by the state machine.
-spec unreg(handler_type(), binary()) -> ok.
unreg(Type, Name) ->
    gen_statem:call(?SERVER, {unreg, Type, Name}).

%% @doc Execute a handler.
%% This is a read operation - uses persistent_term directly.
-spec run(handler_type(), binary(), map()) -> {ok, term()} | {error, term()}.
run(Type, Name, Args) ->
    case find(Type, Name) of
        {ok, #{module := M, function := F}} ->
            try
                Result = M:F(Args),
                {ok, Result}
            catch
                Class:Reason:Stack ->
                    {error, {Class, Reason, Stack}}
            end;
        error ->
            {error, {not_found, Type, Name}}
    end.

%% @doc Find a handler by type and name.
%% This is a read operation - uses persistent_term directly for O(1) lookup.
-spec find(handler_type(), binary()) -> {ok, map()} | error.
find(Type, Name) ->
    Handlers = persistent_term:get(?REGISTRY_KEY, #{}),
    case maps:find({Type, Name}, Handlers) of
        {ok, Handler} -> {ok, Handler};
        error -> error
    end.

%% @doc List all handlers grouped by type.
%% This is a read operation - uses persistent_term directly.
-spec all() -> #{handler_type() => [{binary(), map()}]}.
all() ->
    Handlers = persistent_term:get(?REGISTRY_KEY, #{}),
    lists:foldl(fun({{Type, Name}, Handler}, Acc) ->
        TypeHandlers = maps:get(Type, Acc, []),
        Acc#{Type => [{Name, Handler} | TypeHandlers]}
    end, #{}, maps:to_list(Handlers)).

%% @doc List all handlers of a specific type.
%% This is a read operation - uses persistent_term directly.
-spec all(handler_type()) -> [{binary(), map()}].
all(Type) ->
    maps:get(Type, all(), []).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

callback_mode() ->
    state_functions.

init([]) ->
    %% Create ETS table owned by this process
    ?REGISTRY_TABLE = ets:new(?REGISTRY_TABLE, [
        named_table,
        public,
        set,
        {read_concurrency, true}
    ]),
    %% Initialize persistent_term with empty map
    persistent_term:put(?REGISTRY_KEY, #{}),

    %% Check if we should wait for an external process
    case application:get_env(barrel_mcp, wait_for_proc) of
        {ok, Proc} when is_atom(Proc) ->
            %% Spawn a waiter to monitor for the process
            spawn_waiter(self(), Proc),
            {ok, not_ready, #{}};
        _ ->
            %% Send ready message to trigger transition after init completes
            self() ! ready,
            {ok, not_ready, #{}}
    end.

%% State: not_ready
%% Registry is not yet ready to accept registrations

%% Handle ready message - transition to ready state
not_ready(info, ready, Data) ->
    {next_state, ready, Data};

%% Wait for ready - postpone until we're ready
not_ready({call, _From}, wait_for_ready, _Data) ->
    {keep_state_and_data, [postpone]};

%% Registration requests - postpone until ready
not_ready({call, _From}, {reg, _Type, _Name, _Module, _Function, _Opts}, _Data) ->
    {keep_state_and_data, [postpone]};

%% Unregistration requests - postpone until ready
not_ready({call, _From}, {unreg, _Type, _Name}, _Data) ->
    {keep_state_and_data, [postpone]};

%% Other calls - postpone
not_ready({call, _From}, _, _Data) ->
    {keep_state_and_data, [postpone]}.

%% State: ready
%% Registry is ready to accept registrations

ready(info, ready, _Data) ->
    %% Already ready, ignore
    keep_state_and_data;

ready({call, From}, wait_for_ready, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

ready({call, From}, {reg, Type, Name, Module, Function, Opts}, Data) ->
    Reply = do_reg(Type, Name, Module, Function, Opts),
    {keep_state, Data, [{reply, From, Reply}]};

ready({call, From}, {unreg, Type, Name}, Data) ->
    Reply = do_unreg(Type, Name),
    {keep_state, Data, [{reply, From, Reply}]};

ready({call, From}, _, _Data) ->
    {keep_state_and_data, [{reply, From, {error, unknown_request}}]}.

terminate(_Reason, _State, _Data) ->
    %% Clean up persistent_term on shutdown
    catch persistent_term:erase(?REGISTRY_KEY),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% Spawn a process that waits for Proc to be registered, then signals ready
spawn_waiter(Parent, Proc) ->
    spawn_link(fun() -> wait_for_proc(Parent, Proc) end).

wait_for_proc(Parent, Proc) ->
    case whereis(Proc) of
        undefined ->
            timer:sleep(100),
            wait_for_proc(Parent, Proc);
        _Pid ->
            Parent ! ready
    end.

%% Atomic registration operation
do_reg(Type, Name, Module, Function, Opts) ->
    %% Validate module/function exists
    case erlang:function_exported(Module, Function, 1) of
        true ->
            Handler = build_handler(Type, Module, Function, Opts),
            true = ets:insert(?REGISTRY_TABLE, {{Type, Name}, Handler}),
            sync_persistent_term(),
            ok;
        false ->
            {error, {function_not_exported, Module, Function, 1}}
    end.

%% Atomic unregistration operation
do_unreg(Type, Name) ->
    true = ets:delete(?REGISTRY_TABLE, {Type, Name}),
    sync_persistent_term(),
    ok.

%% Build handler map based on type
build_handler(tool, Module, Function, Opts) ->
    #{
        module => Module,
        function => Function,
        description => maps:get(description, Opts, <<>>),
        input_schema => maps:get(input_schema, Opts, #{type => <<"object">>})
    };
build_handler(resource, Module, Function, Opts) ->
    #{
        module => Module,
        function => Function,
        name => maps:get(name, Opts, <<>>),
        uri => maps:get(uri, Opts, <<>>),
        description => maps:get(description, Opts, <<>>),
        mime_type => maps:get(mime_type, Opts, <<"text/plain">>)
    };
build_handler(prompt, Module, Function, Opts) ->
    #{
        module => Module,
        function => Function,
        name => maps:get(name, Opts, <<>>),
        description => maps:get(description, Opts, <<>>),
        arguments => maps:get(arguments, Opts, [])
    }.

%% Sync ETS table to persistent_term for fast lookups
sync_persistent_term() ->
    Handlers = ets:foldl(fun({Key, Handler}, Acc) ->
        Acc#{Key => Handler}
    end, #{}, ?REGISTRY_TABLE),
    persistent_term:put(?REGISTRY_KEY, Handlers).
