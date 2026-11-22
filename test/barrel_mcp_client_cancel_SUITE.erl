%%%-------------------------------------------------------------------
%%% @doc A request belongs to the process that made it: when that
%%% process exits mid-call, the client cancels the one request it was
%%% waiting on and leaves the connection to its other callers.
%%%
%%% Each case runs a real server, over stdio in a child OS process and
%%% over Streamable HTTP in this node, in both eras.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_cancel_SUITE).

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
    legacy_stdio_caller_exit_cancels_its_call/1,
    modern_stdio_caller_exit_cancels_its_call/1,
    legacy_http_caller_exit_cancels_its_call/1,
    modern_http_caller_exit_cancels_its_call/1,
    modern_http_caller_exit_always_reaches_the_tool/1,
    modern_http_cancel_always_reaches_the_tool/1
]).

-define(MODERN, <<"2026-07-28">>).
-define(LEGACY, <<"2025-11-25">>).
-define(BASE_PORT, 22900).
-define(TOKEN, <<"doomed">>).

all() ->
    [
        legacy_stdio_caller_exit_cancels_its_call,
        modern_stdio_caller_exit_cancels_its_call,
        legacy_http_caller_exit_cancels_its_call,
        modern_http_caller_exit_cancels_its_call,
        modern_http_caller_exit_always_reaches_the_tool,
        modern_http_cancel_always_reaches_the_tool
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"echo">>, barrel_mcp_stdio_child, echo_tool, #{}),
    ok = barrel_mcp:reg_tool(<<"waiting">>, barrel_mcp_stdio_child, waiting_tool, #{}),
    Config.

end_per_suite(_Config) ->
    barrel_mcp_registry:unreg(tool, <<"echo">>),
    barrel_mcp_registry:unreg(tool, <<"waiting">>),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(TC, Config) ->
    Dir = filename:join(?config(priv_dir, Config), atom_to_list(TC)),
    ok = filelib:ensure_path(Dir),
    [{dir, unicode:characters_to_binary(Dir)}, {port, port_of(TC)} | Config].

end_per_testcase(_TC, _Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    ok.

port_of(TC) ->
    barrel_mcp_test_helpers:case_port(?BASE_PORT, TC, all()).

%%====================================================================
%% Cases
%%====================================================================

%% "stdio: ... The client MUST send a notifications/cancelled
%% notification referencing the request ID"
%% (2026-07-28/basic/patterns/cancellation.mdx:42), and the handshake
%% era has no other signal on either transport.
legacy_stdio_caller_exit_cancels_its_call(Config) ->
    over_stdio(?LEGACY, Config, told).

modern_stdio_caller_exit_cancels_its_call(Config) ->
    over_stdio(?MODERN, Config, told).

legacy_http_caller_exit_cancels_its_call(Config) ->
    over_http(?LEGACY, Config, told).

%% "Streamable HTTP: Closing the SSE response stream is the cancellation
%% signal" (2026-07-28/basic/patterns/cancellation.mdx:39).
modern_http_caller_exit_cancels_its_call(Config) ->
    over_http(?MODERN, Config, told).

%% Closing the response stream has to reach the server at once,
%% whatever state the request is in, and must not hold up the client's
%% other requests. Without a progress token the server has sent nothing
%% yet when the cancel comes.
modern_http_caller_exit_always_reaches_the_tool(Config) ->
    repeatedly(Config, fun(_Client, Caller, _Id) -> exit(Caller, kill) end).

modern_http_cancel_always_reaches_the_tool(Config) ->
    repeatedly(Config, fun(Client, _Caller, Id) -> barrel_mcp_client:cancel(Client, Id) end).

repeatedly(Config, Cancel) ->
    Port = ?config(port, Config),
    Dir = ?config(dir, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port}),
    {ok, Client} = barrel_mcp_client:start(#{
        transport => {http, barrel_mcp_test_helpers:url(Port)},
        protocol_version => ?MODERN
    }),
    try
        wait_until(fun() -> is_ready(Client) end, 30000),
        {_, Missed} = lists:foldl(
            fun(N, {Seen, Acc}) ->
                Opts =
                    case N rem 2 of
                        0 -> #{};
                        1 -> #{progress_token => integer_to_binary(N)}
                    end,
                Caller = call_waiting(Client, Dir, 1500, Opts),
                [Id] = started(Dir, N) -- Seen,
                Cancel(Client, Caller, Id),
                T0 = erlang:monotonic_time(millisecond),
                {ok, _} = barrel_mcp_client:call_tool(Client, <<"echo">>, #{<<"input">> => <<"x">>}),
                ?assert(erlang:monotonic_time(millisecond) - T0 < 400),
                wait_until(fun() -> marked(Dir, "cancelled", Id) end, 400),
                case marked(Dir, "cancelled", Id) of
                    true -> {[Id | Seen], Acc};
                    false -> {[Id | Seen], [{N, Opts} | Acc]}
                end
            end,
            {[], []},
            lists:seq(1, 40)
        ),
        ?assertEqual([], Missed),
        ?assertEqual(#{}, pending(Client)),
        ?assertMatch(
            {ok, _}, barrel_mcp_client:call_tool(Client, <<"echo">>, #{<<"input">> => <<"x">>})
        )
    after
        try
            barrel_mcp_client:close(Client)
        catch
            _:_ -> ok
        end
    end.

%%====================================================================
%% The scenario
%%====================================================================

over_stdio(Version, Config, Expect) ->
    {ok, Client} = barrel_mcp_client:start(#{
        transport =>
            {stdio, #{
                command => barrel_mcp_test_helpers:erl_executable(),
                args => barrel_mcp_test_helpers:child_args(
                    barrel_mcp_stdio_child, start_cancellable
                )
            }},
        protocol_version => Version,
        %% A cold VM answers later than a server that is already up.
        probe_timeout => 30000,
        init_timeout => 30000
    }),
    run(Client, Config, Expect).

over_http(Version, Config, Expect) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, session_enabled => true}),
    {ok, Client} = barrel_mcp_client:start(#{
        transport => {http, barrel_mcp_test_helpers:url(Port)},
        protocol_version => Version
    }),
    run(Client, Config, Expect).

