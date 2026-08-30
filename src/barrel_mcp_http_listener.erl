%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Built-in HTTP/1.1 + HTTP/2 server for the MCP HTTP transports.
%%%
%%% A small acceptor pool on a single port. Cleartext binds speak
%%% HTTP/1.1; TLS binds advertise ALPN `[h2, http/1.1]' and hand each
%%% accepted socket to the negotiated protocol library, so one URL
%%% serves both.
%%%
%%% What this module owns: the listen socket, the acceptors, the
%%% connection and request caps, and the translation between the
%%% wire library and {@link barrel_mcp_http_engine}. What the `h1' and
%%% `h2' libraries own, through `serve_socket/2': the connection
%%% process, framing, pipelining order, one process per request or
%%% stream, and the 500 for a handler that crashes.
%%%
%%% Per request the library invokes our handler in its own process.
%%% That process is the translator: it admits the request against
%%% `max_requests', collects the body, runs the engine in a linked
%%% child, and turns the library's stream-reset and close messages
%%% into the engine's `mcp_disconnect' until the child ends.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_listener).

-export([start/3, start_link/3, stop/1, acceptors/1, in_flight/1]).

%% Spawned entry points (must be exported for `spawn/3`-style traces
%% and for clarity; called via funs internally).
-export([connection_init/3, listener_init/4]).

-define(DEFAULT_MAX_BODY_BYTES, 16 * 1024 * 1024).
%% Requests in flight per listener; livery's figure.
-define(DEFAULT_MAX_REQUESTS, 10000).
-define(DEFAULT_BODY_TIMEOUT, 60000).
-define(HANDSHAKE_TIMEOUT, 30000).
%% Brief backoff after a non-`closed' accept error so a persistent
%% system error (e.g. file-descriptor exhaustion, `emfile') throttles
%% the accept loop instead of spinning the CPU.
-define(ACCEPT_ERROR_BACKOFF, 50).
%% Default cap on concurrently-established connections per listener.
%% `idle_timeout' is `infinity' (so long-lived SSE GETs are never
%% reaped), which means a connection lives until the peer closes it.
%% Without a cap a flood of connections (or slow/idle keep-alive
%% clients) could exhaust file descriptors and memory. Override with
%% the `max_connections' listen option.
-define(DEFAULT_MAX_CONNECTIONS, 16384).

%%====================================================================
%% API
%%====================================================================

%% @doc Start an unsupervised listener registered as `Name'.
%%
%% For use without the `barrel_mcp' application, where the caller owns
%% the lifecycle. Under the application, listeners go through
%% {@link barrel_mcp_listener_sup:start_listener/3} instead, which
%% restarts them on a crash and stops them with the application.
%%
%% `ListenOpts': `#{port, ip, ssl, acceptors, max_connections,
%% max_requests, max_body_bytes, body_timeout_ms}'.
%% `ssl' is `undefined' (cleartext) or
%% `#{certfile, keyfile, cacertfile => _}'.
%% `EngineConfig' is passed verbatim to {@link barrel_mcp_http_engine:handle/6}.
-spec start(atom(), map(), barrel_mcp_http_engine:config()) ->
    {ok, pid()} | {error, term()}.
start(Name, ListenOpts, EngineConfig) ->
    %% No parent: nothing above this listener owns it, so a caller
    %% going away must not take it down.
    proc_lib:start(?MODULE, listener_init, [undefined, Name, ListenOpts, EngineConfig]).

%% @doc Start a listener linked to the caller, for use as a supervised
%% child. A shutdown from the parent closes the listen socket and takes
%% every connection with it.
-spec start_link(atom(), map(), barrel_mcp_http_engine:config()) ->
    {ok, pid()} | {error, term()}.
start_link(Name, ListenOpts, EngineConfig) ->
    Parent = self(),
    proc_lib:start_link(?MODULE, listener_init, [Parent, Name, ListenOpts, EngineConfig]).

%% @doc Stop a listener by registered name.
-spec stop(atom()) -> ok | {error, not_found | stop_timeout}.
stop(Name) ->
    case whereis(Name) of
        undefined ->
            {error, not_found};
        Pid ->
            Ref = make_ref(),
            Pid ! {stop, self(), Ref},
            receive
                {Ref, ok} -> ok
            after 5000 ->
                {error, stop_timeout}
            end
    end.

