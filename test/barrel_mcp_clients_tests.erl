%%%-------------------------------------------------------------------
%%% @doc Tests for the `barrel_mcp_clients' federation registry.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_clients_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PORT, 19292).
-define(URL, <<"http://127.0.0.1:19292/mcp">>).

federation_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     {timeout, 30, [
         {"start_client registers and returns a pid", fun test_start/0},
         {"duplicate registration is rejected", fun test_dup/0},
         {"stop_client removes the entry", fun test_stop/0},
         {"crash auto-removes the entry", fun test_crash/0}
     ]}}.

setup() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    {ok, _} = barrel_mcp_http_stream:start(#{port => ?PORT, session_enabled => true}),
    timer:sleep(150),
    ok.

cleanup(_) ->
    catch barrel_mcp_http_stream:stop(),
    [catch barrel_mcp:stop_client(Id) || {Id, _} <- barrel_mcp:list_clients()],
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
    ?assertMatch({error, {already_registered, _}},
                 barrel_mcp:start_client(<<"b">>, Spec)),
    barrel_mcp:stop_client(<<"b">>).

test_stop() ->
    Spec = client_spec(),
    {ok, _} = barrel_mcp:start_client(<<"c">>, Spec),
    ok = barrel_mcp:stop_client(<<"c">>),
    timer:sleep(100),
    ?assertEqual(undefined, barrel_mcp:whereis_client(<<"c">>)).

test_crash() ->
    Spec = client_spec(),
    {ok, Pid} = barrel_mcp:start_client(<<"d">>, Spec),
    exit(Pid, kill),
    %% Allow the registry's monitor to fire.
    wait_until_undefined(<<"d">>, 30).

%%====================================================================
%% Helpers
%%====================================================================

client_spec() ->
    #{transport => {http, ?URL},
      handler => {barrel_mcp_client_handler_default, []}}.

wait_until_undefined(_Id, 0) -> error(still_registered);
wait_until_undefined(Id, N) ->
    case barrel_mcp:whereis_client(Id) of
        undefined -> ok;
        _ ->
            timer:sleep(50),
            wait_until_undefined(Id, N - 1)
    end.
