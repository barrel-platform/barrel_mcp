%%%-------------------------------------------------------------------
%%% @doc The stdio transport, driven over a fake stdin/stdout.
%%%
%%% One channel carries every request, every cancellation and every
%%% notification, so what matters here is that a slow tool cannot stop
%%% the rest of them arriving.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_stdio_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    answers_a_request/1,
    slow_calls_run_concurrently/1,
    cancelling_a_running_request_answers_nothing/1,
    cancelling_a_queued_request_answers_nothing/1,
    duplicate_id_is_refused/1,
    overload_is_refused/1,
    unmatched_response_is_dropped/1,
    notifications_are_never_answered/1,
    oversized_frame_closes_the_server/1,
    subscriptions_are_served/1,
    legacy_subscribe_is_served/1,
    eof_stops_the_server/1,
    client_subscribes_over_real_stdio/1
]).

-export([echo_tool/1, slow_tool/1, a_tool/1, a_resource/1]).

-define(MODERN, <<"2026-07-28">>).
-define(LEGACY, <<"2025-11-25">>).
-define(WATCHED, <<"file:///watched">>).

all() ->
    [
        answers_a_request,
        slow_calls_run_concurrently,
        cancelling_a_running_request_answers_nothing,
        cancelling_a_queued_request_answers_nothing,
        duplicate_id_is_refused,
        overload_is_refused,
        unmatched_response_is_dropped,
        notifications_are_never_answered,
        oversized_frame_closes_the_server,
        subscriptions_are_served,
        legacy_subscribe_is_served,
        eof_stops_the_server,
        client_subscribes_over_real_stdio
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echoes its input">>
    }),
    ok = barrel_mcp:reg_tool(<<"slow">>, ?MODULE, slow_tool, #{
        description => <<"Sleeps, then answers">>
    }),
    Config.

end_per_suite(_Config) ->
    barrel_mcp_registry:unreg(tool, <<"echo">>),
    barrel_mcp_registry:unreg(tool, <<"slow">>),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    application:unset_env(barrel_mcp, stdio_max_workers),
    application:unset_env(barrel_mcp, stdio_max_queue),
    application:unset_env(barrel_mcp, stdio_max_frame_bytes),
    ok.

echo_tool(Args) ->
    <<"Echo: ", (maps:get(<<"input">>, Args, <<"none">>))/binary>>.

slow_tool(Args) ->
    timer:sleep(maps:get(<<"ms">>, Args, 400)),
    <<"slept">>.

a_tool(_Args) -> <<"ok">>.

a_resource(_Args) -> <<"body">>.

%%====================================================================
%% Cases
%%====================================================================

