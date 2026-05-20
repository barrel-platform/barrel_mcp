%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Built-in HTTP/1.1 + HTTP/2 server for the MCP HTTP transports.
%%%
%%% A small acceptor pool on a single port, built on the `h1' and
%%% `h2' protocol libraries (no cowboy). Cleartext binds speak
%%% HTTP/1.1; TLS binds advertise ALPN `[h2, http/1.1]' and dispatch
%%% each connection to the negotiated protocol — so one URL serves
%%% both, like the cowboy listener it replaces.
%%%
%%% Per accepted connection a process owns the socket, performs the
%%% TLS handshake (TLS only), starts an `h1_connection'/`h2_connection'
%%% in server mode and runs the owner loop. Each request is handled in
%%% its own process that reads the body, builds a
%%% {@link barrel_mcp_http_engine} `Responder' over
%%% `h1'/`h2:send_response/send_data', and runs the engine.
%%%
%%% The engine, not this module, holds the MCP protocol logic; this
%%% module is pure transport plumbing.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_listener).

-export([start/3, stop/1]).

%% Spawned entry points (must be exported for `spawn/3`-style traces
%% and for clarity; called via funs internally).
-export([connection_init/3]).

-define(MAX_BODY_BYTES, 16 * 1024 * 1024).
-define(BODY_TIMEOUT, 60000).
-define(HANDSHAKE_TIMEOUT, 30000).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a listener registered as `Name'.
%%
%% `ListenOpts': `#{port, ip, ssl, acceptors}'. `ssl' is `undefined'
%% (cleartext) or `#{certfile, keyfile, cacertfile => _}'.
%% `EngineConfig' is passed verbatim to {@link barrel_mcp_http_engine:handle/6}.
-spec start(atom(), map(), barrel_mcp_http_engine:config()) ->
    {ok, pid()} | {error, term()}.
start(Name, ListenOpts, EngineConfig) ->
    Parent = self(),
    Pid = spawn(fun() -> listener_init(Parent, Name, ListenOpts, EngineConfig) end),
    MRef = monitor(process, Pid),
    receive
        {Pid, {ok, Pid}} ->
            demonitor(MRef, [flush]),
            {ok, Pid};
        {Pid, {error, Reason}} ->
            demonitor(MRef, [flush]),
            {error, Reason};
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, Reason}
    after 5000 ->
        demonitor(MRef, [flush]),
        {error, listener_start_timeout}
    end.

%% @doc Stop a listener by registered name.
-spec stop(atom()) -> ok | {error, not_found}.
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

listener_init(Parent, Name, ListenOpts, EngineConfig) ->
    process_flag(trap_exit, true),
    case listen(ListenOpts) of
        {ok, Transport, LSock} ->
            case catch register(Name, self()) of
                true ->
                    Handler = make_handler(EngineConfig),
                    N = maps:get(acceptors, ListenOpts,
                                 max(2, erlang:system_info(schedulers))),
                    Listener = self(),
                    _ = [spawn_link(fun() ->
                                        acceptor_loop(LSock, Transport, Handler, Listener)
                                    end)
                         || _ <- lists:seq(1, N)],
                    Parent ! {self(), {ok, self()}},
                    listener_loop(LSock, Transport);
                _ ->
                    close_listen(Transport, LSock),
                    Parent ! {self(), {error, {already_started, Name}}}
            end;
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

