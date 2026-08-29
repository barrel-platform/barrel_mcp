%%%-------------------------------------------------------------------
%%% @doc The legacy HTTP+SSE `endpoint' event must name the stream's
%%% own origin: the POST it directs carries the session's credential.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_http_tests).

-include_lib("eunit/include/eunit.hrl").

%% A test auth handle (see the flow tests at the end of this module).
-export([init/1, header/1, refresh/2, challenge/2]).

-define(A_PORT, 19298).
-define(B_PORT, 19299).
-define(TAB, client_http_tests_hits).

%%====================================================================
%% Pure URL resolution
%%====================================================================

same_origin_relative_path_test() ->
    ?assertEqual(
        {ok, <<"http://host/messages?s=1">>},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"/messages?s=1">>)
    ).

same_origin_absolute_test() ->
    ?assertEqual(
        {ok, <<"http://host/messages">>},
        barrel_mcp_client_http:same_origin_endpoint(
            <<"http://host/sse">>, <<"http://host/messages">>
        )
    ).

same_origin_default_port_http_test() ->
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"http://host:80/x">>)
    ),
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host:80/sse">>, <<"http://host/x">>)
    ).

same_origin_default_port_https_test() ->
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_http:same_origin_endpoint(
            <<"https://host/sse">>, <<"https://host:443/x">>
        )
    ).

same_origin_host_case_test() ->
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://Host/sse">>, <<"http://host/x">>)
    ).

cross_origin_scheme_relative_test() ->
    ?assertEqual(
        {error, {cross_origin, <<"http://other/x">>}},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"//other/x">>)
    ).

cross_origin_host_test() ->
    ?assertEqual(
        {error, {cross_origin, <<"http://other/x">>}},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"http://other/x">>)
    ).

cross_origin_scheme_test() ->
    ?assertEqual(
        {error, {cross_origin, <<"https://host/x">>}},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"https://host/x">>)
    ).

cross_origin_port_test() ->
    ?assertEqual(
        {error, {cross_origin, <<"http://host:8081/x">>}},
        barrel_mcp_client_http:same_origin_endpoint(
            <<"http://host:8080/sse">>, <<"http://host:8081/x">>
        )
    ).

bad_endpoint_test() ->
    ?assertEqual(
        {error, {bad_endpoint, <<"http://[">>}},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"http://[">>)
    ).

%%====================================================================
%% The transport against a stream naming another origin
%%====================================================================

endpoint_origin_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 30, [
            {"a cross-origin endpoint closes the transport and sends nothing",
                fun test_cross_origin_endpoint/0},
            {"a same-origin endpoint receives the queued POST", fun test_same_origin_endpoint/0}
        ]}}.

setup() ->
    {ok, _} = application:ensure_all_started(hackney),
    _ = ets:new(?TAB, [named_table, public, bag]),
    {ok, _} = barrel_mcp_test_http:start(legacy_a, ?A_PORT, fun handle_a/1),
    {ok, _} = barrel_mcp_test_http:start(legacy_b, ?B_PORT, fun handle_b/1),
    ok.

cleanup(_) ->
    [
        try
            barrel_mcp_test_http:stop(N)
        catch
            _:_ -> ok
        end
     || N <- [legacy_a, legacy_b]
    ],
    _ =
        try
            ets:delete(?TAB)
        catch
            _:_ -> ok
        end,
    ok.

url(Port, Path) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B~s", [Port, Path])).

%% Server A hosts only the 2024 pair: the Streamable probe is refused,
%% the stream names the endpoint the test installed.
handle_a(#{path := <<"/sse">>}) ->
    [{endpoint, Endpoint}] = ets:lookup(?TAB, endpoint),
    {200, #{<<"content-type">> => <<"text/event-stream">>},
        <<"event: endpoint\ndata: ", Endpoint/binary, "\n\n">>};
handle_a(#{path := Path} = Req) ->
    true = ets:insert(?TAB, {hit_a, Path, maps:get(method, Req, undefined)}),
    case Path of
        <<"/messages">> -> {202, #{}, <<>>};
        _ -> {404, #{<<"content-type">> => <<"text/plain">>}, <<"Not Found">>}
    end.

handle_b(#{path := Path}) ->
    true = ets:insert(?TAB, {hit_b, Path}),
    {202, #{}, <<>>}.

connect() ->
    barrel_mcp_client_http:connect(self(), #{
        url => url(?A_PORT, "/mcp"),
        legacy_sse_url => url(?A_PORT, "/sse"),
        open_event_stream => false
    }).

test_cross_origin_endpoint() ->
    ets:delete_all_objects(?TAB),
    Foreign = url(?B_PORT, "/messages"),
    true = ets:insert(?TAB, {endpoint, Foreign}),
    {ok, Pid} = connect(),
    ok = barrel_mcp_client_http:send(Pid, <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}">>),
    receive
        {mcp_closed, Pid, Reason} ->
            ?assertEqual({cross_origin, Foreign}, Reason)
    after 5000 ->
        error(no_close)
    end,
    timer:sleep(300),
    ?assertEqual([], ets:lookup(?TAB, hit_b)),
    barrel_mcp_client_http:close(Pid).

test_same_origin_endpoint() ->
    ets:delete_all_objects(?TAB),
    true = ets:insert(?TAB, {endpoint, <<"/messages">>}),
    {ok, Pid} = connect(),
    ok = barrel_mcp_client_http:send(Pid, <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}">>),
    wait_until(fun() -> [] =/= ets:match_object(?TAB, {hit_a, <<"/messages">>, '_'}) end, 5000),
    barrel_mcp_client_http:close(Pid).

wait_until(Fun, Timeout) when Timeout =< 0 ->
    Fun() orelse error(timeout);
wait_until(Fun, Timeout) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Timeout - 50)
    end.

%%====================================================================
%% Oversized and refused responses close the connection
%%====================================================================

overflow_test_() ->
    {setup, fun overflow_setup/0, fun overflow_cleanup/1,
        {timeout, 60, [
            {"an oversized JSON response closes the connection",
                {timeout, 30, fun test_oversized_json_response/0}},
            {"an oversized per-request SSE response closes the connection",
                {timeout, 30, fun test_oversized_request_stream/0}},
            {"an oversized standalone stream closes the connection",
                {timeout, 30, fun test_oversized_event_stream/0}},
            {"a refused standalone stream is closed, not pooled",
                {timeout, 30, fun test_refused_event_stream/0}}
        ]}}.

-define(RAW_PORT, 19300).

overflow_setup() ->
    {ok, _} = application:ensure_all_started(hackney),
    ok.

overflow_cleanup(_) ->
    ok.

%% A one-shot raw server: accepts one connection, reads the request
%% head, hands the socket to `Serve', then reports whether the peer
%% closed it. hackney's pool would keep a finished connection open,
%% so `tcp_closed' is the proof that the client called close.
raw_server(Serve) ->
    Test = self(),
    spawn_link(fun() ->
        {ok, L} = gen_tcp:listen(?RAW_PORT, [
            binary, {active, false}, {reuseaddr, true}, {packet, raw}
        ]),
        Test ! listening,
        {ok, S} = gen_tcp:accept(L, 10000),
        ok = gen_tcp:close(L),
        {ok, _Head} = gen_tcp:recv(S, 0, 5000),
        Serve(S),
        Test ! {peer, wait_closed(S, 10000)}
    end),
    receive
        listening -> ok
    after 5000 -> error(no_listener)
    end.

wait_closed(S, Timeout) ->
    inet:setopts(S, [{active, once}]),
    receive
        {tcp_closed, S} -> closed;
        {tcp_error, S, _} -> closed;
        {tcp, S, _} -> wait_closed(S, Timeout)
    after Timeout -> still_open
    end.

%% Writes until the peer goes away; a closed socket ends the loop.
pump(S, Chunk) ->
    case gen_tcp:send(S, Chunk) of
        ok -> pump(S, Chunk);
        {error, _} -> ok
    end.

peer_closed() ->
    receive
        {peer, Outcome} -> Outcome
    after 15000 -> error(no_peer_report)
    end.

expect_too_large(Pid) ->
    receive
        {mcp_closed, Pid, Got} -> ?assertMatch({response_too_large, N} when is_integer(N), Got)
    after 15000 -> error(no_close)
    end.

connect_raw(Opts) ->
    barrel_mcp_client_http:connect(
        self(),
        maps:merge(#{url => url(?RAW_PORT, "/mcp"), open_event_stream => false}, Opts)
    ).

test_oversized_json_response() ->
    raw_server(fun(S) ->
        ok = gen_tcp:send(S, [
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
            "transfer-encoding: chunked\r\n\r\n"
        ]),
        %% 64 KiB chunks, more than the 16 MiB cap can hold.
        Chunk = [io_lib:format("~.16b\r\n", [65536]), binary:copy(<<"x">>, 65536), "\r\n"],
        pump(S, iolist_to_binary(Chunk))
    end),
    {ok, Pid} = connect_raw(#{}),
    ok = barrel_mcp_client_http:send(Pid, <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}">>),
    expect_too_large(Pid),
    ?assertEqual(closed, peer_closed()),
    barrel_mcp_client_http:close(Pid).

test_oversized_request_stream() ->
    raw_server(fun(S) ->
        ok = gen_tcp:send(S, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
            "transfer-encoding: chunked\r\n\r\n"
        ]),
        %% A data line that never ends: the SSE buffer only grows.
        Chunk = [io_lib:format("~.16b\r\n", [65536]), binary:copy(<<"d">>, 65536), "\r\n"],
        pump(S, iolist_to_binary(Chunk))
    end),
    {ok, Pid} = connect_raw(#{}),
    ok = barrel_mcp_client_http:send(Pid, <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}">>),
    expect_too_large(Pid),
    ?assertEqual(closed, peer_closed()),
    barrel_mcp_client_http:close(Pid).

test_oversized_event_stream() ->
    raw_server(fun(S) ->
        ok = gen_tcp:send(S, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
            "transfer-encoding: chunked\r\n\r\n"
        ]),
        Chunk = [io_lib:format("~.16b\r\n", [65536]), binary:copy(<<"d">>, 65536), "\r\n"],
        pump(S, iolist_to_binary(Chunk))
    end),
    {ok, Pid} = connect_raw(#{open_event_stream => true}),
    ok = barrel_mcp_client_http:open_event_stream(Pid),
    expect_too_large(Pid),
    ?assertEqual(closed, peer_closed()),
    barrel_mcp_client_http:close(Pid).

test_refused_event_stream() ->
    raw_server(fun(S) ->
        ok = gen_tcp:send(S, [
            "HTTP/1.1 405 Method Not Allowed\r\ncontent-type: text/plain\r\n",
            "content-length: 2\r\n\r\nno"
        ])
    end),
    {ok, Pid} = connect_raw(#{open_event_stream => true}),
    ok = barrel_mcp_client_http:open_event_stream(Pid),
    ?assertEqual(closed, peer_closed()),
    barrel_mcp_client_http:close(Pid).

%%====================================================================
%% The authorization flow runs beside the transport, not inside it
%%====================================================================

%% A test auth handle: `challenge/2' asks the test process for the
%% answer and waits, which is what a person's consent step looks like
%% from the transport.