%%====================================================================
%% Listener process
%%====================================================================

%% @private Shared by the supervised and standalone entry points.
%% `Parent' is `undefined' when standalone, so the shutdown clause in
%% the loop below can never match.
listener_init(Parent, Name, ListenOpts, EngineConfig) ->
    process_flag(trap_exit, true),
    case listen(ListenOpts) of
        {ok, Transport, LSock} ->
            case
                (try
                    register(Name, self())
                catch
                    _:_ -> error
                end)
            of
                true ->
                    Requests = atomics:new(1, [{signed, false}]),
                    Limits = #{
                        max_requests => maps:get(max_requests, ListenOpts, ?DEFAULT_MAX_REQUESTS),
                        max_body_bytes => maps:get(
                            max_body_bytes, ListenOpts, ?DEFAULT_MAX_BODY_BYTES
                        ),
                        body_timeout_ms => maps:get(
                            body_timeout_ms, ListenOpts, ?DEFAULT_BODY_TIMEOUT
                        ),
                        requests => Requests
                    },
                    Handler = serve_opts(EngineConfig, Limits),
                    N = maps:get(
                        acceptors,
                        ListenOpts,
                        max(2, erlang:system_info(schedulers))
                    ),
                    Max = maps:get(
                        max_connections,
                        ListenOpts,
                        ?DEFAULT_MAX_CONNECTIONS
                    ),
                    Counter = atomics:new(1, [{signed, false}]),
                    Listener = self(),
                    Spawn = fun() ->
                        spawn_link(fun() ->
                            acceptor_loop(
                                LSock,
                                Transport,
                                Handler,
                                Listener,
                                Counter,
                                Max
                            )
                        end)
                    end,
                    Acceptors = maps:from_list([{Spawn(), true} || _ <- lists:seq(1, N)]),
                    proc_lib:init_ack({ok, self()}),
                    listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors, Requests);
                _ ->
                    close_listen(Transport, LSock),
                    proc_lib:init_ack({error, {already_started, Name}}),
                    exit(normal)
            end;
        {error, Reason} ->
            proc_lib:init_ack({error, Reason}),
            exit(normal)
    end.

listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors, Requests) ->
    receive
        {'EXIT', Parent, _Reason} ->
            %% The supervisor is taking us down. Same teardown as an
            %% explicit stop: close the socket and exit `shutdown', so
            %% the linked connections go too.
            close_listen(Transport, LSock),
            exit(shutdown);
        {stop, From, Ref} ->
            %% Close the listen socket (unblocks acceptors) and exit
            %% with `shutdown', which propagates to the linked
            %% connection processes so no stale server survives a stop.
            close_listen(Transport, LSock),
            From ! {Ref, ok},
            exit(shutdown);
        {track, Pid} ->
            %% Monitor each accepted connection so its slot is released
            %% on termination, however the process dies: an h2 wrapper
            %% failing abnormally takes the connection process with it.
            _ = monitor(process, Pid),
            listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors, Requests);
        {'DOWN', _Ref, process, _Pid, _Reason} ->
            atomics:sub(Counter, 1, 1),
            listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors, Requests);
        {in_flight, From, Ref} ->
            From ! {Ref, atomics:get(Requests, 1)},
            listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors, Requests);
        {acceptors, From, Ref} ->
            From ! {Ref, maps:keys(Acceptors)},
            listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors, Requests);
        {'EXIT', Pid, Reason} when is_map_key(Pid, Acceptors) ->
            %% An acceptor ends normally only when the listen socket is
            %% gone; anything else leaves the pool short, so refill it.
            Acceptors1 =
                case Reason of
                    normal ->
                        maps:remove(Pid, Acceptors);
                    shutdown ->
                        maps:remove(Pid, Acceptors);
                    _ ->
                        logger:warning("mcp http acceptor exited: ~p; replacing", [Reason]),
                        %% A replacement that dies at once must not spin.
                        timer:sleep(?ACCEPT_ERROR_BACKOFF),
                        (maps:remove(Pid, Acceptors))#{Spawn() => true}
                end,
            listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors1, Requests);
        {'EXIT', _Pid, _Reason} ->
            %% A connection process exited; the slot is released by the
            %% matching `DOWN' above.
            listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors, Requests);
        _Other ->
            listener_loop(Parent, LSock, Transport, Counter, Spawn, Acceptors, Requests)
    end.

%% @doc The live acceptor pids of a listener. For tests.
-spec acceptors(atom()) -> [pid()].
acceptors(Name) ->
    Ref = make_ref(),
    Name ! {acceptors, self(), Ref},
    receive
        {Ref, Pids} -> Pids
    after 5000 ->
        error({no_listener, Name})
    end.

%% @doc Requests in flight on a listener, admitted and not yet ended.
-spec in_flight(atom()) -> non_neg_integer().
in_flight(Name) ->
    Ref = make_ref(),
    Name ! {in_flight, self(), Ref},
    receive
        {Ref, N} -> N
    after 5000 ->
        error({no_listener, Name})
    end.

listen(ListenOpts) ->
    Port = maps:get(port, ListenOpts, 9090),
    Ip = maps:get(ip, ListenOpts, {127, 0, 0, 1}),
    Base = [
        binary,
        {active, false},
        {reuseaddr, true},
        {ip, Ip},
        {backlog, 1024}
    ],
    case maps:get(ssl, ListenOpts, undefined) of
        undefined ->
            case gen_tcp:listen(Port, Base) of
                {ok, LSock} -> {ok, gen_tcp, LSock};
                {error, _} = E -> E
            end;
        #{certfile := Cert, keyfile := Key} = Ssl ->
            CaOpts =
                case maps:get(cacertfile, Ssl, undefined) of
                    undefined -> [];
                    CaCert -> [{cacertfile, CaCert}]
                end,
            TlsOpts =
                Base ++
                    [
                        {certfile, Cert},
                        {keyfile, Key},
                        {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]},
                        {versions, ['tlsv1.2', 'tlsv1.3']}
                    ] ++ CaOpts,
            case ssl:listen(Port, TlsOpts) of
                {ok, LSock} -> {ok, ssl, LSock};
                {error, _} = E -> E
            end
    end.

close_listen(gen_tcp, LSock) ->
    _ = gen_tcp:close(LSock),
    ok;
close_listen(ssl, LSock) ->
    _ = ssl:close(LSock),
    ok.

%%====================================================================
%% Acceptor
%%====================================================================

acceptor_loop(LSock, Transport, Serve, Listener, Counter, Max) ->
    case do_accept(Transport, LSock) of
        {ok, Socket} ->
            _ =
                case atomics:add_get(Counter, 1, 1) > Max of
                    false ->
                        Pid = start_connection(Socket, Transport, Serve, Listener),
                        %% Hand the pid to the listener to monitor; it
                        %% releases the slot on the connection's `DOWN'.
                        Listener ! {track, Pid};
                    true ->
                        %% At capacity: undo the reservation and drop the
                        %% connection so a flood cannot exhaust resources.
                        %% The brief backoff bounds the accept/close churn.
                        atomics:sub(Counter, 1, 1),
                        close(Transport, Socket),
                        timer:sleep(?ACCEPT_ERROR_BACKOFF)
                end,
            acceptor_loop(LSock, Transport, Serve, Listener, Counter, Max);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            timer:sleep(?ACCEPT_ERROR_BACKOFF),
            acceptor_loop(LSock, Transport, Serve, Listener, Counter, Max)
    end.

do_accept(gen_tcp, LSock) -> gen_tcp:accept(LSock, infinity);
do_accept(ssl, LSock) -> ssl:transport_accept(LSock, infinity).