listener_loop(LSock, Transport) ->
    receive
        {stop, From, Ref} ->
            %% Close the listen socket (unblocks acceptors) and exit
            %% with `shutdown', which propagates to the linked
            %% connection processes so no stale server survives a stop.
            close_listen(Transport, LSock),
            From ! {Ref, ok},
            exit(shutdown);
        {'EXIT', _Pid, _Reason} ->
            %% A connection or acceptor process exited; ignore.
            listener_loop(LSock, Transport);
        _Other ->
            listener_loop(LSock, Transport)
    end.

listen(ListenOpts) ->
    Port = maps:get(port, ListenOpts, 9090),
    Ip = maps:get(ip, ListenOpts, {127, 0, 0, 1}),
    Base = [binary, {active, false}, {reuseaddr, true},
            {ip, Ip}, {backlog, 1024}],
    case maps:get(ssl, ListenOpts, undefined) of
        undefined ->
            case gen_tcp:listen(Port, Base) of
                {ok, LSock} -> {ok, gen_tcp, LSock};
                {error, _} = E -> E
            end;
        #{certfile := Cert, keyfile := Key} = Ssl ->
            CaOpts = case maps:get(cacertfile, Ssl, undefined) of
                         undefined -> [];
                         CaCert -> [{cacertfile, CaCert}]
                     end,
            TlsOpts = Base ++ [{certfile, Cert}, {keyfile, Key},
                               {alpn_preferred_protocols,
                                [<<"h2">>, <<"http/1.1">>]},
                               {versions, ['tlsv1.2', 'tlsv1.3']}] ++ CaOpts,
            case ssl:listen(Port, TlsOpts) of
                {ok, LSock} -> {ok, ssl, LSock};
                {error, _} = E -> E
            end
    end.

close_listen(gen_tcp, LSock) -> _ = gen_tcp:close(LSock), ok;
close_listen(ssl, LSock) -> _ = ssl:close(LSock), ok.

%%====================================================================
%% Acceptor
%%====================================================================

acceptor_loop(LSock, Transport, Handler, Listener) ->
    case do_accept(Transport, LSock) of
        {ok, Socket} ->
            start_connection(Socket, Transport, Handler, Listener),
            acceptor_loop(LSock, Transport, Handler, Listener);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            acceptor_loop(LSock, Transport, Handler, Listener)
    end.

do_accept(gen_tcp, LSock) -> gen_tcp:accept(LSock, infinity);
do_accept(ssl, LSock) -> ssl:transport_accept(LSock, infinity).

%% Spawn the connection process, transfer socket ownership to it, then
%% let it handshake (TLS) and run the protocol. The process links to
%% the listener (which traps exits) so a crash is absorbed there while
%% a listener `stop' tears every connection down.
start_connection(Socket, Transport, Handler, Listener) ->
    Pid = spawn(?MODULE, connection_init, [Transport, Handler, Listener]),
    _ = case transfer(Transport, Socket, Pid) of
        ok ->
            Pid ! {socket_ready, Socket};
        {error, Reason} ->
            Pid ! {socket_failed, Reason},
            close(Transport, Socket)
    end,
    ok.

transfer(gen_tcp, Socket, Pid) -> gen_tcp:controlling_process(Socket, Pid);
transfer(ssl, Socket, Pid) -> ssl:controlling_process(Socket, Pid).

close(gen_tcp, Socket) -> _ = gen_tcp:close(Socket), ok;
close(ssl, Socket) -> _ = ssl:close(Socket), ok.

%%====================================================================
%% Per-connection process
%%====================================================================

connection_init(Transport, Handler, Listener) ->
    %% Link to the listener so a `stop' (listener exits `shutdown')
    %% terminates this connection too. The listener traps exits, so
    %% our own crash is absorbed there rather than killing the pool.
    link(Listener),
    receive
        {socket_ready, Socket} ->
            handle_accepted(Socket, Transport, Handler);
        {socket_failed, _Reason} ->
            ok
    after 5000 ->
        ok
    end.

handle_accepted(Socket, gen_tcp, Handler) ->
    %% Cleartext: HTTP/1.1.
    run_h1(Socket, gen_tcp, Handler);
handle_accepted(Socket, ssl, Handler) ->
    case ssl:handshake(Socket, ?HANDSHAKE_TIMEOUT) of
        {ok, Tls} ->
            case ssl:negotiated_protocol(Tls) of
                {ok, <<"h2">>} -> run_h2(Tls, Handler);
                _ -> run_h1(Tls, ssl, Handler)
            end;
        {error, _Reason} ->
            _ = ssl:close(Socket),
            ok
    end.

run_h1(Socket, Transport, Handler) ->
    ConnOpts = #{idle_timeout => infinity, max_body_size => ?MAX_BODY_BYTES},
    case h1_connection:start_link(server, Socket, self(), ConnOpts) of
        {ok, Conn} ->
            case transfer(Transport, Socket, Conn) of
                ok ->
                    case h1_connection:activate(Conn) of
                        ok -> h1_loop(Conn, Handler);
                        {error, _} -> catch h1_connection:close(Conn)
                    end;
                {error, _} ->
                    catch h1_connection:close(Conn),
                    close(Transport, Socket)
            end;
        {error, _Reason} ->
            close(Transport, Socket)
    end.

