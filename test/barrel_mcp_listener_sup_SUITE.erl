%%%-------------------------------------------------------------------
%%% @doc HTTP listeners under supervision.
%%%
%%% Listeners used to be started with a bare spawn, outside any
%%% supervision tree: a crash meant a silent outage, and
%%% `application:stop/1' left the process running with its port bound.
%%% These cases pin both, plus the standalone path that still has to
%%% work without the application.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_listener_sup_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(barrel_mcp_test_helpers, [wait_until/2]).

-include("barrel_mcp.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    listener_is_supervised/1,
    restarts_after_crash/1,
    acceptor_is_replaced/1,
    application_stop_releases_port/1,
    stop_then_start_again/1,
    standalone_without_application/1,
    pipelined_requests_are_all_answered/1,
    body_over_cap_is_413/1,
    max_requests_answers_503/1,
    max_connections_refuses_the_next_socket/1,
    tls_serves_http1_and_http2/1,
    http2_disconnect_cancels_the_request/1
]).
-export([slow_tool/1]).

-define(BASE_PORT, 21800).

all() ->
    [
        listener_is_supervised,
        restarts_after_crash,
        acceptor_is_replaced,
        application_stop_releases_port,
        stop_then_start_again,
        standalone_without_application,
        pipelined_requests_are_all_answered,
        body_over_cap_is_413,
        max_requests_answers_503,
        max_connections_refuses_the_next_socket,
        tls_serves_http1_and_http2,
        http2_disconnect_cancels_the_request
    ].

%% Where the slow tool reports its lifecycle.
-define(WATCH, barrel_mcp_listener_watch).

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"slow">>, ?MODULE, slow_tool, #{
        description => <<"Reports that it started, waits, reports that it finished">>
    }),
    [{port, barrel_mcp_test_helpers:case_port(?BASE_PORT, TC, all())} | Config].

end_per_testcase(_TC, _Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    application:stop(barrel_mcp),
    timer:sleep(50),
    ok.

%%====================================================================
%% Cases
%%====================================================================

listener_is_supervised(Config) ->
    Port = ?config(port, Config),
    {ok, Pid} = barrel_mcp:start_http_stream(#{port => Port}),
    Children = supervisor:which_children(barrel_mcp_listener_sup),
    ?assertMatch(
        {barrel_mcp_http_stream_listener, Pid, worker, _},
        lists:keyfind(barrel_mcp_http_stream_listener, 1, Children)
    ),
    ok.

%% A crash used to be a silent outage: the acceptors and connections
%% died with the listener and nothing brought it back.
restarts_after_crash(Config) ->
    Port = ?config(port, Config),
    {ok, Pid} = barrel_mcp:start_http_stream(#{port => Port}),
    ?assert(serves(Port)),
    exit(Pid, kill),
    wait_until(
        fun() ->
            case whereis(barrel_mcp_http_stream_listener) of
                undefined -> false;
                New -> New =/= Pid
            end
        end,
        5000
    ),
    New = whereis(barrel_mcp_http_stream_listener),
    ?assertNotEqual(undefined, New),
    ?assertNotEqual(Pid, New),
    %% And it is serving again, not merely alive.
    ?assert(serves(Port)),
    ok.

%% The listener used to outlive the application, holding the port with
%% nothing in the tree to stop it.
application_stop_releases_port(Config) ->
    Port = ?config(port, Config),
    {ok, Pid} = barrel_mcp:start_http_stream(#{port => Port}),
    ok = application:stop(barrel_mcp),
    wait_until(fun() -> not is_process_alive(Pid) end, 5000),
    ?assertNot(is_process_alive(Pid)),
    ?assertEqual(released, rebind(Port)),
    ok.

%% A transient child keeps its spec after a deliberate stop, so without
%% deleting it the same listener could never be started again.
stop_then_start_again(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port}),
    ok = barrel_mcp:stop_http_stream(),
    ?assertEqual(undefined, whereis(barrel_mcp_http_stream_listener)),
    ?assertMatch({ok, _}, barrel_mcp:start_http_stream(#{port => Port})),
    ?assert(serves(Port)),
    ok.

%% The engine can be driven with no application around it, so the
%% unsupervised listener has to keep working.
standalone_without_application(Config) ->
    Port = ?config(port, Config),
    ok = application:stop(barrel_mcp),
    timer:sleep(50),
    ?assertEqual(undefined, whereis(barrel_mcp_listener_sup)),
    {ok, Pid} = barrel_mcp:start_http_stream(#{port => Port}),
    ?assert(is_process_alive(Pid)),
    ok = barrel_mcp:stop_http_stream(),
    wait_until(fun() -> not is_process_alive(Pid) end, 5000),
    ?assertNot(is_process_alive(Pid)),
    ok.

%%====================================================================
%% The wire libraries own the connection
%%====================================================================

%% Two requests in one segment. The old owner loop served one request
%% at a time and threw the second envelope away.
pipelined_requests_are_all_answered(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port}),
    Req = raw_post(Port, discover_body(1), []),
    Req2 = raw_post(Port, discover_body(2), []),
    {ok, Sock} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Sock, [Req, Req2]),
    Reply = recv_until(Sock, fun(Acc) -> count(<<"HTTP/1.1 200">>, Acc) >= 2 end, 5000),
    gen_tcp:close(Sock),
    ?assertEqual(2, count(<<"HTTP/1.1 200">>, Reply)),
    ok.

%% A body over the cap is refused with 413, over both protocols.
body_over_cap_is_413(Config) ->
    Port = ?config(port, Config),
    Dir = ?config(priv_dir, Config),
    #{cacerts := CaCerts} = Tls = barrel_mcp_test_helpers:tls_files(Dir),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port, ssl => maps:without([cacerts], Tls), max_body_bytes => 1024
    }),
    Big = binary:copy(<<"x">>, 4096),
    {ok, S1} = ssl:connect("127.0.0.1", Port, tls_client_opts(CaCerts, <<"http/1.1">>), 5000),
    ok = ssl:send(S1, raw_post(Port, Big, [])),
    {ok, R1} = ssl:recv(S1, 0, 5000),
    ssl:close(S1),
    ?assertMatch(<<"HTTP/1.1 413", _/binary>>, R1),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => ssl, cacerts => CaCerts}),
    {ok, Sid} = h2:request(Conn, <<"POST">>, <<"/mcp">>, h2_headers(Port), Big),
    Status =
        receive
            {h2, Conn, {response, Sid, St, _}} -> St
        after 5000 -> timeout
        end,
    ok = h2:close(Conn),
    ?assertEqual(413, Status),
    ok.

%% `max_requests' bounds the requests in flight per listener. A held
%% stream occupies a slot; the next request is refused with 503 and
%% admitted again once the stream is gone.
max_requests_answers_503(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, max_requests => 1}),
    Listener = barrel_mcp_http_stream_listener,
    {200, H, _} = init_session(Port),
    Sid = proplists:get_value(<<"mcp-session-id">>, H),
    {ok, Stream} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Stream, [
        <<"GET /mcp HTTP/1.1\r\nhost: 127.0.0.1\r\naccept: text/event-stream\r\n">>,
        <<"mcp-session-id: ">>,
        Sid,
        <<"\r\n\r\n">>
    ]),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Stream, 0, 5000),
    ?assertEqual(1, barrel_mcp_http_listener:in_flight(Listener)),
    {ok, 503, Hdrs, _} = hackney:request(post, url(Port), json_headers(), discover_body(1), [
        with_body
    ]),
    ?assertEqual(<<"1">>, proplists:get_value(<<"retry-after">>, Hdrs)),
    ok = gen_tcp:close(Stream),
    wait_until(fun() -> barrel_mcp_http_listener:in_flight(Listener) =:= 0 end, 5000),
    {ok, 200, _, _} = hackney:request(post, url(Port), json_headers(), discover_body(2), [with_body]),
    ok.