%% Spawn the connection process, transfer socket ownership to it, then
%% let it handshake (TLS) and run the protocol. The process links to
%% the listener (which traps exits) so a crash is absorbed there while
%% a listener `stop' tears every connection down.
start_connection(Socket, Transport, Serve, Listener) ->
    Pid = spawn(?MODULE, connection_init, [Transport, Serve, Listener]),
    _ =
        case transfer(Transport, Socket, Pid) of
            ok ->
                Pid ! {socket_ready, Socket};
            {error, Reason} ->
                Pid ! {socket_failed, Reason},
                close(Transport, Socket)
        end,
    Pid.

transfer(gen_tcp, Socket, Pid) -> gen_tcp:controlling_process(Socket, Pid);
transfer(ssl, Socket, Pid) -> ssl:controlling_process(Socket, Pid).

close(gen_tcp, Socket) ->
    _ = gen_tcp:close(Socket),
    ok;
close(ssl, Socket) ->
    _ = ssl:close(Socket),
    ok.

%%====================================================================
%% Per-connection process
%%====================================================================

connection_init(Transport, Serve, Listener) ->
    %% Link to the listener so a `stop' (listener exits `shutdown')
    %% terminates this connection too. The listener traps exits, so
    %% our own crash is absorbed there rather than killing the pool.
    %% The listener also monitors us and releases our connection slot
    %% on `DOWN' (see {@link listener_loop/3}).
    link(Listener),
    receive
        {socket_ready, Socket} ->
            handle_accepted(Socket, Transport, Serve);
        {socket_failed, _Reason} ->
            ok
    after 5000 ->
        ok
    end.

handle_accepted(Socket, gen_tcp, Serve) ->
    %% Cleartext: HTTP/1.1.
    serve(fun h1:serve_socket/2, gen_tcp, Socket, maps:get(h1, Serve));
handle_accepted(Socket, ssl, Serve) ->
    case ssl:handshake(Socket, ?HANDSHAKE_TIMEOUT) of
        {ok, Tls} ->
            case ssl:negotiated_protocol(Tls) of
                {ok, <<"h2">>} -> serve(fun h2:serve_socket/2, ssl, Tls, maps:get(h2, Serve));
                _ -> serve(fun h1:serve_socket/2, ssl, Tls, maps:get(h1, Serve))
            end;
        {error, _Reason} ->
            _ = ssl:close(Socket),
            ok
    end.

%% The library's connection process is linked to us, so we outlive it
%% on purpose: our death (a listener stop, over the link) tears the
%% connection down, and its end releases our slot through the
%% listener's monitor. h1 closes the socket itself on a failed
%% hand-off; h2 leaves it to us; closing twice is harmless.
serve(ServeSocket, Transport, Socket, Opts) ->
    case ServeSocket(Socket, Opts) of
        {ok, Pid} ->
            MRef = monitor(process, Pid),
            receive
                {'DOWN', MRef, process, Pid, _Reason} -> ok
            end;
        {error, _Reason} ->
            close(Transport, Socket)
    end.

%%====================================================================
%% Per-request translator
%%====================================================================

%% The option maps handed to `serve_socket/2', one per protocol. h1
%% enforces the body cap itself and answers 413; h2 has no such
%% option, so the translator checks it for both.
serve_opts(EngineConfig, Limits) ->
    #{
        h1 => #{
            handler => handler(h1, EngineConfig, Limits),
            idle_timeout => infinity,
            max_body_size => maps:get(max_body_bytes, Limits)
        },
        h2 => #{handler => handler(h2, EngineConfig, Limits)}
    }.

%% Runs in the process the wire library spawned for this request.
handler(Proto, EngineConfig, Limits) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        case attach(Proto, Conn, StreamId) of
            ok -> admit(Proto, Conn, StreamId, Method, Path, Headers, EngineConfig, Limits);
            {error, _Gone} -> ok
        end
    end.

%% h2 delivers a stream's frames only to a registered handler.
attach(h1, _Conn, _StreamId) ->
    ok;
attach(h2, Conn, StreamId) ->
    case h2:set_stream_handler(Conn, StreamId, self()) of
        ok -> ok;
        {ok, _Buffered} -> ok;
        {error, _} = E -> E
    end.