run_h2(Socket, Handler) ->
    case h2_connection:start_link(server, Socket, self(), #{}) of
        {ok, Conn} ->
            case ssl:controlling_process(Socket, Conn) of
                ok ->
                    _ = h2_connection:activate(Conn),
                    h2_loop(Conn, Handler, #{});
                {error, _} ->
                    catch h2_connection:close(Conn),
                    _ = ssl:close(Socket)
            end;
        {error, _Reason} ->
            _ = ssl:close(Socket)
    end.

%%====================================================================
%% HTTP/1.1 owner loop (serial per connection, like h1_server)
%%====================================================================

h1_loop(Conn, Handler) ->
    receive
        {h1, Conn, {request, StreamId, Method, Path, Headers}} ->
            {Pid, MRef} = spawn_handler(h1, Conn, StreamId, Method, Path,
                                        Headers, Handler),
            h1_pump(Conn, Handler, Pid, MRef, StreamId);
        {h1, Conn, {upgrade, StreamId, _Proto, Method, Path, Headers}} ->
            {Pid, MRef} = spawn_handler(h1, Conn, StreamId, Method, Path,
                                        Headers, Handler),
            h1_pump(Conn, Handler, Pid, MRef, StreamId);
        {h1, Conn, {goaway, _, _}} -> ok;
        {h1, Conn, {closed, _}} -> ok;
        {'EXIT', Conn, _} -> ok;
        _Other ->
            h1_loop(Conn, Handler)
    end.

h1_pump(Conn, Handler, Pid, MRef, StreamId) ->
    receive
        {h1, Conn, {data, StreamId, Data, End}} ->
            Pid ! {mcp_body, StreamId, {data, Data, End}},
            h1_pump(Conn, Handler, Pid, MRef, StreamId);
        {h1, Conn, {trailers, StreamId, _T}} ->
            Pid ! {mcp_body, StreamId, eof},
            h1_pump(Conn, Handler, Pid, MRef, StreamId);
        {h1, Conn, {stream_reset, StreamId, _R}} ->
            Pid ! mcp_disconnect,
            h1_pump(Conn, Handler, Pid, MRef, StreamId);
        {'DOWN', MRef, process, Pid, _Reason} ->
            h1_loop(Conn, Handler);
        {h1, Conn, {closed, _Reason}} ->
            Pid ! mcp_disconnect,
            ok;
        {'EXIT', Conn, _Reason} ->
            Pid ! mcp_disconnect,
            ok;
        _Other ->
            h1_pump(Conn, Handler, Pid, MRef, StreamId)
    end.

%%====================================================================
%% HTTP/2 owner loop (concurrent streams)
%%====================================================================

h2_loop(Conn, Handler, Streams) ->
    receive
        {h2, Conn, {request, StreamId, Method, Path, Headers}} ->
            {Pid, MRef} = spawn_handler(h2, Conn, StreamId, Method, Path,
                                        Headers, Handler),
            h2_loop(Conn, Handler, Streams#{StreamId => {Pid, MRef}});
        {h2, Conn, {data, StreamId, Data, Fin}} ->
            route(Streams, StreamId, {mcp_body, StreamId, {data, Data, Fin}}),
            h2_loop(Conn, Handler, Streams);
        {h2, Conn, {trailers, StreamId, _T}} ->
            route(Streams, StreamId, {mcp_body, StreamId, eof}),
            h2_loop(Conn, Handler, Streams);
        {h2, Conn, {stream_reset, StreamId, _R}} ->
            route(Streams, StreamId, mcp_disconnect),
            h2_loop(Conn, Handler, maps:remove(StreamId, Streams));
        {'DOWN', _MRef, process, Pid, _Reason} ->
            h2_loop(Conn, Handler, drop_pid(Streams, Pid));
        {h2, Conn, {closed, _Reason}} ->
            broadcast_disconnect(Streams),
            ok;
        {h2, Conn, {goaway, _, _}} ->
            broadcast_disconnect(Streams),
            ok;
        {'EXIT', Conn, _Reason} ->
            broadcast_disconnect(Streams),
            ok;
        _Other ->
            h2_loop(Conn, Handler, Streams)
    end.

route(Streams, StreamId, Msg) ->
    case maps:find(StreamId, Streams) of
        {ok, {Pid, _}} -> Pid ! Msg, ok;
        error -> ok
    end.

drop_pid(Streams, Pid) ->
    maps:filter(fun(_, {P, _}) -> P =/= Pid end, Streams).

broadcast_disconnect(Streams) ->
    maps:foreach(fun(_, {Pid, _}) -> Pid ! mcp_disconnect end, Streams).

%%====================================================================
%% Per-request handler
%%====================================================================

spawn_handler(Proto, Conn, StreamId, Method, Path, Headers, Handler) ->
    spawn_monitor(fun() ->
        try
            Handler(Proto, Conn, StreamId, Method, Path, Headers)
        catch
            Class:Reason:Stack ->
                logger:error("mcp http handler crash: ~p:~p~n~p",
                             [Class, Reason, Stack]),
                catch Proto:send_response(Conn, StreamId, 500,
                                          [{<<"content-type">>, <<"text/plain">>},
                                           {<<"content-length">>, <<"21">>}]),
                catch Proto:send_data(Conn, StreamId,
                                      <<"Internal Server Error">>, true)
        end
    end).

%% Build the engine handler fun (closes over the engine config).
make_handler(EngineConfig) ->
    fun(Proto, Conn, StreamId, Method, Path, Headers) ->
        Body = read_request_body(Method, StreamId),
        Responder = responder(Proto, Conn, StreamId),
        barrel_mcp_http_engine:handle(Method, Path, Headers, Body,
                                      Responder, EngineConfig)
    end.

read_request_body(<<"POST">>, StreamId) ->
    case read_body(StreamId, <<>>) of
        {ok, Body} -> Body;
        {error, _} -> <<>>
    end;
read_request_body(<<"PUT">>, StreamId) ->
    case read_body(StreamId, <<>>) of
        {ok, Body} -> Body;
        {error, _} -> <<>>
    end;
read_request_body(_Method, _StreamId) ->
    <<>>.

read_body(StreamId, Acc) ->
    receive
        {mcp_body, StreamId, {data, Data, true}} ->
            {ok, <<Acc/binary, Data/binary>>};
        {mcp_body, StreamId, {data, Data, false}} ->
            Combined = <<Acc/binary, Data/binary>>,
            case byte_size(Combined) > ?MAX_BODY_BYTES of
                true -> {error, body_too_large};
                false -> read_body(StreamId, Combined)
            end;
        {mcp_body, StreamId, eof} ->
            {ok, Acc};
        mcp_disconnect ->
            {error, closed}
    after ?BODY_TIMEOUT ->
        {error, timeout}
    end.

%% Responder closures over the negotiated protocol module + connection.
responder(Proto, Conn, StreamId) ->
    #{
        reply => fun(Status, Headers, Body) ->
            Bin = iolist_to_binary(Body),
            Hdrs = ensure_content_length(Headers, byte_size(Bin)),
            _ = Proto:send_response(Conn, StreamId, Status, Hdrs),
            _ = Proto:send_data(Conn, StreamId, Bin, true),
            ok
        end,
        stream_start => fun(Status, Headers) ->
            _ = Proto:send_response(Conn, StreamId, Status, Headers),
            ok
        end,
        stream_chunk => fun(Data) ->
            Proto:send_data(Conn, StreamId, iolist_to_binary(Data), false)
        end,
        stream_end => fun() ->
            _ = Proto:send_data(Conn, StreamId, <<>>, true),
            ok
        end
    }.

%% Add an explicit content-length for fixed responses so h1 does not
%% fall back to chunked framing (and 204/202 bodies stay empty).
ensure_content_length(Headers, Len) ->
    HasFraming = lists:any(
        fun({K, _}) ->
            L = string:lowercase(K),
            L =:= <<"content-length">> orelse L =:= <<"transfer-encoding">>
        end, Headers),
    case HasFraming of
        true -> Headers;
        false -> [{<<"content-length">>, integer_to_binary(Len)} | Headers]
    end.
