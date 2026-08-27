%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Handler registry for MCP tools, resources, and prompts.
%%%
%%% This module manages the registration and lookup of MCP handlers
%%% using a gen_statem for atomic write operations and persistent_term
%%% for O(1) read operations.
%%%
%%% == Architecture ==
%%%
%%% The registry uses a two-tier storage approach:
%%% <ul>
%%%   <li>ETS table: Authoritative storage, owned by the gen_statem process</li>
%%%   <li>persistent_term: Read-only copy for lock-free O(1) lookups</li>
%%% </ul>
%%%
%%% This ensures that write operations are atomic and supervised,
%%% while reads are extremely fast and don't block on process calls.
%%%
%%% == States ==
%%%
%%% The registry has two states:
%%% <ul>
%%%   <li>`not_ready' - Initial state, waiting for initialization signal</li>
%%%   <li>`ready' - Accepting registrations and lookups</li>
%%% </ul>
%%%
%%% In `not_ready' state, all calls are postponed until the registry
%%% transitions to `ready'.
%%%
%%% == Configuration ==
%%%
%%% The registry can be configured to wait for an external process
%%% before becoming ready:
%%%
%%% ```
%%% %% In sys.config
%%% {barrel_mcp, [
%%%     {wait_for_proc, my_init_process}
%%% ]}.
%%% '''
%%%
%%% If not configured, the registry becomes ready immediately after init.
%%%
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
    run/3,
    run/4,
    run_tool/3,
    param_header_names/0,
    run_completion/3,
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
%%
%% This is called by the supervisor during application startup.
%% You typically don't need to call this directly.
%%
%% @returns `{ok, Pid}' on success
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Wait for the registry to be ready.
%%
%% Blocks until the registry transitions to the `ready' state.
%% Uses the default timeout of 5 seconds.
%%
%% This is useful during application startup to ensure the registry
%% is ready before registering handlers.
%%
%% == Example ==
%%
%% ```
%% application:ensure_all_started(barrel_mcp),
%% ok = barrel_mcp_registry:wait_for_ready(),
%% %% Now safe to register handlers
%% '''
%%
%% @returns `ok' when ready, `{error, timeout}' on timeout
%% @see wait_for_ready/1
-spec wait_for_ready() -> ok | {error, timeout}.
wait_for_ready() ->
    wait_for_ready(?DEFAULT_TIMEOUT).

%% @doc Wait for the registry to be ready with a custom timeout.
%%
%% @param Timeout Maximum time to wait in milliseconds, or `infinity'
%% @returns `ok' when ready, `{error, timeout}' on timeout,
%%          `{error, not_started}' if registry process not running
-spec wait_for_ready(Timeout :: timeout()) -> ok | {error, timeout | not_started}.
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
%%
%% Equivalent to `reg(Type, Name, Module, Function, #{})'.
%%
%% @param Type Handler type: `tool', `resource', or `prompt'
%% @param Name Unique name for this handler
%% @param Module Module containing the handler function
%% @param Function Handler function name (must be exported with arity 1)
%% @returns `ok' on success, `{error, Reason}' on failure
%% @see reg/5
-spec reg(Type, Name, Module, Function) -> ok | {error, term()} when
    Type :: handler_type(),
    Name :: binary(),
    Module :: module(),
    Function :: atom().
reg(Type, Name, Module, Function) ->
    reg(Type, Name, Module, Function, #{}).

%% @doc Register a handler with options.
%%
%% Registers a handler function with the MCP server. The handler
%% will be callable via the corresponding MCP protocol methods
%% (tools/call, resources/read, prompts/get).
%%
%% This is an atomic operation that goes through the gen_statem.
%%
%% == Options by Type ==
%%%
%%% For `tool':
%%% <ul>
%%%   <li>`description' - Tool description</li>
%%%   <li>`input_schema' - JSON Schema for input validation</li>
%%% </ul>
%%%
%%% For `resource':
%%% <ul>
%%%   <li>`name' - Resource display name</li>
%%%   <li>`uri' - Resource URI</li>
%%%   <li>`description' - Resource description</li>
%%%   <li>`mime_type' - MIME type (default: text/plain)</li>
%%% </ul>
%%%
%%% For `prompt':
%%% <ul>
%%%   <li>`description' - Prompt description</li>
%%%   <li>`arguments' - List of argument definitions</li>
%%% </ul>
%%
%% @param Type Handler type
%% @param Name Unique name
%% @param Module Handler module
%% @param Function Handler function (exported with arity 1, or arity 2
%%        to receive the request `Ctx')
%% @param Opts Type-specific options
%% @returns `ok' on success, `{error, {function_not_exported, M, F, 1}}'
%%          if the function doesn't exist
-spec reg(Type, Name, Module, Function, Opts) -> ok | {error, term()} when
    Type :: handler_type(),
    Name :: binary(),
    Module :: module(),
    Function :: atom(),
    Opts :: map().
reg(Type, Name, Module, Function, Opts) when is_atom(Type), is_binary(Name) ->
    gen_statem:call(?SERVER, {reg, Type, Name, Module, Function, Opts}).

%% @doc Unregister a handler.
%%
%% Removes a previously registered handler. After unregistration,
%% the handler will no longer appear in list operations and calls
%% to it will return not_found errors.
%%
%% This is an atomic operation that goes through the gen_statem.
%%
%% @param Type Handler type
%% @param Name Handler name to unregister
%% @returns `ok' (always succeeds, even if handler didn't exist)
-spec unreg(Type :: handler_type(), Name :: binary()) -> ok.
unreg(Type, Name) ->
    gen_statem:call(?SERVER, {unreg, Type, Name}).

%% @doc Execute a handler.
%%
%% Looks up and executes a handler with the given arguments.
%% This is a read operation that uses persistent_term directly,
%% bypassing the gen_statem process for maximum performance.
%%
%% == Example ==
%%
%% ```
%% {ok, Result} = barrel_mcp_registry:run(tool, <<"search">>, #{
%%%     <<"query">> => <<"erlang">>
%% }).
%% '''
%%
%% @param Type Handler type
%% @param Name Handler name
%% @param Args Arguments to pass to the handler
%% @returns `{ok, Result}' on success, `{error, {not_found, Type, Name}}'
%%          if handler doesn't exist, `{error, {Class, Reason, Stack}}'
%%          if handler throws
-spec run(Type, Name, Args) -> {ok, term()} | {error, term()} when
    Type :: handler_type(),
    Name :: binary(),
    Args :: map().