admit(Proto, Conn, StreamId, Method, Path, Headers, EngineConfig, Limits) ->
    #{requests := Requests, max_requests := Max} = Limits,
    case atomics:add_get(Requests, 1, 1) > Max of
        true ->
            atomics:sub(Requests, 1, 1),
            answer(
                Proto, Conn, StreamId, 503, [{<<"retry-after">>, <<"1">>}], <<"Server overloaded">>
            );
        false ->
            try
                serve_request(Proto, Conn, StreamId, Method, Path, Headers, EngineConfig, Limits)
            after
                atomics:sub(Requests, 1, 1)
            end
    end.

serve_request(Proto, Conn, StreamId, Method, Path, Headers, EngineConfig, Limits) ->
    case read_request_body(Proto, Conn, StreamId, Method, Limits) of
        {ok, Body} ->
            Responder = responder(Proto, Conn, StreamId),
            {Engine, MRef} = spawn_engine(
                Proto, Conn, StreamId, Method, Path, Headers, Body, Responder, EngineConfig
            ),
            relay_until_done(Proto, Conn, StreamId, Engine, MRef);
        {error, body_too_large} ->
            answer(Proto, Conn, StreamId, 413, [], <<"Request body too large">>);
        {error, timeout} ->
            answer(Proto, Conn, StreamId, 408, [], <<"Request body timeout">>);
        {error, closed} ->
            ok
    end.

%% Forward what the library says about the stream as the engine's
%% disconnect, until the engine process ends.
relay_until_done(Proto, Conn, StreamId, Engine, MRef) ->
    receive
        {'DOWN', MRef, process, Engine, _Reason} ->
            ok;
        Msg ->
            case disconnect_message(Proto, Conn, StreamId, Msg) of
                true -> Engine ! mcp_disconnect;
                false -> ok
            end,
            relay_until_done(Proto, Conn, StreamId, Engine, MRef)
    end.

disconnect_message(h1, _Conn, StreamId, {h1_stream, StreamId, {stream_reset, _}}) -> true;
disconnect_message(h2, Conn, StreamId, {h2, Conn, {stream_reset, StreamId, _}}) -> true;
disconnect_message(h2, Conn, _StreamId, {h2, Conn, {closed, _}}) -> true;
disconnect_message(_, _, _, _) -> false.

%% Linked as well as monitored. An engine serving a long-lived stream
%% blocks until told to stop, so if this process is killed outright
%% there must be a signal left to send: the link is it.
spawn_engine(Proto, Conn, StreamId, Method, Path, Headers, Body, Responder, EngineConfig) ->
    spawn_opt(
        fun() ->
            %% Trapping turns that link into a message. What a lost
            %% connection means is revision-dependent, and only the
            %% engine knows which revision is being served.
            process_flag(trap_exit, true),
            try
                barrel_mcp_http_engine:handle(
                    Method, Path, Headers, Body, Responder, EngineConfig
                )
            catch
                Class:Reason:Stack ->
                    %% A connection that went away mid-handler is not a
                    %% crash: the exit is the listener's shutdown or the
                    %% connection statem already gone.
                    _ =
                        case {Class, Reason} of
                            {exit, shutdown} ->
                                ok;
                            {exit, {shutdown, _}} ->
                                ok;
                            {exit, {noproc, {gen_statem, call, _}}} ->
                                ok;
                            {exit, {normal, {gen_statem, call, _}}} ->
                                ok;
                            _ ->
                                logger:error(
                                    "mcp http handler crash: ~p:~p~n~p",
                                    [Class, Reason, Stack]
                                )
                        end,
                    answer(Proto, Conn, StreamId, 500, [], <<"Internal Server Error">>)
            end
        end,
        [link, monitor]
    ).

%% A fixed answer from the translator itself: a refusal, or the 500
%% for an engine that crashed. Nothing here may raise.
answer(Proto, Conn, StreamId, Status, Headers, Body) ->
    Hdrs = [
        {<<"content-type">>, <<"text/plain">>},
        {<<"content-length">>, integer_to_binary(byte_size(Body))}
        | Headers
    ],
    _ =
        (try
            Proto:send_response(Conn, StreamId, Status, Hdrs)
        catch
            _:_ -> ok
        end),
    _ =
        (try
            Proto:send_data(Conn, StreamId, Body, true)
        catch
            _:_ -> ok
        end),
    ok.

