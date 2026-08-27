%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc stdio transport for MCP protocol.
%%%
%%% Newline-delimited JSON-RPC 2.0 over stdin/stdout, the transport
%%% Claude Desktop and most local MCP hosts use.
%%%
%%% == Processes ==
%%%
%%% One channel carries everything, so the work is split rather than
%%% serialised:
%%%
%%% <ul>
%%%   <li>a reader that only frames bytes, so a slow tool never stops
%%%       cancellations or new requests from arriving;</li>
%%%   <li>a coordinator that decodes, classifies and dispatches, and
%%%       never runs handler code itself;</li>
%%%   <li>bounded workers, one per executable request;</li>
%%%   <li>a single writer owning stdout, so two answers cannot
%%%       interleave mid-line.</li>
%%% </ul>
%%%
%%% == Usage ==
%%%
%%% {@link start/0} runs it in the calling process and returns when
%%% stdin closes. {@link start_link/0} starts it as a supervisable
%%% gen_server registered as `barrel_mcp_stdio'.
%%%
%%% ```
%%% main(_Args) ->
%%%     application:ensure_all_started(barrel_mcp),
%%%     barrel_mcp_registry:wait_for_ready(),
%%%     barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo, #{}),
%%%     barrel_mcp_stdio:start().
%%% '''
%%%
%%% == Claude Desktop ==
%%%
%%% ```
%%% {"mcpServers": {"my-server": {"command": "/path/to/escript"}}}
%%% '''
%%%
%%% at `~/Library/Application Support/Claude/claude_desktop_config.json'
%%% (macOS), `%APPDATA%\Claude\claude_desktop_config.json' (Windows) or
%%% `~/.config/claude/claude_desktop_config.json' (Linux).
%%%
%%% @see barrel_mcp
%%% @see barrel_mcp_protocol
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_stdio).

-export([
    start/0,
    start_link/0
]).

-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Spawned entry points.
-export([reader_init/1, writer_init/0, subscription_init/2]).

-include("barrel_mcp.hrl").

%% Largest single stdio frame accepted from a peer.
-define(DEFAULT_MAX_FRAME_BYTES, 16 * 1024 * 1024).

%% Requests executing at once, and how many may wait behind them.
-define(DEFAULT_MAX_WORKERS, 8).
-define(DEFAULT_MAX_QUEUE, 64).
%% Notifications waiting to be handled. They produce no response, so an
%% overflow is dropped rather than refused.
-define(DEFAULT_MAX_NOTIFICATIONS, 256).
%% Notifications written but not yet on stdout. The writer blocks when
%% the peer stops draining its pipe, and its mailbox is not a bound.
-define(DEFAULT_MAX_OUTBOUND, 256).
%% Response streams one peer may hold open. A subscription holds no
%% worker slot, so nothing else counts them.
-define(DEFAULT_MAX_SUBSCRIPTIONS, 32).

-define(WORKER_TIMEOUT, 60000).
-define(DROP_LOG_INTERVAL_MS, 5000).

-record(entry, {
    state :: queued | running | subscription,
    pid :: pid() | undefined,
    mref :: reference() | undefined,
    tag :: reference() | undefined
}).

-record(state, {
    reader :: pid() | undefined,
    writer :: pid() | undefined,
    version :: binary() | undefined,
    session :: binary() | undefined,
    requests = #{} :: #{term() => #entry{}},
    %% Monitor and result-tag indexes into `requests'.
    by_mref = #{} :: #{reference() => term()},
    by_tag = #{} :: #{reference() => term()},
    pending = queue:new() :: queue:queue(),
    queued = 0 :: non_neg_integer(),
    running = 0 :: non_neg_integer(),
    notifications = queue:new() :: queue:queue(),
    notifying = 0 :: non_neg_integer(),
    notif_len = 0 :: non_neg_integer(),
    %% Notifications handed to the writer and not yet on stdout.
    outbound = 0 :: non_neg_integer(),
    dropped = 0 :: non_neg_integer(),
    last_drop_log = 0 :: integer()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Run the server in the calling process. Returns when stdin