%% Past `max_connections' the kernel still accepts, and we close.
max_connections_refuses_the_next_socket(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, max_connections => 1}),
    {ok, Held} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ok = gen_tcp:send(Held, raw_post(Port, discover_body(1), [])),
    {ok, <<"HTTP/1.1 200", _/binary>>} = gen_tcp:recv(Held, 0, 5000),
    {ok, Second} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000),
    ?assertEqual({error, closed}, gen_tcp:recv(Second, 0, 5000)),
    ok = gen_tcp:close(Held),
    wait_until(
        fun() ->
            case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000) of
                {ok, S} ->
                    ok = gen_tcp:send(S, raw_post(Port, discover_body(2), [])),
                    R = gen_tcp:recv(S, 0, 2000),
                    gen_tcp:close(S),
                    match =:=
                        (case R of
                            {ok, <<"HTTP/1.1 200", _/binary>>} -> match;
                            _ -> nomatch
                        end);
                _ ->
                    false
            end
        end,
        5000
    ),
    ok.

%% One TLS port, both protocols by ALPN.
tls_serves_http1_and_http2(Config) ->
    Port = ?config(port, Config),
    Dir = ?config(priv_dir, Config),
    #{cacerts := CaCerts} = Tls = barrel_mcp_test_helpers:tls_files(Dir),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, ssl => maps:without([cacerts], Tls)}),
    {ok, S1} = ssl:connect("127.0.0.1", Port, tls_client_opts(CaCerts, <<"http/1.1">>), 5000),
    ?assertEqual({ok, <<"http/1.1">>}, ssl:negotiated_protocol(S1)),
    ok = ssl:send(S1, raw_post(Port, discover_body(1), [])),
    {ok, R1} = ssl:recv(S1, 0, 5000),
    ssl:close(S1),
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, R1),
    {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => ssl, cacerts => CaCerts}),
    {ok, Sid} = h2:request(Conn, <<"POST">>, <<"/mcp">>, h2_headers(Port), discover_body(2)),
    receive
        {h2, Conn, {response, Sid, 200, _}} -> ok
    after 5000 -> ct:fail(no_h2_response)
    end,
    Body = h2_body(Conn, Sid, <<>>),
    ok = h2:close(Conn),
    ?assertMatch(#{<<"result">> := #{<<"protocolVersion">> := _}}, json:decode(Body)),
    ok.

%% "MUST treat a client disconnect as cancellation of that request"
%% (2026-07-28/basic/patterns/cancellation.mdx:38), over HTTP/2 too.
http2_disconnect_cancels_the_request(Config) ->
    Port = ?config(port, Config),
    Dir = ?config(priv_dir, Config),
    #{cacerts := CaCerts} = Tls = barrel_mcp_test_helpers:tls_files(Dir),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, ssl => maps:without([cacerts], Tls)}),
    Params = #{<<"name">> => <<"slow">>, <<"arguments">> => #{}},
    Body = iolist_to_binary(
        json:encode(barrel_mcp_test_helpers:modern_request(1, <<"tools/call">>, Params))
    ),
    Headers = h2_headers(Port) ++ barrel_mcp_headers:standard(<<"tools/call">>, Params),
    true = register(?WATCH, self()),
    try
        {ok, Conn} = h2:connect("127.0.0.1", Port, #{transport => ssl, cacerts => CaCerts}),
        {ok, _Sid} = h2:request(Conn, <<"POST">>, <<"/mcp">>, Headers, Body),
        ok = await_watch(started, 5000),
        ok = h2:close(Conn),
        ?assertEqual(timeout, await_watch(finished, 4000))
    after
        unregister(?WATCH)
    end,
    ok.

slow_tool(_Args) ->
    watch(started),
    timer:sleep(1500),
    watch(finished),
    <<"slow">>.

watch(Msg) ->
    case whereis(?WATCH) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end,
    ok.

await_watch(Msg, Timeout) ->
    receive
        Msg -> ok
    after Timeout -> timeout
    end.

%%====================================================================
%% Helpers
%%====================================================================

url(Port) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])).

json_headers() ->
    [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>}
    ].

discover_body(Id) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"server/discover">>
    }).

%% A legacy initialize, for a session the standalone GET can attach to.
init_session(Port) ->
    {ok, _} = application:ensure_all_started(hackney),
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{<<"name">> => <<"listener-suite">>, <<"version">> => <<"1">>}
        }
    }),
    {ok, S, H, B} = hackney:request(post, url(Port), json_headers(), Body, [with_body]),
    {S, H, B}.

raw_post(Port, Body0, ExtraHeaders) ->
    Body = iolist_to_binary(Body0),
    Headers =
        [
            {<<"host">>, iolist_to_binary(io_lib:format("127.0.0.1:~B", [Port]))},
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"content-length">>, integer_to_binary(byte_size(Body))}
        ] ++ ExtraHeaders,
    Lines = [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Headers],
    [<<"POST /mcp HTTP/1.1\r\n">>, Lines, <<"\r\n">>, Body].

recv_until(Sock, Done, Timeout) ->
    recv_until(Sock, Done, Timeout, <<>>).

recv_until(Sock, Done, Timeout, Acc) ->
    case Done(Acc) of
        true ->
            Acc;
        false ->
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, Data} -> recv_until(Sock, Done, Timeout, <<Acc/binary, Data/binary>>);
                {error, _} -> Acc
            end
    end.

count(Pattern, Bin) ->
    length(binary:matches(Bin, Pattern)).

tls_client_opts(CaCerts, Alpn) ->
    [
        binary,
        {active, false},
        {verify, verify_peer},
        {cacerts, CaCerts},
        {server_name_indication, disable},
        {alpn_advertised_protocols, [Alpn]}
    ].

h2_headers(Port) ->
    [
        {<<"host">>, iolist_to_binary(io_lib:format("127.0.0.1:~B", [Port]))},
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>}
    ].

h2_body(Conn, Sid, Acc) ->
    receive
        {h2, Conn, {data, Sid, Data, true}} -> <<Acc/binary, Data/binary>>;
        {h2, Conn, {data, Sid, Data, false}} -> h2_body(Conn, Sid, <<Acc/binary, Data/binary>>)
    after 5000 ->
        Acc
    end.

%% Prove the port is actually being served, not just that a process
%% holds the name.
serves(Port) ->
    {ok, _} = application:ensure_all_started(hackney),
    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])),
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"server/discover">>
    }),
    case
        hackney:request(
            post,
            Url,
            [
                {<<"content-type">>, <<"application/json">>},
                {<<"accept">>, <<"application/json, text/event-stream">>}
            ],
            Body,
            [with_body]
        )
    of
        {ok, 200, _, _} -> true;
        _ -> false
    end.

rebind(Port) ->
    case gen_tcp:listen(Port, [{reuseaddr, false}]) of
        {ok, S} ->
            gen_tcp:close(S),
            released;
        {error, Reason} ->
            Reason
    end.

%% An acceptor that dies used to leave the pool one short for the life
%% of the listener.
acceptor_is_replaced(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, acceptors => 2}),
    [A, B] = barrel_mcp_http_listener:acceptors(barrel_mcp_http_stream_listener),
    exit(A, kill),
    wait_until(
        fun() ->
            case barrel_mcp_http_listener:acceptors(barrel_mcp_http_stream_listener) of
                [_, _] = Pids ->
                    lists:member(B, Pids) andalso not lists:member(A, Pids) andalso
                        lists:all(fun is_process_alive/1, Pids);
                _ ->
                    false
            end
        end,
        5000
    ),
    ?assert(serves(Port)),
    ok.
