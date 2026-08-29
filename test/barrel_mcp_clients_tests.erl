%%%-------------------------------------------------------------------
%%% @doc Tests for the `barrel_mcp_clients' federation registry.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_clients_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PORT, 19292).
-define(URL, <<"http://127.0.0.1:19292/mcp">>).

federation_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 30, [
            {"start_client registers and returns a pid", fun test_start/0},
            {"duplicate registration is rejected", fun test_dup/0},
            {"stop_client removes the entry", fun test_stop/0},
            {"a crashed client is restarted under its id", fun test_crash/0},
            {"a normal exit frees the id", fun test_normal_exit/0},
            {"the restart window is visible and stoppable", fun test_restart_window/0}
        ]}}.

setup() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    {ok, _} = barrel_mcp_http_stream:start(#{port => ?PORT, session_enabled => true}),
    timer:sleep(150),
    ok.

cleanup(_) ->
    try
        barrel_mcp_http_stream:stop()
    catch
        _:_ -> ok
    end,
    barrel_mcp_test_refusing_handler:refuse(false),
    [
        try
            barrel_mcp:stop_client(Id)
        catch
            _:_ -> ok
        end
     || {Id, _} <- barrel_mcp:list_clients()
    ],
    ok.

test_start() ->
    Spec = client_spec(),
    {ok, Pid} = barrel_mcp:start_client(<<"a">>, Spec),
    ?assert(is_pid(Pid)),
    ?assertEqual(Pid, barrel_mcp:whereis_client(<<"a">>)),
    ?assert(lists:keymember(<<"a">>, 1, barrel_mcp:list_clients())),
    barrel_mcp:stop_client(<<"a">>).

test_dup() ->
    Spec = client_spec(),
    {ok, _} = barrel_mcp:start_client(<<"b">>, Spec),
    ?assertMatch(
        {error, {already_registered, _}},
        barrel_mcp:start_client(<<"b">>, Spec)
    ),
    barrel_mcp:stop_client(<<"b">>).

test_stop() ->
    Spec = client_spec(),
    {ok, _} = barrel_mcp:start_client(<<"c">>, Spec),
    ok = barrel_mcp:stop_client(<<"c">>),
    ?assertEqual(undefined, barrel_mcp:whereis_client(<<"c">>)),
    ?assertEqual({error, not_found}, barrel_mcp:stop_client(<<"c">>)).

test_crash() ->
    Spec = client_spec(),
    {ok, Pid} = barrel_mcp:start_client(<<"d">>, Spec),
    exit(Pid, kill),
    NewPid = wait_for_pid(<<"d">>, Pid, 30),
    ?assert(is_process_alive(NewPid)),
    ?assertEqual(
        {error, {already_registered, NewPid}},
        barrel_mcp:start_client(<<"d">>, Spec)
    ),
    ok = barrel_mcp:stop_client(<<"d">>).

test_normal_exit() ->
    Spec = client_spec(),
    {ok, Pid} = barrel_mcp:start_client(<<"e">>, Spec),
    ok = barrel_mcp_client:close(Pid),
    wait_until_undefined(<<"e">>, 30),
    {ok, Pid2} = barrel_mcp:start_client(<<"e">>, Spec),
    ?assertNotEqual(Pid, Pid2),
    ok = barrel_mcp:stop_client(<<"e">>).

test_restart_window() ->
    Spec = (client_spec())#{handler => {barrel_mcp_test_refusing_handler, []}},
    barrel_mcp_test_refusing_handler:refuse(false),
    {ok, Pid} = barrel_mcp:start_client(<<"f">>, Spec),
    barrel_mcp_test_refusing_handler:refuse(true),
    exit(Pid, kill),
    wait_until_undefined(<<"f">>, 30),
    ?assertEqual({error, {restarting, <<"f">>}}, barrel_mcp:start_client(<<"f">>, Spec)),
    ?assertEqual(undefined, barrel_mcp:whereis_client(<<"f">>)),
    ?assertNot(lists:keymember(<<"f">>, 1, barrel_mcp:list_clients())),
    ok = barrel_mcp:stop_client(<<"f">>),
    barrel_mcp_test_refusing_handler:refuse(false),
    ?assertEqual({error, not_found}, barrel_mcp:stop_client(<<"f">>)),
    {ok, _} = barrel_mcp:start_client(<<"f">>, Spec),
    ok = barrel_mcp:stop_client(<<"f">>).

%%====================================================================
%% Helpers
%%====================================================================

client_spec() ->
    #{
        transport => {http, ?URL},
        handler => {barrel_mcp_client_handler_default, []}
    }.

wait_until_undefined(_Id, 0) ->
    error(still_registered);
wait_until_undefined(Id, N) ->
    case barrel_mcp:whereis_client(Id) of
        undefined ->
            ok;
        _ ->
            timer:sleep(50),
            wait_until_undefined(Id, N - 1)
    end.

wait_for_pid(_Id, _Old, 0) ->
    error(not_restarted);
wait_for_pid(Id, Old, N) ->
    case barrel_mcp:whereis_client(Id) of
        Pid when is_pid(Pid), Pid =/= Old ->
            Pid;
        _ ->
            timer:sleep(50),
            wait_for_pid(Id, Old, N - 1)
    end.