init(Ctl) -> {ok, #{ctl => Ctl, token => undefined}}.

header(#{token := undefined}) -> none;
header(#{token := T}) -> {ok, <<"Bearer ", T/binary>>}.

refresh(H, _Www) -> {ok, H}.

challenge(#{ctl := Ctl} = H, _Challenge) ->
    Ctl ! {challenge, self()},
    receive
        {token, T} -> {ok, H#{token => T}};
        crash -> exit(boom)
    end.

-define(AUTH_PORT, 19301).

auth_flow_test_() ->
    {setup, fun auth_setup/0, fun auth_cleanup/1,
        {timeout, 60, [
            {"one flow serves concurrent refusals and the transport stays live",
                {timeout, 30, fun test_single_flight/0}},
            {"a crashed flow fails the waiting requests", {timeout, 30, fun test_flow_crash/0}},
            {"close kills a running flow", {timeout, 30, fun test_close_kills_flow/0}},
            {"a request gives up after three rounds", {timeout, 30, fun test_retry_limit/0}},
            {"a DPoP nonce challenge is answered with a new proof, not a new token",
                {timeout, 30, fun test_rs_nonce/0}}
        ]}}.

auth_setup() ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, _} = barrel_mcp_test_http:start(auth_mcp, ?AUTH_PORT, fun handle_auth/1),
    ok.

auth_cleanup(_) ->
    try
        barrel_mcp_test_http:stop(auth_mcp)
    catch
        _:_ -> ok
    end,
    ok.

%% 200 with a JSON-RPC result for the right bearer, 401 otherwise. The
%% `always_401' token never satisfies it.
handle_auth(#{path := <<"/dpop">>} = Req) ->
    %% RFC 9449 9: a proof without the server's nonce is refused with
    %% the nonce to use; one carrying it is accepted.
    Proof = barrel_mcp_test_http:header(<<"dpop">>, Req),
    Nonce =
        case Proof of
            undefined -> undefined;
            _ -> maps:get(<<"nonce">>, proof_claims(Proof), undefined)
        end,
    case Nonce of
        <<"rs-1">> ->
            #{<<"id">> := Id} = json:decode(maps:get(body, Req)),
            {200, #{<<"content-type">> => <<"application/json">>},
                iolist_to_binary(json:encode(#{jsonrpc => <<"2.0">>, id => Id, result => #{}}))};
        _ ->
            {401,
                #{
                    <<"www-authenticate">> => <<"DPoP error=\"use_dpop_nonce\"">>,
                    <<"dpop-nonce">> => <<"rs-1">>
                },
                <<>>}
    end;
handle_auth(Req) ->
    case barrel_mcp_test_http:header(<<"authorization">>, Req) of
        <<"Bearer good">> ->
            #{<<"id">> := Id} = json:decode(maps:get(body, Req)),
            {200, #{<<"content-type">> => <<"application/json">>},
                iolist_to_binary(json:encode(#{jsonrpc => <<"2.0">>, id => Id, result => #{}}))};
        _ ->
            {401, #{<<"www-authenticate">> => <<"Bearer realm=\"mcp\"">>}, <<>>}
    end.

auth_connect() ->
    barrel_mcp_client_http:connect(self(), #{
        url => url(?AUTH_PORT, "/mcp"),
        open_event_stream => false,
        auth => {?MODULE, #{ctl => self(), token => undefined}}
    }).

request(Id) ->
    iolist_to_binary(json:encode(#{jsonrpc => <<"2.0">>, id => Id, method => <<"ping">>})).

next_challenge() ->
    receive
        {challenge, Worker} -> Worker
    after 5000 -> error(no_challenge)
    end.

next_in() ->
    receive
        {mcp_in, _, Body} -> maps:get(<<"id">>, json:decode(Body))
    after 5000 -> error(no_response)
    end.

test_single_flight() ->
    {ok, Pid} = auth_connect(),
    ok = barrel_mcp_client_http:send(Pid, request(1)),
    Worker = next_challenge(),
    %% Refused while the flow runs: queued, no second flow.
    ok = barrel_mcp_client_http:send(Pid, request(2)),
    %% The transport answers a call while the worker waits.
    ok = barrel_mcp_client_http:set_session_id(Pid, <<"s">>),
    ?assertEqual({error, badcall}, gen_server:call(Pid, nothing, 1000)),
    receive
        {challenge, _} -> error(second_flow_started)
    after 300 -> ok
    end,
    Worker ! {token, <<"good">>},
    Ids = lists:sort([next_in(), next_in()]),
    ?assertEqual([1, 2], Ids),
    barrel_mcp_client_http:close(Pid).

test_flow_crash() ->
    {ok, Pid} = auth_connect(),
    ok = barrel_mcp_client_http:send(Pid, request(1)),
    ok = barrel_mcp_client_http:send(Pid, request(2)),
    Worker = next_challenge(),
    Worker ! crash,
    receive
        {mcp_closed, Pid, {unauthorized, {auth_flow_crashed, boom}}} -> ok
    after 5000 -> error(no_close)
    end,
    barrel_mcp_client_http:close(Pid).

test_close_kills_flow() ->
    {ok, Pid} = auth_connect(),
    ok = barrel_mcp_client_http:send(Pid, request(1)),
    Worker = next_challenge(),
    Ref = monitor(process, Worker),
    barrel_mcp_client_http:close(Pid),
    receive
        {'DOWN', Ref, process, Worker, killed} -> ok
    after 5000 -> error(worker_survived)
    end.

test_retry_limit() ->
    {ok, Pid} = auth_connect(),
    ok = barrel_mcp_client_http:send(Pid, request(1)),
    %% A token the server never accepts: every round ends in 401.
    Rounds = [
        begin
            W = next_challenge(),
            W ! {token, <<"bad">>},
            round
        end
     || _ <- [1, 2, 3]
    ],
    ?assertEqual([round, round, round], Rounds),
    receive
        {mcp_closed, Pid, {unauthorized, retry_limit}} -> ok
    after 5000 -> error(no_limit)
    end,
    receive
        {challenge, _} -> error(fourth_round)
    after 300 -> ok
    end,
    barrel_mcp_client_http:close(Pid).

%%====================================================================
%% SEP-1699: a response stream cut short is resumed from its last event
%%====================================================================

resume_test_() ->
    {setup, fun overflow_setup/0, fun overflow_cleanup/1,
        {timeout, 60, [
            {"an unanswered stream is resumed with Last-Event-ID after retry",
                {timeout, 30, fun test_resume_after_retry/0}}
        ]}}.

-define(RESUME_PORT, 19302).

test_resume_after_retry() ->
    Test = self(),
    spawn_link(fun() ->
        {ok, L} = gen_tcp:listen(?RESUME_PORT, [
            binary, {active, false}, {reuseaddr, true}, {packet, raw}
        ]),
        Test ! listening,
        %% 1. The POST: prime the stream with an id and a retry, close it.
        {ok, S1} = gen_tcp:accept(L, 10000),
        {ok, _} = gen_tcp:recv(S1, 0, 5000),
        ok = gen_tcp:send(S1, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
            "transfer-encoding: chunked\r\n\r\n"
        ]),
        Prime =
            <<"id: event-7\nretry: 400\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{}}\n\n">>,
        ok = gen_tcp:send(S1, [
            io_lib:format("~.16b\r\n", [byte_size(Prime)]), Prime, "\r\n0\r\n\r\n"
        ]),
        Closed = erlang:monotonic_time(millisecond),
        ok = gen_tcp:close(S1),
        %% 2. The resumption GET: carries the id, arrives after the delay.
        {ok, S2} = gen_tcp:accept(L, 10000),
        Arrived = erlang:monotonic_time(millisecond),
        {ok, Head} = gen_tcp:recv(S2, 0, 5000),
        Test ! {resumed, Head, Arrived - Closed},
        Answer =
            <<"id: event-8\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resumed\":true}}\n\n">>,
        ok = gen_tcp:send(S2, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
            "transfer-encoding: chunked\r\n\r\n",
            io_lib:format("~.16b\r\n", [byte_size(Answer)]),
            Answer,
            "\r\n0\r\n\r\n"
        ]),
        ok = gen_tcp:close(S2),
        ok = gen_tcp:close(L)
    end),
    receive
        listening -> ok
    after 5000 -> error(no_listener)
    end,
    {ok, Pid} = barrel_mcp_client_http:connect(self(), #{
        url => url(?RESUME_PORT, "/mcp"), open_event_stream => false
    }),
    ok = barrel_mcp_client_http:send(Pid, request(1)),
    receive
        {resumed, Head, Elapsed} ->
            ?assertNotEqual(nomatch, binary:match(Head, <<"GET /mcp">>)),
            ?assertNotEqual(nomatch, binary:match(Head, <<"last-event-id: event-7">>)),
            ?assert(Elapsed >= 350)
    after 10000 -> error(no_resumption)
    end,
    ?assertEqual(1, next_response()),
    barrel_mcp_client_http:close(Pid).

%% The stream forwards notifications too; wait for the response.
next_response() ->
    receive
        {mcp_in, _, Body} ->
            case json:decode(Body) of
                #{<<"id">> := Id, <<"result">> := _} -> Id;
                _ -> next_response()
            end
    after 5000 -> error(no_response)
    end.

proof_claims(Jwt) ->
    [_, Payload | _] = binary:split(Jwt, <<".">>, [global]),
    json:decode(base64:decode(Payload, #{mode => urlsafe, padding => false})).

test_rs_nonce() ->
    Auth = barrel_mcp_client_auth:new({oauth, #{access_token => <<"bound">>, dpop => true}}),
    {ok, Pid} = barrel_mcp_client_http:connect(self(), #{
        url => url(?AUTH_PORT, "/dpop"), open_event_stream => false, auth => Auth
    }),
    ok = barrel_mcp_client_http:send(Pid, request(1)),
    ?assertEqual(1, next_in()),
    receive
        {challenge, _} -> error(flow_started)
    after 200 -> ok
    end,
    barrel_mcp_client_http:close(Pid).
