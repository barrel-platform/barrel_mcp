%%%-------------------------------------------------------------------
%%% @doc Integration suite for `barrel_mcp_client:notify_roots_list_changed/1'.
%%%
%%% Stands up a real Streamable HTTP server, configures the
%%% `roots_changed_handler' application env to forward inbound
%%% `notifications/roots/list_changed' to a test process, connects
%%% a client, calls the new emitter, and asserts the server-side
%%% handler observed the notification.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_roots_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([client_emits_roots_list_changed/1]).

%% Roots-changed handler exported for the application env hook.
-export([roots_changed/2]).

-define(BASE_PORT, 22580).

all() -> [client_emits_roots_list_changed].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    Config.

end_per_suite(_Config) ->
    try barrel_mcp:stop_http_stream() catch _:_ -> ok end,
    application:unset_env(barrel_mcp, roots_changed_handler),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(TC, Config) ->
    Port = ?BASE_PORT + erlang:phash2(TC, 100),
    [{port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    try barrel_mcp:stop_http_stream() catch _:_ -> ok end,
    application:unset_env(barrel_mcp, roots_changed_handler),
    timer:sleep(50),
    ok.

%%====================================================================
%% Test
%%====================================================================

client_emits_roots_list_changed(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                              session_enabled => true}),

    %% Forward inbound notifications/roots/list_changed to ourselves.
    Self = self(),
    register_observer(Self),
    application:set_env(barrel_mcp, roots_changed_handler,
                        {?MODULE, roots_changed}),

    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp",
                                          [Port])),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport => {http, Url}
    }),
    ok = wait_ready(Pid, 30),

    ok = barrel_mcp_client:notify_roots_list_changed(Pid),

    receive
        {roots_list_changed, _Params} -> ok
    after 5000 ->
        ct:fail("server did not observe notifications/roots/list_changed")
    end,

    barrel_mcp_client:close(Pid),
    unregister_observer(),
    ok.

%%====================================================================
%% roots_changed_handler hook
%%====================================================================

roots_changed(Params, _State) ->
    case observer() of
        undefined -> ok;
        Pid -> Pid ! {roots_list_changed, Params}, ok
    end.

%%====================================================================
%% Helpers
%%====================================================================

%% Stash the test pid in persistent_term so the application-env
%% callback can reach it without depending on registered names.
register_observer(Pid) ->
    persistent_term:put({?MODULE, observer}, Pid).

unregister_observer() ->
    try persistent_term:erase({?MODULE, observer}) catch _:_ -> ok end,
    ok.

observer() ->
    try persistent_term:get({?MODULE, observer})
    catch _:_ -> undefined
    end.

wait_ready(_Pid, 0) -> {error, not_ready};
wait_ready(Pid, N) ->
    case (try barrel_mcp_client:server_capabilities(Pid) catch _:_ -> error end) of
        {ok, _} -> ok;
        _ ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.