read_request_body(Proto, Conn, StreamId, Method, Limits) when
    Method =:= <<"POST">>; Method =:= <<"PUT">>
->
    read_body(Proto, Conn, StreamId, Limits, <<>>);
read_request_body(_Proto, _Conn, _StreamId, _Method, _Limits) ->
    {ok, <<>>}.

read_body(
    Proto, Conn, StreamId, #{max_body_bytes := Max, body_timeout_ms := Timeout} = Limits, Acc
) ->
    receive
        Msg ->
            case body_message(Proto, Conn, StreamId, Msg) of
                {data, Data, End} ->
                    Combined = <<Acc/binary, Data/binary>>,
                    case {byte_size(Combined) > Max, End} of
                        {true, _} -> {error, body_too_large};
                        {false, true} -> {ok, Combined};
                        {false, false} -> read_body(Proto, Conn, StreamId, Limits, Combined)
                    end;
                eof ->
                    {ok, Acc};
                closed ->
                    {error, closed};
                other ->
                    read_body(Proto, Conn, StreamId, Limits, Acc)
            end
    after Timeout ->
        {error, timeout}
    end.

body_message(h1, _Conn, StreamId, {h1_stream, StreamId, {data, Data, End}}) -> {data, Data, End};
body_message(h1, _Conn, StreamId, {h1_stream, StreamId, {trailers, _}}) -> eof;
body_message(h1, _Conn, StreamId, {h1_stream, StreamId, {stream_reset, _}}) -> closed;
body_message(h2, Conn, StreamId, {h2, Conn, {data, StreamId, Data, Fin}}) -> {data, Data, Fin};
body_message(h2, Conn, StreamId, {h2, Conn, {trailers, StreamId, _}}) -> eof;
body_message(h2, Conn, StreamId, {h2, Conn, {stream_reset, StreamId, _}}) -> closed;
body_message(h2, Conn, _StreamId, {h2, Conn, {closed, _}}) -> closed;
body_message(_, _, _, _) -> other.

%% Responder closures over the negotiated protocol module + connection.
responder(Proto, Conn, StreamId) ->
    #{
        reply => fun(Status, Headers, Body) ->
            Bin = iolist_to_binary(Body),
            Hdrs = ensure_content_length(wire_headers(Proto, Headers), byte_size(Bin)),
            _ = Proto:send_response(Conn, StreamId, Status, Hdrs),
            _ = Proto:send_data(Conn, StreamId, Bin, true),
            ok
        end,
        stream_start => fun(Status, Headers) ->
            case Proto:send_response(Conn, StreamId, Status, wire_headers(Proto, Headers)) of
                ok ->
                    ok;
                {error, Reason} ->
                    %% Nothing the engine writes afterwards can reach
                    %% the peer; a stream loop would spin on it.
                    exit({shutdown, {stream_start, Reason}})
            end
        end,
        stream_chunk => fun(Data) ->
            Proto:send_data(Conn, StreamId, iolist_to_binary(Data), false)
        end,
        stream_end => fun() ->
            _ = Proto:send_data(Conn, StreamId, <<>>, true),
            ok
        end
    }.

%% HTTP/2 forbids connection-specific headers (RFC 9113 section 8.2.2)
%% and h2 refuses the whole response over one.
wire_headers(h1, Headers) ->
    Headers;
wire_headers(h2, Headers) ->
    [
        {K, V}
     || {K, V} <- Headers,
        not lists:member(string:lowercase(K), [
            <<"connection">>,
            <<"keep-alive">>,
            <<"proxy-connection">>,
            <<"transfer-encoding">>,
            <<"upgrade">>
        ])
    ].

%% Add an explicit content-length for fixed responses so h1 does not
%% fall back to chunked framing (and 204/202 bodies stay empty).
ensure_content_length(Headers, Len) ->
    HasFraming = lists:any(
        fun({K, _}) ->
            L = string:lowercase(K),
            L =:= <<"content-length">> orelse L =:= <<"transfer-encoding">>
        end,
        Headers
    ),
    case HasFraming of
        true -> Headers;
        false -> [{<<"content-length">>, integer_to_binary(Len)} | Headers]
    end.