run(Type, Name, Args) ->
    run(Type, Name, Args, #{}).

%% @doc Variant of {@link run/3} that threads a context to arity-2
%% handlers.
%%
%% `Ctx' is merged under the `tool_name' every handler already gets, so
%% a caller that has a request context (the wire path) can pass the
%% `mcp_ctx' and `mrtr' keys `barrel_mcp:input/2' and
%% `client_supports/2' read, and one that does not (a local invoke)
%% passes nothing and sees today's behaviour.
-spec run(Type, Name, Args, Ctx) -> {ok, term()} | {error, term()} when
    Type :: handler_type(),
    Name :: binary(),
    Args :: map(),
    Ctx :: map().
run(Type, Name, Args, Ctx) when is_map(Ctx) ->
    case find(Type, Name) of
        {ok, #{module := M, function := F}} ->
            try
                %% Mirror invoke_tool_handler/5: prefer the arity-2 form so
                %% a local invoke reaches the same handlers the wire does.
                Result =
                    case exported(M, F, 2) of
                        true -> M:F(Args, Ctx#{tool_name => Name});
                        false -> M:F(Args)
                    end,
                {ok, Result}
            catch
                Class:Reason:Stack ->
                    {error, {Class, Reason, Stack}}
            end;
        error ->
            {error, {not_found, Type, Name}}
    end.

%% @doc Run a completion handler synchronously. Completion handlers
%% are arity 2: `(PartialValue, Ctx)'.
-spec run_completion(Key :: binary(), Value :: binary(), Ctx :: map()) ->
    {ok, term()} | {error, term()}.
run_completion(Key, Value, Ctx) ->
    case find(completion, Key) of
        {ok, #{module := M, function := F}} ->
            try
                {ok, M:F(Value, Ctx)}
            catch
                Class:Reason:Stack ->
                    {error, {Class, Reason, Stack}}
            end;
        error ->
            {error, {not_found, completion, Key}}
    end.

%% @doc Execute a tool handler asynchronously. Spawns a worker that
%% calls `Mod:Fun(Args, Ctx)' (when arity 2 is exported) or
%% `Mod:Fun(Args)' otherwise. `Ctx' carries `tool_name' — the name the
%% tool was invoked under — so one handler can serve many registered
%% tools (as an MCP gateway does). The worker reports back to
%% `maps:get(reply_to, Ctx)' as either:
%% <ul>
%%   <li>`{tool_result, RequestId, Result}' on a normal return</li>
%%   <li>`{tool_error, RequestId, Content}' for `{tool_error, _}'</li>
%%   <li>`{tool_failed, RequestId, Reason}' on exception</li>
%%   <li>`{tool_validation_failed, RequestId, Errors}' if input
%%       validation was enabled and the args didn't match
%%       `input_schema'.</li>
%% </ul>
%%
%% Returns the worker pid.
-spec run_tool(Name :: binary(), Args :: map(), Ctx :: map()) ->
    {ok, pid()} | {error, term()}.
run_tool(Name, Args, Ctx) ->
    case find(tool, Name) of
        {ok, Handler} ->
            ReplyTo = maps:get(reply_to, Ctx),
            RequestId = maps:get(request_id, Ctx),
            Pid = spawn(fun() ->
                run_tool_worker(Name, Args, Ctx, Handler, ReplyTo, RequestId)
            end),
            {ok, Pid};
        error ->
            {error, {not_found, tool, Name}}
    end.

run_tool_worker(Name, Args, Ctx0, Handler, ReplyTo, RequestId) ->
    %% Gateways register many tools against one handler; without the name
    %% an arity-2 handler cannot tell which tool it is serving.
    Ctx = Ctx0#{tool_name => Name},
    %% Optional input validation against the registered input_schema.
    case validate_tool_input(Args, Handler) of
        ok ->
            invoke_tool_handler(Args, Ctx, Handler, ReplyTo, RequestId);
        {error, Errors} ->
            ReplyTo ! {tool_validation_failed, RequestId, Errors}
    end.

validate_tool_input(Args, Handler) ->
    case maps:get(validate_input, Handler, false) of
        true ->
            Schema = maps:get(input_schema, Handler, #{}),
            case barrel_mcp_schema:validate(Args, Schema) of
                ok -> ok;
                {error, Errors} -> {error, Errors}
            end;
        _ ->
            ok
    end.

invoke_tool_handler(
    Args,
    Ctx,
    #{module := M, function := F} = Handler,
    ReplyTo,
    RequestId
) ->
    try
        Result =
            case exported(M, F, 2) of
                true -> M:F(Args, Ctx);
                false -> M:F(Args)
            end,
        deliver_tool_result(Result, Handler, ReplyTo, RequestId)
    catch
        Class:Reason:Stack ->
            %% Log the full exception (with stack) server-side and
            %% surface only an opaque request-scoped reference to the
            %% client. The wire layer renders a generic "Internal tool
            %% error" text; operators cross-reference using the id.
            logger:error(
                "Tool handler crashed: ~p:~p ~p (request_id=~p, "
                "module=~p, function=~p)",
                [Class, Reason, Stack, RequestId, M, F]
            ),
            ReplyTo ! {tool_failed, RequestId, internal_error}
    end.

%% The handler cannot finish without more from the client. Under MRTR
%% it says so by returning rather than blocking, and the request ends
%% here; the client retries with what it gathered.
deliver_tool_result({input_required, Requests, State}, _Handler, ReplyTo, RequestId) when
    is_map(Requests)
->
    ReplyTo ! {tool_input_required, RequestId, Requests, State};
deliver_tool_result({tool_error, Content}, _Handler, ReplyTo, RequestId) ->
    ReplyTo ! {tool_error, RequestId, Content};
deliver_tool_result({tool_error, Content, Meta}, _Handler, ReplyTo, RequestId) when
    is_map(Meta)
->
    ReplyTo ! {tool_error_meta, RequestId, Content, Meta};
deliver_tool_result({structured, Data}, Handler, ReplyTo, RequestId) ->
    deliver_structured(
        Data,
        default_content_for(Data),
        #{},
        Handler,
        ReplyTo,
        RequestId
    );
deliver_tool_result({structured, Data, Content}, Handler, ReplyTo, RequestId) ->
    deliver_structured(Data, Content, #{}, Handler, ReplyTo, RequestId);
deliver_tool_result(
    {structured_meta, Data, Content, Meta},
    Handler,
    ReplyTo,
    RequestId
) when is_map(Meta) ->
    deliver_structured(Data, Content, Meta, Handler, ReplyTo, RequestId);
deliver_tool_result({result_meta, Result, Meta}, _Handler, ReplyTo, RequestId) when
    is_map(Meta)
->
    ReplyTo ! {tool_result_meta, RequestId, Result, Meta};
deliver_tool_result(Result, _Handler, ReplyTo, RequestId) ->
    ReplyTo ! {tool_result, RequestId, Result}.

deliver_structured(Data, Content, Meta, Handler, ReplyTo, RequestId) ->
    case validate_tool_output(Data, Handler) of
        ok when map_size(Meta) =:= 0 ->
            ReplyTo ! {tool_structured, RequestId, Data, Content};
        ok ->
            ReplyTo ! {tool_structured_meta, RequestId, Data, Content, Meta};
        {error, Errors} ->
            ReplyTo ! {tool_validation_failed, RequestId, {output, Errors}}
    end.

validate_tool_output(Data, Handler) ->
    case maps:get(validate_output, Handler, false) of
        true ->
            case maps:find(output_schema, Handler) of
                {ok, Schema} -> barrel_mcp_schema:validate(Data, Schema);
                error -> ok
            end;
        _ ->
            ok
    end.

%% Build a sensible default human-readable content list when the
%% caller returned `{structured, Data}' without a Content companion.
default_content_for(Data) when is_binary(Data) ->
    [#{<<"type">> => <<"text">>, <<"text">> => Data}];
default_content_for(Data) when is_map(Data); is_list(Data) ->
    [
        #{
            <<"type">> => <<"text">>,
            <<"text">> => iolist_to_binary(json:encode(Data))
        }
    ];
default_content_for(Data) ->
    [
        #{
            <<"type">> => <<"text">>,
            <<"text">> => iolist_to_binary(io_lib:format("~p", [Data]))
        }
    ].

%% @doc Find a handler by type and name.
%%
%% Looks up handler metadata without executing it.
%% This is a read operation using persistent_term for O(1) lookup.
%%
%% @param Type Handler type
%% @param Name Handler name
%% @returns `{ok, HandlerMap}' if found, `error' otherwise
-spec find(Type :: handler_type(), Name :: binary()) -> {ok, map()} | error.
find(Type, Name) ->
    Handlers = persistent_term:get(?REGISTRY_KEY, #{}),
    case maps:find({Type, Name}, Handlers) of
        {ok, Handler} -> {ok, Handler};
        error -> error
    end.

%% @doc List all handlers grouped by type.
%%
%% Returns a map with handler types as keys and lists of
%% `{Name, Metadata}' tuples as values.
%%
%% == Example ==
%%
%% ```
%% All = barrel_mcp_registry:all(),
%% %% Returns:
%% %% #{tool => [{<<"search">>, #{...}}],
%% %%   resource => [{<<"config">>, #{...}}],
%% %%   prompt => []}
%% '''
%%
%% @returns Map of type => handlers
-spec all() -> #{handler_type() => [{binary(), map()}]}.
all() ->
    Handlers = persistent_term:get(?REGISTRY_KEY, #{}),
    lists:foldl(
        fun({{Type, Name}, Handler}, Acc) ->
            TypeHandlers = maps:get(Type, Acc, []),
            Acc#{Type => [{Name, Handler} | TypeHandlers]}
        end,
        #{},
        maps:to_list(Handlers)
    ).

%% @doc List all handlers of a specific type.
%%
%% @param Type Handler type to list
%% @returns List of `{Name, Metadata}' tuples
-spec all(Type :: handler_type()) -> [{binary(), map()}].
all(Type) ->
    maps:get(Type, all(), []).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

%% @private
callback_mode() ->
    state_functions.

%% @private
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
    persistent_term:put(?PARAM_HEADERS_KEY, []),

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

%% @private
%% State: not_ready - Registry is not yet ready to accept registrations

not_ready(info, ready, Data) ->
    {next_state, ready, Data};
not_ready({call, _From}, wait_for_ready, _Data) ->
    {keep_state_and_data, [postpone]};
not_ready({call, _From}, {reg, _Type, _Name, _Module, _Function, _Opts}, _Data) ->
    {keep_state_and_data, [postpone]};
not_ready({call, _From}, {unreg, _Type, _Name}, _Data) ->
    {keep_state_and_data, [postpone]};
not_ready({call, _From}, _, _Data) ->
    {keep_state_and_data, [postpone]}.

%% @private
%% State: ready - Registry is ready to accept registrations

ready(info, ready, _Data) ->
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

%% @private
terminate(_Reason, _State, _Data) ->
    try
        persistent_term:erase(?REGISTRY_KEY),
        persistent_term:erase(?PARAM_HEADERS_KEY)
    catch
        _:_ -> ok
    end,
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

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

do_reg(Type, Name, Module, Function, Opts) ->
    %% Every handler but a completion may be arity 1 or arity 2. The
    %% arity-2 form takes a `Ctx': progress and cancel hooks for a tool,
    %% and for any of them the request context that multi round-trip
    %% requests need to ask the client for input.
    Arities =
        case Type of
            completion -> [2];
            _ -> [2, 1]
        end,
    case any_exported(Module, Function, Arities) of
        true ->
            case build_handler(Type, Module, Function, Opts) of
                {error, _} = Err ->
                    Err;
                Handler ->
                    true = ets:insert(?REGISTRY_TABLE, {{Type, Name}, Handler}),
                    sync_persistent_term(),
                    broadcast_list_changed(Type),
                    ok
            end;
        false ->
            {error, {function_not_exported, Module, Function, lists:max(Arities)}}
    end.

any_exported(Module, Function, Arities) ->
    lists:any(fun(A) -> exported(Module, Function, A) end, Arities).

%% `function_exported/3' answers for loaded modules only, and under
%% interactive code loading a handler module is loaded on first call,
%% which is this one. Without the load a valid registration is refused
%% and an arity-2 handler is invoked as arity 1.
exported(Module, Function, Arity) ->
    _ = code:ensure_loaded(Module),
    erlang:function_exported(Module, Function, Arity).

do_unreg(Type, Name) ->
    true = ets:delete(?REGISTRY_TABLE, {Type, Name}),
    sync_persistent_term(),
    broadcast_list_changed(Type),
    ok.

%% Legacy clients hear this on their session's SSE stream, modern ones
%% on a `subscriptions/listen' stream. One catalogue, two deliveries.
broadcast_list_changed(Type) ->
    barrel_mcp_session:broadcast_list_changed(Type),
    barrel_mcp_subscriptions:list_changed(Type).

build_handler(tool, Module, Function, Opts) ->
    InputSchema = maps:get(input_schema, Opts, #{type => <<"object">>}),
    %% Both schemas are checked here rather than on every call: a schema
    %% that is not one would otherwise fail at the worst moment, and a
    %% caller registering it can still do something about it.
    case check_schemas(InputSchema, Opts) of
        {error, _} = SchemaErr ->
            SchemaErr;
        ok ->
            build_tool(Module, Function, Opts, InputSchema)
    end;
build_handler(resource, Module, Function, Opts) ->
    Base = #{
        module => Module,
        function => Function,
        name => maps:get(name, Opts, <<>>),
        uri => maps:get(uri, Opts, <<>>),
        description => maps:get(description, Opts, <<>>),
        mime_type => maps:get(mime_type, Opts, <<"text/plain">>)
    },
    Merged = maps:merge(Base, opt_field(cache_ttl_ms, Opts)),
    add_metadata(maps:merge(Merged, opt_field(annotations, Opts)), Opts);
build_handler(prompt, Module, Function, Opts) ->
    Base = #{
        module => Module,
        function => Function,
        name => maps:get(name, Opts, <<>>),
        description => maps:get(description, Opts, <<>>),
        arguments => maps:get(arguments, Opts, [])
    },
    add_metadata(maps:merge(Base, opt_field(annotations, Opts)), Opts);
build_handler(resource_template, Module, Function, Opts) ->
    Base = #{
        module => Module,
        function => Function,
        name => maps:get(name, Opts, <<>>),
        uri_template => maps:get(uri_template, Opts, <<>>),
        description => maps:get(description, Opts, <<>>),
        mime_type => maps:get(mime_type, Opts, <<"text/plain">>)
    },
    Merged = maps:merge(Base, opt_field(cache_ttl_ms, Opts)),
    add_metadata(maps:merge(Merged, opt_field(annotations, Opts)), Opts);
build_handler(completion, Module, Function, _Opts) ->
    %% Completion handlers are arity 2: (PartialValue, Ctx) ->
    %%   {ok, [Suggestion]} | {ok, [Suggestion], #{has_more => true}}.
    #{module => Module, function => Function}.

build_tool(Module, Function, Opts, InputSchema) ->
    %% An invalid `x-mcp-header' annotation makes the whole tool
    %% definition invalid, so it fails registration rather than every
    %% later call. Scanning once here also keeps the per-request
    %% validation off the schema-walking path.
    case barrel_mcp_headers:scan_header_params(InputSchema) of
        {error, Reason} ->
            {error, {invalid_input_schema, Reason}};
        {ok, HeaderParams} ->
            Base = #{
                module => Module,
                function => Function,
                description => maps:get(description, Opts, <<>>),
                input_schema => InputSchema,
                header_params => HeaderParams,
                validate_input => maps:get(validate_input, Opts, false),
                long_running => maps:get(long_running, Opts, false),
                validate_output => maps:get(validate_output, Opts, false)
            },
            Merged = maps:merge(Base, opt_field(output_schema, Opts)),
            Merged1 = maps:merge(Merged, opt_field(annotations, Opts)),
            add_metadata(Merged1, Opts)
    end.

%% `inputSchema' is object rooted in every revision. `outputSchema' is
%% accepted with any root: registration happens before any revision is
%% negotiated, and what a given revision can render is decided when the
%% tool is listed.
check_schemas(InputSchema, Opts) ->
    case check_schema(input_schema, InputSchema) of
        {error, _} = Err ->
            Err;
        ok ->
            case object_rooted(InputSchema) of
                false ->
                    {error, {invalid_input_schema, not_object_rooted}};
                true ->
                    case maps:find(output_schema, Opts) of
                        error -> ok;
                        {ok, Output} -> check_schema(output_schema, Output)
                    end
            end
    end.

check_schema(Which, Schema) ->
    case barrel_mcp_jsonschema:validate_schema(normalize_schema(Schema)) of
        {error, Errors} ->
            {error, {list_to_atom("invalid_" ++ atom_to_list(Which)), Errors}};
        ok ->
            case barrel_mcp_jsonschema:compile(normalize_schema(Schema)) of
                {ok, _} ->
                    ok;
                {error, Reason} ->
                    {error, {list_to_atom("invalid_" ++ atom_to_list(Which)), Reason}}
            end
    end.

object_rooted(Schema) when is_map(Schema) ->
    case type_of(Schema) of
        undefined -> true;
        Type -> Type =:= <<"object">>
    end;
object_rooted(_Schema) ->
    false.

type_of(Schema) ->
    case maps:get(<<"type">>, Schema, maps:get(type, Schema, undefined)) of
        T when is_binary(T) -> T;
        T when is_atom(T), T =/= undefined -> atom_to_binary(T, utf8);
        _ -> undefined
    end.

%% Handlers may be registered with atom keys, which the validator does
%% not speak. Only the shape is normalised; values pass through.
normalize_schema(Map) when is_map(Map) ->
    maps:fold(
        fun(K, V, Acc) -> Acc#{to_key(K) => normalize_schema(V)} end,
        #{},
        Map
    );
normalize_schema(List) when is_list(List) ->
    [normalize_schema(V) || V <- List];
normalize_schema(Other) ->
    Other.

to_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
to_key(K) -> K.

add_metadata(Handler, Opts) ->
    Handler1 =
        case maps:get(title, Opts, undefined) of
            undefined -> Handler;
            T -> Handler#{title => T}
        end,
    case maps:get(icons, Opts, undefined) of
        undefined -> Handler1;
        I -> Handler1#{icons => I}
    end.

opt_field(Key, Opts) ->
    case maps:get(Key, Opts, undefined) of
        undefined -> #{};
        V -> #{Key => V}
    end.

%% @doc The `Mcp-Param-{Name}' headers registered tools ask clients to
%% send, lowercased. Used by the transport to build
%% `Access-Control-Allow-Headers'.
-spec param_header_names() -> [binary()].
param_header_names() ->
    persistent_term:get(?PARAM_HEADERS_KEY, []).

sync_persistent_term() ->
    Handlers = ets:foldl(
        fun({Key, Handler}, Acc) ->
            Acc#{Key => Handler}
        end,
        #{},
        ?REGISTRY_TABLE
    ),
    persistent_term:put(?REGISTRY_KEY, Handlers),
    persistent_term:put(?PARAM_HEADERS_KEY, collect_param_headers(Handlers)).

%% The union of `Mcp-Param-{Name}' headers any registered tool asks a
%% client to send. Cached alongside the registry because CORS needs it
%% on every response and `Access-Control-Allow-Headers' cannot express
%% a prefix.
collect_param_headers(Handlers) ->
    Names = maps:fold(
        fun
            ({tool, _}, Handler, Acc) ->
                [N || {N, _Path} <- maps:get(header_params, Handler, [])] ++ Acc;
            (_Key, _Handler, Acc) ->
                Acc
        end,
        [],
        Handlers
    ),
    lists:usort([<<"mcp-param-", (string:lowercase(N))/binary>> || N <- Names]).