answers_a_request(_Config) ->
    {Dev, Server} = start_server(),
    send(Dev, request(1, <<"tools/call">>, call(<<"echo">>, #{<<"input">> => <<"hi">>}))),
    Response = barrel_mcp_stdio_io:next_line(Dev),
    ?assertEqual(1, maps:get(<<"id">>, Response)),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Response)),
    ?assertEqual(<<"Echo: hi">>, maps:get(<<"text">>, Block)),
    stop_server(Dev, Server).

%% The point of the rewrite: two calls that each take 400ms finish in
%% well under 800ms, and a request behind a slow one is not stuck.
slow_calls_run_concurrently(_Config) ->
    {Dev, Server} = start_server(),
    Started = erlang:monotonic_time(millisecond),
    send(Dev, request(1, <<"tools/call">>, call(<<"slow">>, #{<<"ms">> => 400}))),
    send(Dev, request(2, <<"tools/call">>, call(<<"slow">>, #{<<"ms">> => 400}))),
    send(Dev, request(3, <<"tools/call">>, call(<<"echo">>, #{<<"input">> => <<"fast">>}))),
    Ids = collect_ids(Dev, 3),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertEqual([1, 2, 3], lists:sort(Ids)),
    ?assert(Elapsed < 700),
    stop_server(Dev, Server).

%% "Servers receiving cancellation notifications SHOULD ... not send a
%% response for the cancelled request"
%% (2026-07-28/basic/patterns/cancellation.mdx:70).
cancelling_a_running_request_answers_nothing(_Config) ->
    {Dev, Server} = start_server(),
    send(Dev, request(1, <<"tools/call">>, call(<<"slow">>, #{<<"ms">> => 3000}))),
    timer:sleep(150),
    send(Dev, cancelled(1)),
    ?assertEqual(ok, barrel_mcp_stdio_io:silent(Dev, 1000)),
    %% Still serving: the cancellation took one request, not the channel.
    send(Dev, request(2, <<"tools/call">>, call(<<"echo">>, #{<<"input">> => <<"ok">>}))),
    ?assertEqual(2, maps:get(<<"id">>, barrel_mcp_stdio_io:next_line(Dev))),
    stop_server(Dev, Server).

%% A queued request has not started, so cancelling it must not later
%% produce an answer when a slot frees up.
cancelling_a_queued_request_answers_nothing(_Config) ->
    application:set_env(barrel_mcp, stdio_max_workers, 1),
    {Dev, Server} = start_server(),
    send(Dev, request(1, <<"tools/call">>, call(<<"slow">>, #{<<"ms">> => 400}))),
    send(Dev, request(2, <<"tools/call">>, call(<<"echo">>, #{<<"input">> => <<"queued">>}))),
    send(Dev, cancelled(2)),
    ?assertEqual(1, maps:get(<<"id">>, barrel_mcp_stdio_io:next_line(Dev))),
    ?assertEqual(ok, barrel_mcp_stdio_io:silent(Dev, 500)),
    stop_server(Dev, Server).

duplicate_id_is_refused(_Config) ->
    {Dev, Server} = start_server(),
    send(Dev, request(1, <<"tools/call">>, call(<<"slow">>, #{<<"ms">> => 400}))),
    send(Dev, request(1, <<"tools/call">>, call(<<"echo">>, #{<<"input">> => <<"dup">>}))),
    Refusal = barrel_mcp_stdio_io:next_line(Dev),
    ?assertEqual(1, maps:get(<<"id">>, Refusal)),
    ?assertEqual(-32600, maps:get(<<"code">>, maps:get(<<"error">>, Refusal))),
    stop_server(Dev, Server).

overload_is_refused(_Config) ->
    application:set_env(barrel_mcp, stdio_max_workers, 1),
    application:set_env(barrel_mcp, stdio_max_queue, 1),
    {Dev, Server} = start_server(),
    send(Dev, request(1, <<"tools/call">>, call(<<"slow">>, #{<<"ms">> => 600}))),
    send(Dev, request(2, <<"tools/call">>, call(<<"slow">>, #{<<"ms">> => 600}))),
    send(Dev, request(3, <<"tools/call">>, call(<<"slow">>, #{<<"ms">> => 600}))),
    Refusal = barrel_mcp_stdio_io:next_line(Dev),
    ?assertEqual(3, maps:get(<<"id">>, Refusal)),
    ?assertEqual(-32603, maps:get(<<"code">>, maps:get(<<"error">>, Refusal))),
    stop_server(Dev, Server).

%% We issue no outbound requests, so a response matches nothing.
%% Answering it would risk trading errors with the peer forever.
unmatched_response_is_dropped(_Config) ->
    {Dev, Server} = start_server(),
    send(Dev, #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 99, <<"result">> => #{}}),
    ?assertEqual(ok, barrel_mcp_stdio_io:silent(Dev, 300)),
    stop_server(Dev, Server).

notifications_are_never_answered(_Config) ->
    {Dev, Server} = start_server(),
    send(Dev, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/initialized">>,
        <<"params">> => #{}
    }),
    %% Malformed, and still a notification: JSON-RPC forbids a reply.
    send(Dev, #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => 42}),
    ?assertEqual(ok, barrel_mcp_stdio_io:silent(Dev, 300)),
    stop_server(Dev, Server).

oversized_frame_closes_the_server(_Config) ->
    application:set_env(barrel_mcp, stdio_max_frame_bytes, 512),
    {Dev, Server} = start_server(),
    MRef = monitor(process, Server),
    barrel_mcp_stdio_io:feed(Dev, [binary:copy(<<"x">>, 4096), <<"\n">>]),
    Response = barrel_mcp_stdio_io:next_line(Dev),
    ?assertEqual(-32600, maps:get(<<"code">>, maps:get(<<"error">>, Response))),
    receive
        {'DOWN', MRef, process, Server, _} -> ok
    after 5000 -> error(server_stayed_up)
    end,
    barrel_mcp_stdio_io:stop(Dev).

%% stdio holds one long-lived channel, so it can serve a response
%% stream. The subscription's notifications share stdout with
%% everything else and are demultiplexed by their subscription id.
subscriptions_are_served(_Config) ->
    {Dev, Server} = start_server(),
    send(
        Dev,
        request(7, <<"subscriptions/listen">>, #{
            <<"notifications">> => #{<<"toolsListChanged">> => true}
        })
    ),
    Ack = barrel_mcp_stdio_io:next_line(Dev),
    ?assertEqual(
        <<"notifications/subscriptions/acknowledged">>,
        maps:get(<<"method">>, Ack)
    ),
    ?assertEqual(7, subscription_id(Ack)),
    ok = barrel_mcp:reg_tool(<<"late">>, ?MODULE, a_tool, #{}),
    try
        Note = barrel_mcp_stdio_io:next_line(Dev),
        ?assertEqual(<<"notifications/tools/list_changed">>, maps:get(<<"method">>, Note)),
        ?assertEqual(7, subscription_id(Note))
    after
        barrel_mcp_registry:unreg(tool, <<"late">>)
    end,
    stop_server(Dev, Server),
    %% The subscription went with the connection.
    wait_until(fun() -> barrel_mcp_subscriptions:count() =:= 0 end, 5000),
    ?assertEqual(0, barrel_mcp_subscriptions:count()).

%% `resources/subscribe' needs a session, and stdio has exactly one.
%% The capability is advertised on every handshake revision, so a client
%% that subscribes has to get the update.
legacy_subscribe_is_served(_Config) ->
    ok = barrel_mcp:reg_resource(<<"watched">>, ?MODULE, a_resource, #{uri => ?WATCHED}),
    {Dev, Server} = start_server(),
    try
        send(Dev, legacy_request(1, <<"initialize">>, initialize_params())),
        Init = barrel_mcp_stdio_io:next_line(Dev),
        ?assertEqual(?LEGACY, maps:get(<<"protocolVersion">>, maps:get(<<"result">>, Init))),

        send(Dev, legacy_request(2, <<"resources/subscribe">>, #{<<"uri">> => ?WATCHED})),
        ?assertMatch(#{<<"id">> := 2, <<"result">> := _}, barrel_mcp_stdio_io:next_line(Dev)),

        ok = barrel_mcp:notify_resource_updated(?WATCHED),
        Note = barrel_mcp_stdio_io:next_line(Dev),
        ?assertEqual(<<"notifications/resources/updated">>, maps:get(<<"method">>, Note)),
        ?assertEqual(?WATCHED, maps:get(<<"uri">>, maps:get(<<"params">>, Note))),

        send(Dev, legacy_request(3, <<"resources/unsubscribe">>, #{<<"uri">> => ?WATCHED})),
        ?assertMatch(#{<<"id">> := 3, <<"result">> := _}, barrel_mcp_stdio_io:next_line(Dev)),
        ok = barrel_mcp:notify_resource_updated(?WATCHED),
        ?assertEqual(timeout, barrel_mcp_stdio_io:next_line(Dev))
    after
        stop_server(Dev, Server),
        barrel_mcp_registry:unreg(resource, <<"watched">>)
    end.

eof_stops_the_server(_Config) ->
    {Dev, Server} = start_server(),
    MRef = monitor(process, Server),
    barrel_mcp_stdio_io:close(Dev),
    receive
        {'DOWN', MRef, process, Server, _} -> ok
    after 5000 -> error(server_stayed_up)
    end,
    barrel_mcp_stdio_io:stop(Dev).

%% Both ends over a real pipe, in a child OS process. The fake device
%% cannot show that the reader frames an actual stream, and it was
%% hiding a reader that only delivered a frame at EOF.
client_subscribes_over_real_stdio(_Config) ->
    {ok, Client} = barrel_mcp_client:start(#{
        transport => {stdio, #{command => erl_executable(), args => child_args()}},
        protocol_version => ?MODERN,
        %% A cold VM plus the application answers later than a server
        %% that is already up.
        probe_timeout => 30000
    }),
    try
        wait_until(fun() -> is_ready(Client) end, 30000),
        ?assertEqual({ok, ?MODERN}, barrel_mcp_client:protocol_version(Client)),

        {ok, Tools} = barrel_mcp_client:list_tools(Client),
        ?assert(lists:member(<<"echo">>, [maps:get(<<"name">>, T) || T <- Tools])),

        {ok, _} = barrel_mcp_client:subscribe(Client, <<"file:///watched">>),
        %% The tool runs on the server and makes it emit the update, so
        %% the notification and this call's response share one channel.
        {ok, _} = barrel_mcp_client:call_tool(Client, <<"touch">>, #{}),
        receive
            {mcp_resource_updated, <<"file:///watched">>, _} -> ok
        after 15000 -> error(no_resource_update)
        end,

        {ok, _} = barrel_mcp_client:unsubscribe(Client, <<"file:///watched">>),
        {ok, Result} = barrel_mcp_client:call_tool(
            Client, <<"echo">>, #{<<"input">> => <<"after">>}
        ),
        [Block] = maps:get(<<"content">>, Result),
        ?assertEqual(<<"Echo: after">>, maps:get(<<"text">>, Block))
    after
        try
            barrel_mcp_client:close(Client)
        catch
            _:_ -> ok
        end
    end.

erl_executable() ->
    filename:join([code:root_dir(), "bin", "erl"]).

%% Logging has to go to stderr: the default handler writes stdout, which
%% is the wire. The paths are reversed because each `-pa' prepends, so
%% feeding them in order would leave the child searching this node's
%% path backwards and picking up whichever profile was listed last.
child_args() ->
    Dirs = lists:reverse([D || D <- code:get_path(), filelib:is_dir(D)]),
    Paths = lists:append([["-pa", D] || D <- Dirs]),
    [
        "-noshell",
        "-boot",
        "no_dot_erlang",
        "-kernel",
        "logger",
        "[{handler,default,logger_std_h,#{config=>#{type=>standard_error}}}]"
    ] ++ Paths ++
        ["-eval", "barrel_mcp_stdio_child:start()"].

is_ready(Pid) ->
    try barrel_mcp_client:protocol_version(Pid) of
        {ok, V} when is_binary(V) -> true;
        _ -> false
    catch
        _:_ -> false
    end.

%%====================================================================
%% Helpers
%%====================================================================

%% The group leader is what `standard_io' resolves to, so setting it on
%% the starter makes the whole transport read and write the fake device.
start_server() ->
    Dev = barrel_mcp_stdio_io:start(),
    Caller = self(),
    Starter = spawn(fun() ->
        group_leader(Dev, self()),
        {ok, Pid} = gen_server:start(barrel_mcp_stdio, [], []),
        Caller ! {started, Pid},
        receive
            stop -> ok
        end
    end),
    Server =
        receive
            {started, Pid} -> Pid
        after 5000 -> error(server_never_started)
        end,
    put(starter, Starter),
    {Dev, Server}.

stop_server(Dev, Server) ->
    MRef = monitor(process, Server),
    barrel_mcp_stdio_io:close(Dev),
    receive
        {'DOWN', MRef, process, Server, _} -> ok
    after 5000 -> exit(Server, kill)
    end,
    case get(starter) of
        undefined -> ok;
        Starter -> Starter ! stop
    end,
    barrel_mcp_stdio_io:stop(Dev),
    ok.

send(Dev, Envelope) ->
    barrel_mcp_stdio_io:feed(Dev, [json:encode(Envelope), <<"\n">>]).

request(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => modern_meta()}
    }.

%% No `_meta' protocol stamp: the era comes from the handshake instead.
legacy_request(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }.

initialize_params() ->
    #{
        <<"protocolVersion">> => ?LEGACY,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"ct">>, <<"version">> => <<"0">>}
    }.

cancelled(Id) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/cancelled">>,
        <<"params">> => #{<<"requestId">> => Id}
    }.

call(Name, Args) ->
    #{<<"name">> => Name, <<"arguments">> => Args}.

modern_meta() ->
    #{
        ?MCP_META_PROTOCOL_VERSION => ?MODERN,
        ?MCP_META_CLIENT_CAPABILITIES => #{}
    }.

subscription_id(Envelope) ->
    Params = maps:get(<<"params">>, Envelope, #{}),
    maps:get(?MCP_META_SUBSCRIPTION_ID, maps:get(<<"_meta">>, Params, #{})).

collect_ids(Dev, N) ->
    collect_ids(Dev, N, []).

collect_ids(_Dev, 0, Acc) ->
    Acc;
collect_ids(Dev, N, Acc) ->
    case barrel_mcp_stdio_io:next_line(Dev) of
        timeout -> error({missing_responses, N, Acc});
        Response -> collect_ids(Dev, N - 1, [maps:get(<<"id">>, Response) | Acc])
    end.

wait_until(_Fun, Remaining) when Remaining =< 0 ->
    ok;
wait_until(Fun, Remaining) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Remaining - 50)
    end.