run(Client, Config, Expect) ->
    try
        wait_until(fun() -> is_ready(Client) end, 30000),
        ?assert(is_ready(Client)),
        caller_exit_cancels_its_call(Client, ?config(dir, Config), Expect)
    after
        try
            barrel_mcp_client:close(Client)
        catch
            _:_ -> ok
        end
    end.

%% Two callers share the client. One is killed mid-call; the other must
%% not notice.
caller_exit_cancels_its_call(Client, Dir, Expect) ->
    Doomed = call_waiting(Client, Dir, 1500, #{progress_token => ?TOKEN}),
    [DoomedId] = started(Dir, 1),
    Other = call_waiting(Client, Dir, 500, #{}),
    [OtherId] = started(Dir, 2) -- [DoomedId],
    ?assertEqual([DoomedId, OtherId], lists:sort(maps:keys(pending(Client)))),
    ?assertEqual(#{?TOKEN => Doomed}, progress(Client)),

    exit(Doomed, kill),

    %% Exactly that request is cancelled, and nothing of it is kept.
    wait_until(fun() -> not maps:is_key(DoomedId, pending(Client)) end, 2000),
    ?assertNot(maps:is_key(DoomedId, pending(Client))),
    ?assertEqual(#{}, progress(Client)),
    case Expect of
        told ->
            wait_until(fun() -> marked(Dir, "cancelled", DoomedId) end, 5000),
            ?assert(marked(Dir, "cancelled", DoomedId));
        stopped ->
            ok
    end,

    %% The other request in flight completes.
    receive
        {Other, Result} -> ?assertMatch({ok, #{<<"content">> := [_]}}, Result)
    after 10000 -> error(other_caller_never_answered)
    end,
    ?assert(marked(Dir, "finished", OtherId)),
    ?assertNot(marked(Dir, "cancelled", OtherId)),

    %% Past the time the cancelled call would have taken.
    wait_until(fun() -> marked(Dir, "finished", DoomedId) end, 2000),
    ?assertNot(marked(Dir, "finished", DoomedId)),

    ?assertEqual(#{}, pending(Client)),
    ?assertMatch(
        {ok, _}, barrel_mcp_client:call_tool(Client, <<"echo">>, #{<<"input">> => <<"x">>})
    ).

call_waiting(Client, Dir, Ms, Opts) ->
    Self = self(),
    spawn(fun() ->
        Args = #{<<"dir">> => Dir, <<"ms">> => Ms},
        Self ! {self(), barrel_mcp_client:call_tool(Client, <<"waiting">>, Args, Opts)}
    end).

%% The ids of the `N' calls the server has started, oldest first.
started(Dir, N) ->
    wait_until(fun() -> length(started_ids(Dir)) >= N end, 10000),
    Ids = started_ids(Dir),
    ?assertEqual(N, length(Ids)),
    Ids.

started_ids(Dir) ->
    lists:sort([
        list_to_integer(Id)
     || "started-" ++ Id <- filelib:wildcard("started-*", binary_to_list(Dir))
    ]).

marked(Dir, Step, Id) ->
    barrel_mcp_stdio_child:marked(Dir, Step, Id).

%% The client's own bookkeeping, and proof it is still `ready'. Fields
%% 5 and 10 of its state record are `pending' and `progress'.
pending(Client) ->
    {ready, Data} = sys:get_state(Client),
    element(5, Data).

progress(Client) ->
    {ready, Data} = sys:get_state(Client),
    element(10, Data).

is_ready(Client) ->
    try barrel_mcp_client:protocol_version(Client) of
        {ok, V} when is_binary(V) -> true;
        _ -> false
    catch
        _:_ -> false
    end.