%% closes.
-spec start() -> ok.
start() ->
    {ok, Pid} = gen_server:start(?MODULE, [], []),
    MRef = monitor(process, Pid),
    receive
        {'DOWN', MRef, process, Pid, _Reason} -> ok
    end.

%% @doc Start as a supervisable gen_server registered as
%% `barrel_mcp_stdio'.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% Coordinator
%%====================================================================

%% The one channel is one session, so `resources/subscribe' and the rest
%% of the legacy server-to-client surface have somewhere to live. The
%% channel is only attached once a handshake revision is negotiated; see
%% bind_session/2.
init([]) ->
    process_flag(trap_exit, true),
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    Self = self(),
    Writer = spawn_link(?MODULE, writer_init, []),
    Reader = spawn_link(?MODULE, reader_init, [Self]),
    {ok, SessionId} = barrel_mcp_session:create(#{}),
    {ok, #state{reader = Reader, writer = Writer, session = SessionId}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({stdio_frame, Frame}, State) ->
    State1 = dispatch_frame(Frame, State),
    ack_reader(State1),
    {noreply, State1};
handle_info(stdio_frame_too_large, State) ->
    %% A frame past the cap cannot be answered in place: the newline
    %% that would end it may never arrive.
    write(
        State,
        barrel_mcp_protocol:error_response(
            null, ?JSONRPC_INVALID_REQUEST, <<"Request exceeds the maximum frame size">>
        )
    ),
    {stop, normal, State};
handle_info(stdio_eof, State) ->
    {stop, normal, State};
handle_info({stdio_error, _Reason}, State) ->
    {stop, normal, State};
handle_info({stdio_result, Tag, Response}, State) ->
    {noreply, settle(Tag, Response, State)};
%% With an id this is a `sampling/createMessage', `elicitation/create'
%% or `roots/list' we are waiting on, bounded already by the worker
%% count; dropping one would strand the tool that sent it. Without an id
%% it is a notification and takes the bounded path.
handle_info({sse_send_message, Message}, State) when is_map(Message) ->
    case maps:is_key(<<"id">>, Message) of
        true ->
            write(State, Message),
            {noreply, State};
        false ->
            {noreply, notify(Message, State)}
    end;
handle_info({stdio_notify, Envelope}, State) ->
    {noreply, notify(Envelope, State)};
handle_info(stdio_written, #state{outbound = N} = State) ->
    {noreply, State#state{outbound = max(0, N - 1)}};
handle_info(stdio_notified, State) ->
    {noreply, drain_notifications(State#state{notifying = 0})};
handle_info({'DOWN', MRef, process, _Pid, Reason}, State) ->
    {noreply, worker_down(MRef, Reason, State)};
handle_info({'EXIT', Pid, _Reason}, #state{reader = Pid} = State) ->
    {stop, normal, State};
handle_info({'EXIT', Pid, _Reason}, #state{writer = Pid} = State) ->
    {stop, normal, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = delete_session(State#state.session),
    maps:foreach(fun(_Id, Entry) -> stop_entry(Entry) end, State#state.requests),
    stop_child(State#state.reader),
    flush_writer(State#state.writer),
    stop_child(State#state.writer),
    ok.

delete_session(SessionId) when is_binary(SessionId) ->
    try
        barrel_mcp_session:delete(SessionId)
    catch
        _:_ -> ok
    end,
    ok;
delete_session(_) ->
    ok.

%% The last answer is often written on the way out, and the writer's
%% mailbox is not the socket: killing it here would drop what it has not
%% put on stdout yet.
flush_writer(Writer) when is_pid(Writer) ->
    Ref = make_ref(),
    Writer ! {stdio_flush, self(), Ref},
    receive
        {stdio_flushed, Ref} -> ok
    after 5000 -> ok
    end;
flush_writer(_Writer) ->
    ok.

stop_entry(#entry{pid = Pid, mref = MRef}) ->
    _ =
        case MRef of
            undefined -> ok;
            _ -> demonitor(MRef, [flush])
        end,
    stop_child(Pid).

stop_child(undefined) ->
    ok;
stop_child(Pid) when is_pid(Pid) ->
    exit(Pid, shutdown),
    ok.

ack_reader(#state{reader = Reader}) when is_pid(Reader) ->
    Reader ! stdio_ack,
    ok;
ack_reader(_State) ->
    ok.

%%====================================================================
%% Classification
%%====================================================================

dispatch_frame(Frame, State) ->
    case string:trim(Frame) of
        <<>> -> State;
        Line -> classify(Line, State)
    end.

classify(Line, State) ->
    case barrel_mcp_protocol:decode(Line) of
        {ok, Message} when is_map(Message) ->
            route(Message, State);
        {ok, _Batch} ->
            %% A batch is not constant-time to classify, so it goes to a
            %% worker like any other executable request.
            enqueue_batch(Line, State);
        {error, too_deep} ->
            write(
                State,
                barrel_mcp_protocol:error_response(
                    null, ?JSONRPC_INVALID_REQUEST, <<"Request nesting is too deep">>
                )
            ),
            State;
        {error, _} ->
            write(
                State,
                barrel_mcp_protocol:error_response(
                    null, ?JSONRPC_PARSE_ERROR, <<"Parse error">>
                )
            ),
            State
    end.

%% Order matters: a response can never be answered, and a cancellation
%% must not queue behind the request it cancels.
route(Message, State) ->
    case classify_message(Message) of
        {response, Id} -> deliver_response(Id, Message, State);
        {cancel, Id} -> cancel(Id, State);
        {notification, _Method} -> enqueue_notification(Message, State);
        {request, Id} -> enqueue_request(Id, Message, State);
        malformed -> reject_malformed(Message, State)
    end.

classify_message(Message) ->
    HasId = maps:is_key(<<"id">>, Message),
    IsResponse =
        maps:is_key(<<"result">>, Message) orelse maps:is_key(<<"error">>, Message),
    case {HasId, IsResponse, maps:get(<<"method">>, Message, undefined)} of
        {true, true, _} -> {response, maps:get(<<"id">>, Message)};
        {_, _, <<"notifications/cancelled">>} -> {cancel, cancelled_id(Message)};
        {false, _, M} when is_binary(M) -> {notification, M};
        {true, _, M} when is_binary(M) -> {request, maps:get(<<"id">>, Message)};
        _ -> malformed
    end.

cancelled_id(Message) ->
    case maps:get(<<"params">>, Message, #{}) of
        P when is_map(P) -> maps:get(<<"requestId">>, P, undefined);
        _ -> undefined
    end.

reject_malformed(Message, State) ->
    case maps:is_key(<<"id">>, Message) of
        true ->
            write(
                State,
                barrel_mcp_protocol:error_response(
                    maps:get(<<"id">>, Message),
                    ?JSONRPC_INVALID_REQUEST,
                    <<"Invalid Request">>
                )
            );
        false ->
            %% JSON-RPC forbids answering a notification.
            ok
    end,
    State.

%% The answer to a `sampling/createMessage', `elicitation/create' or
%% `roots/list' we sent. An id nobody is waiting on is dropped rather
%% than answered: JSON-RPC forbids replying to a response.
deliver_response(Id, Message, State) ->
    case barrel_mcp_session:deliver_response(Id, Message) of
        ok -> State;
        {error, _} -> note_drop(State)
    end.

%%====================================================================
%% Requests
%%====================================================================

enqueue_request(Id, Message, State) ->
    case maps:is_key(Id, State#state.requests) of
        true ->
            write(
                State,
                barrel_mcp_protocol:error_response(
                    Id, ?JSONRPC_INVALID_REQUEST, <<"Duplicate request id">>
                )
            ),
            State;
        false ->
            admit_request(Id, Message, State)
    end.

admit_request(Id, Message, State) ->
    case {State#state.running < max_workers(), State#state.queued >= max_queue()} of
        {true, _} ->
            start_worker(Id, Message, State);
        {false, true} ->
            write(
                State,
                barrel_mcp_protocol:error_response(
                    Id, ?JSONRPC_INTERNAL_ERROR, <<"Server is overloaded">>
                )
            ),
            State;
        {false, false} ->
            Entry = #entry{state = queued},
            State#state{
                requests = (State#state.requests)#{Id => Entry},
                pending = queue:in({Id, Message}, State#state.pending),
                queued = State#state.queued + 1
            }
    end.

%% A batch has no single id to register, so it runs as an anonymous
%% worker: it can neither be cancelled nor duplicate-checked by id.
enqueue_batch(Line, State) ->
    case State#state.running < max_workers() of
        false ->
            note_drop(State);
        true ->
            Self = self(),
            Tag = make_ref(),
            Ctx = protocol_state(State),
            {Pid, MRef} = spawn_monitor(fun() -> run_batch(Self, Tag, Line, Ctx) end),
            Id = {batch, Tag},
            Entry = #entry{state = running, pid = Pid, mref = MRef, tag = Tag},
            State#state{
                requests = (State#state.requests)#{Id => Entry},
                by_mref = (State#state.by_mref)#{MRef => Id},
                by_tag = (State#state.by_tag)#{Tag => Id},
                running = State#state.running + 1
            }
    end.

start_worker(Id, Message, State) ->
    Self = self(),
    Tag = make_ref(),
    Ctx = protocol_state(State),
    {Pid, MRef} = spawn_monitor(fun() -> run_request(Self, Tag, Id, Message, Ctx) end),
    Entry = #entry{state = running, pid = Pid, mref = MRef, tag = Tag},
    State#state{
        requests = (State#state.requests)#{Id => Entry},
        by_mref = (State#state.by_mref)#{MRef => Id},
        by_tag = (State#state.by_tag)#{Tag => Id},
        running = State#state.running + 1
    }.

run_request(Coordinator, Tag, Id, Message, Ctx) ->
    Result =
        try
            barrel_mcp_protocol:handle(Message, Ctx)
        catch
            Class:Reason:Stack ->
                logger:error(
                    "barrel_mcp stdio: request crashed: ~p:~p~n~p",
                    [Class, Reason, Stack]
                ),
                barrel_mcp_protocol:error_response(
                    Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
                )
        end,
    Coordinator ! {stdio_result, Tag, settle_result(Result, Id)},
    ok.

run_batch(Coordinator, Tag, Line, Ctx) ->
    Result =
        try
            {ok, Batch} = barrel_mcp_protocol:decode(Line),
            barrel_mcp_protocol:handle(Batch, Ctx)
        catch
            _:_ ->
                barrel_mcp_protocol:error_response(
                    null, ?JSONRPC_INVALID_REQUEST, <<"Invalid Request">>
                )
        end,
    Coordinator ! {stdio_result, Tag, settle_result(Result, null)},
    ok.

%% stdio holds one long-lived channel, so a response stream is
%% something it can serve: `subscriptions/listen' is answered here
%% rather than refused as it is on a transport that answers once.
protocol_state(#state{version = Version, session = SessionId}) ->
    #{protocol_version => Version, session_id => SessionId, streaming => true}.

settle_result(no_response, _Id) ->
    no_response;
settle_result({async, Plan}, _Id) ->
    barrel_mcp_protocol:drive_async_plan(Plan, ?WORKER_TIMEOUT);
settle_result({subscribe, Sub}, _Id) ->
    {subscribe, Sub};
settle_result(Response, _Id) ->
    Response.

%% The worker answered. A subscription is not finished by its first
%% reply, so it keeps its slot; everything else releases one.
settle(Tag, Response, State) ->
    case maps:take(Tag, State#state.by_tag) of
        error ->
            State;
        {Id, ByTag} ->
            State1 = State#state{by_tag = ByTag},
            case Response of
                {subscribe, Sub} -> admit_subscription(Id, Sub, State1);
                no_response -> State1;
                _ -> answer(Id, Response, State1)
            end
    end.

answer(Id, Response, State) ->
    write(State, Response),
    Version = negotiated(Response, State#state.version),
    _ = bind_session(Version, State),
    State#state{version = Version, requests = keep(Id, State)}.

%% Server-to-client traffic through the session is the legacy surface:
%% `resources/subscribe', the log stream, list_changed. A modern
%% connection gets the same things through `subscriptions/listen', so
%% attaching there too would deliver each notification twice.
bind_session(Version, #state{version = Version}) ->
    ok;
bind_session(Version, #state{session = SessionId}) when is_binary(Version), is_binary(SessionId) ->
    case barrel_mcp_version:era(Version) of
        legacy -> barrel_mcp_session:set_sse_pid(SessionId, self());
        _ -> ok
    end;
bind_session(_Version, _State) ->
    ok.

keep(Id, State) ->
    maps:remove(Id, State#state.requests).

%%====================================================================
%% Subscriptions
%%====================================================================

%% A subscription holds no worker slot, so `max_workers' does not bound
%% these. Refused with the same answer an overloaded server gives a
%% request it cannot start.
admit_subscription(Id, Sub, State) ->
    case live_subscriptions(State) >= max_subscriptions() of
        true ->
            answer(
                Id,
                barrel_mcp_protocol:error_response(
                    Id, ?JSONRPC_INTERNAL_ERROR, <<"Server is overloaded">>
                ),
                State
            );
        false ->
            open_subscription(Id, Sub, State)
    end.

%% Counted from `requests' rather than kept in a field: both removal
%% paths already maintain that map, and a second counter would only add
%% a way for the two to disagree.
live_subscriptions(#state{requests = Requests}) ->
    maps:fold(
        fun
            (_Id, #entry{state = subscription}, N) -> N + 1;
            (_Id, _Entry, N) -> N
        end,
        0,
        Requests
    ).

%% Done in one step rather than handed back through the mailbox: the
%% worker's `DOWN' is already queued behind its result, and a two-step
%% swap would let it remove the entry the subscription is about to take.
open_subscription(Id, Sub, State) ->
    OldMRef =
        case maps:find(Id, State#state.requests) of
            {ok, #entry{mref = Ref}} when is_reference(Ref) ->
                demonitor(Ref, [flush]),
                Ref;
            _ ->
                undefined
        end,
    {Pid, MRef} = spawn_monitor(?MODULE, subscription_init, [self(), Sub]),
    Entry = #entry{state = subscription, pid = Pid, mref = MRef},
    State#state{
        requests = (State#state.requests)#{Id => Entry},
        by_mref = (maps:remove(OldMRef, State#state.by_mref))#{MRef => Id},
        %% A subscription holds no worker slot.
        running = max(0, State#state.running - 1)
    }.

%% @private Owns one `subscriptions/listen' stream, tagged with its
%% subscription id so a client on one channel can demultiplex. Output
%% goes through the coordinator rather than straight to the writer: it
%% is the only process that can see the whole outbound backlog. Order
%% still holds, one sender to one coordinator to one writer.
subscription_init(Coordinator, Sub) ->
    SubId = maps:get(id, Sub),
    Filter = maps:get(filter, Sub),
    ok = barrel_mcp_subscriptions:subscribe(SubId, Filter),
    Coordinator ! {stdio_notify, acknowledgment(SubId, Filter)},
    subscription_loop(Coordinator, SubId).

subscription_loop(Coordinator, SubId) ->
    receive
        {mcp_notification, SubId, Envelope} ->
            Coordinator ! {stdio_notify, Envelope},
            subscription_loop(Coordinator, SubId);
        {mcp_subscription_close, SubId} ->
            Coordinator ! {stdio_notify, subscription_cancelled(SubId)},
            Coordinator ! {stdio_notify, subscription_closed(SubId)},
            _ = barrel_mcp_subscriptions:unsubscribe(SubId),
            ok;
        _Other ->
            subscription_loop(Coordinator, SubId)
    end.

acknowledgment(SubId, Filter) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/subscriptions/acknowledged">>,
        <<"params">> => #{
            <<"_meta">> => #{?MCP_META_SUBSCRIPTION_ID => SubId},
            <<"notifications">> => honoured(Filter)
        }
    }.

honoured(Filter) ->
    Flags = [
        {tools_list_changed, <<"toolsListChanged">>},
        {prompts_list_changed, <<"promptsListChanged">>},
        {resources_list_changed, <<"resourcesListChanged">>}
    ],
    Base = lists:foldl(
        fun({Key, WireKey}, Acc) ->
            case maps:get(Key, Filter, false) of
                true -> Acc#{WireKey => true};
                false -> Acc
            end
        end,
        #{},
        Flags
    ),
    Base1 =
        case maps:get(resource_subscriptions, Filter, []) of
            [] -> Base;
            Uris -> Base#{<<"resourceSubscriptions">> => Uris}
        end,
    case maps:get(task_ids, Filter, []) of
        [] -> Base1;
        Ids -> Base1#{<<"taskIds">> => Ids}
    end.

%% "MUST send notifications/cancelled referencing a subscriptions/listen
%% request ID when it tears down that subscription stream"
%% (cancellation.mdx:12).
subscription_cancelled(SubId) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/cancelled">>,
        <<"params">> => #{
            <<"_meta">> => #{?MCP_META_SUBSCRIPTION_ID => SubId},
            <<"requestId">> => SubId,
            <<"reason">> => <<"Subscription torn down by the server">>
        }
    }.

subscription_closed(SubId) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => SubId,
        <<"result">> => #{
            <<"resultType">> => <<"complete">>,
            <<"_meta">> => #{?MCP_META_SUBSCRIPTION_ID => SubId}
        }
    }.

%%====================================================================
%% Cancellation
%%====================================================================

%% "Servers receiving cancellation notifications SHOULD stop processing
%% the cancelled request ... not send a response"
%% (2026-07-28/basic/patterns/cancellation.mdx:70).
cancel(undefined, State) ->
    State;
cancel(Id, State) ->
    case maps:take(Id, State#state.requests) of
        error ->
            State;
        {#entry{state = queued}, Rest} ->
            State#state{
                requests = Rest,
                pending = queue:filter(fun({Q, _}) -> Q =/= Id end, State#state.pending),
                queued = max(0, State#state.queued - 1)
            };
        {#entry{state = subscription} = Entry, Rest} ->
            drop_entry(Entry),
            State#state{
                requests = Rest,
                by_mref = maps:remove(Entry#entry.mref, State#state.by_mref)
            };
        {#entry{} = Entry, Rest} ->
            drop_entry(Entry),
            take_next(State#state{
                requests = Rest,
                by_mref = maps:remove(Entry#entry.mref, State#state.by_mref),
                by_tag = maps:remove(Entry#entry.tag, State#state.by_tag),
                running = max(0, State#state.running - 1)
            })
    end.

drop_entry(#entry{mref = MRef, pid = Pid}) ->
    _ =
        case MRef of
            undefined -> ok;
            _ -> demonitor(MRef, [flush])
        end,
    stop_child(Pid).

worker_down(MRef, Reason, State) ->
    case maps:take(MRef, State#state.by_mref) of
        error ->
            State;
        {Id, ByMref} ->
            State1 = State#state{by_mref = ByMref},
            case maps:take(Id, State1#state.requests) of
                error ->
                    State1;
                {#entry{state = subscription}, Rest} ->
                    _ = barrel_mcp_subscriptions:unsubscribe(Id),
                    State1#state{requests = Rest};
                {#entry{tag = Tag}, Rest} ->
                    State2 = State1#state{
                        requests = Rest,
                        by_tag = maps:remove(Tag, State1#state.by_tag),
                        running = max(0, State1#state.running - 1)
                    },
                    _ = maybe_report_crash(Id, Reason, State2),
                    take_next(State2)
            end
    end.

%% The worker already answered if it exited after sending its result,
%% which is what removing the tag records.
maybe_report_crash(_Id, normal, _State) ->
    ok;
maybe_report_crash({batch, _}, _Reason, _State) ->
    ok;
maybe_report_crash(Id, _Reason, State) ->
    write(
        State,
        barrel_mcp_protocol:error_response(
            Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal error">>
        )
    ).

take_next(#state{queued = 0} = State) ->
    State;
take_next(State) ->
    case queue:out(State#state.pending) of
        {empty, _} ->
            State#state{queued = 0};
        {{value, {Id, Message}}, Rest} ->
            State1 = State#state{pending = Rest, queued = State#state.queued - 1},
            case maps:is_key(Id, State1#state.requests) of
                false -> take_next(State1);
                true -> start_worker(Id, Message, State1)
            end
    end.

%%====================================================================
%% Notifications
%%====================================================================

%% A notification cannot be answered, so an overflow is dropped rather
%% than refused.
enqueue_notification(Message, #state{notif_len = Len} = State) ->
    case Len >= max_notifications() of
        true ->
            note_drop(State);
        false ->
            drain_notifications(State#state{
                notifications = queue:in(Message, State#state.notifications),
                notif_len = Len + 1
            })
    end.

drain_notifications(#state{notifying = N} = State) when N > 0 ->
    State;
drain_notifications(State) ->
    case queue:out(State#state.notifications) of
        {empty, _} ->
            State;
        {{value, Message}, Rest} ->
            Self = self(),
            Ctx = protocol_state(State),
            _ = spawn(fun() ->
                _ =
                    try
                        barrel_mcp_protocol:handle(Message, Ctx)
                    catch
                        Class:Reason:Stack ->
                            logger:error(
                                "barrel_mcp stdio: notification crashed: ~p:~p~n~p",
                                [Class, Reason, Stack]
                            )
                    end,
                Self ! stdio_notified
            end),
            State#state{
                notifications = Rest,
                notif_len = State#state.notif_len - 1,
                notifying = 1
            }
    end.

%% Rate-limited: a flood of unanswerable traffic must not turn into a
%% flood of log lines.
note_drop(#state{dropped = N, last_drop_log = Last} = State) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - Last >= ?DROP_LOG_INTERVAL_MS of
        true ->
            logger:warning("barrel_mcp stdio: dropped ~B unhandled messages", [N + 1]),
            State#state{dropped = 0, last_drop_log = Now};
        false ->
            State#state{dropped = N + 1}
    end.

%%====================================================================
%% Reader
%%====================================================================

%% @private Frames stdin and nothing else, one frame at a time. Waiting
%% for the coordinator's ack bounds how far ahead it may read; it never
%% waits on handler code.
reader_init(Coordinator) ->
    reader_loop(Coordinator, max_frame_bytes()).

reader_loop(Coordinator, Max) ->
    case read_frame(Max) of
        eof ->
            Coordinator ! stdio_eof;
        {error, Reason} ->
            Coordinator ! {stdio_error, Reason};
        {too_large, _Line} ->
            Coordinator ! stdio_frame_too_large;
        {ok, Line} ->
            Coordinator ! {stdio_frame, Line},
            receive
                stdio_ack -> reader_loop(Coordinator, Max)
            end
    end.

%% One line per read. `io:get_chars/3' would let the frame cap apply
%% before the allocation, but it blocks until it has the full count it
%% was asked for: a request smaller than the chunk is never delivered,
%% because the peer is waiting for an answer before it writes again.
%% Asking for one character at a time does work and costs a round trip
%% per byte, which measured at about sixteen seconds for a one-megabyte
%% message.
%%
%% So the cap is applied to the line after it arrives rather than during
%% the read. The exposure that buys is one oversized frame held in
%% memory before it is refused, and on this transport the peer is the
%% process that launched us or that we launched: it can end us far more
%% cheaply than by sending a long line.
read_frame(Max) ->
    case io:get_line(standard_io, '') of
        eof ->
            eof;
        {error, _} = Err ->
            Err;
        Data ->
            Line = string:trim(to_binary(Data), trailing, "\n"),
            case byte_size(Line) > Max of
                true -> {too_large, Line};
                false -> {ok, Line}
            end
    end.

%% The device is set to `binary' mode, but a caller that did not set it
%% would get a list back.
to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> list_to_binary(L).

%%====================================================================
%% Writer
%%====================================================================

%% @private The only process that writes stdout, so two answers cannot
%% interleave mid-line.
writer_init() ->
    writer_loop().

writer_loop() ->
    receive
        {stdio_write, Envelope} ->
            io:format("~s~n", [barrel_mcp_protocol:encode(Envelope)]),
            writer_loop();
        {stdio_write, Envelope, Ack} ->
            io:format("~s~n", [barrel_mcp_protocol:encode(Envelope)]),
            Ack ! stdio_written,
            writer_loop();
        {stdio_flush, From, Ref} ->
            From ! {stdio_flushed, Ref},
            writer_loop();
        _Other ->
            writer_loop()
    end.

write(#state{writer = Writer}, Envelope) when is_pid(Writer) ->
    Writer ! {stdio_write, Envelope},
    ok;
write(_State, _Envelope) ->
    ok.

%% A notification produces no response, so an overflow is dropped rather
%% than refused, as on the inbound side. The writer acknowledges each
%% one it puts on stdout, which is what keeps the count honest when the
%% peer has stopped reading.
notify(Envelope, #state{writer = Writer, outbound = N} = State) when is_pid(Writer) ->
    case N >= max_outbound() of
        true ->
            note_drop(State);
        false ->
            Writer ! {stdio_write, Envelope, self()},
            State#state{outbound = N + 1}
    end;
notify(_Envelope, State) ->
    State.

%%====================================================================
%% Helpers
%%====================================================================

%% The revision an `initialize' exchange settled on, read off the answer
%% rather than re-derived from the request.
negotiated(#{<<"result">> := #{<<"protocolVersion">> := V}}, _Version) when is_binary(V) ->
    V;
negotiated(_Response, Version) ->
    Version.

max_frame_bytes() ->
    application:get_env(barrel_mcp, stdio_max_frame_bytes, ?DEFAULT_MAX_FRAME_BYTES).

max_workers() ->
    application:get_env(barrel_mcp, stdio_max_workers, ?DEFAULT_MAX_WORKERS).

max_queue() ->
    application:get_env(barrel_mcp, stdio_max_queue, ?DEFAULT_MAX_QUEUE).

max_notifications() ->
    application:get_env(barrel_mcp, stdio_max_notifications, ?DEFAULT_MAX_NOTIFICATIONS).

max_outbound() ->
    application:get_env(barrel_mcp, stdio_max_outbound_notifications, ?DEFAULT_MAX_OUTBOUND).

max_subscriptions() ->
    application:get_env(barrel_mcp, stdio_max_subscriptions, ?DEFAULT_MAX_SUBSCRIPTIONS).
