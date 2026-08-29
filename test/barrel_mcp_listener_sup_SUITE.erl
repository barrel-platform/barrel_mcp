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
    standalone_without_application/1
]).

-define(BASE_PORT, 21800).

all() ->
    [
        listener_is_supervised,
        restarts_after_crash,
        acceptor_is_replaced,
        application_stop_releases_port,
        stop_then_start_again,
        standalone_without_application
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TC, Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    [{port, ?BASE_PORT + case_index(TC)} | Config].

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
%% Helpers
%%====================================================================

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

%% A port per case, by position rather than by hash: two case names
%% hashing to the same slot means the second one gets eaddrinuse while
%% the first listener is still releasing its socket.
case_index(TC) ->
    case_index(TC, all(), 0).

case_index(TC, [TC | _], N) -> N;
case_index(TC, [_ | Rest], N) -> case_index(TC, Rest, N + 1);
case_index(_TC, [], N) -> N.

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
