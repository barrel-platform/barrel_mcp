%%%-------------------------------------------------------------------
%%% @doc Tests for client-side ping cadence and progress map cleanup.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_progress_tests).

-include_lib("eunit/include/eunit.hrl").

-import(barrel_mcp_test_helpers, [wait_ready/2, wait_until/2]).

-export([slow_handler/1]).

%% Where the parked tool reports in and waits for its release.
-define(GATE, barrel_mcp_progress_gate).
-define(PORT, 19393).
-define(URL, <<"http://127.0.0.1:19393/mcp">>).

ping_test_() ->
    {setup, fun setup_loopback/0, fun cleanup_loopback/1,
        {timeout, 30, [
            {"ping cadence keeps the client alive against a live server",
                fun test_ping_keeps_alive/0},
            {"no ping is sent when ping_interval is left as default (infinity)",
                fun test_ping_disabled_by_default/0},
            {"progress_token registers in client state and clears on settle",
                fun test_progress_lifecycle/0}
        ]}}.

setup_loopback() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    {ok, _} = barrel_mcp_http_stream:start(#{port => ?PORT, session_enabled => true}),
    timer:sleep(150),
    ok.

cleanup_loopback(_) ->
    try
        barrel_mcp_http_stream:stop()
    catch
        _:_ -> ok
    end,
    ok.

test_ping_keeps_alive() ->
    {ok, Pid} = start_client(#{ping_interval => 100}),
    Before = request_id(Pid),
    %% Wait for pings to be sent rather than sleeping past a cadence:
    %% every outbound request, ping included, consumes an id.
    wait_until(fun() -> request_id(Pid) >= Before + 3 end, 5000),
    ?assert(request_id(Pid) >= Before + 3),
    ?assert(is_process_alive(Pid)),
    %% A regular request still works while pings interleave.
    {ok, _} = barrel_mcp_client:server_info(Pid),
    barrel_mcp_client:close(Pid).

test_ping_disabled_by_default() ->
    {ok, Pid} = start_client(#{}),
    Before = request_id(Pid),
    %% Proving a negative needs a window. Nothing may consume an id in
    %% it; load can only make a stray ping more likely to be caught.
    timer:sleep(300),
    ?assertEqual(Before, request_id(Pid)),
    ?assert(is_process_alive(Pid)),
    barrel_mcp_client:close(Pid).

test_progress_lifecycle() ->
    %% Register a slow tool that lets us see the progress entry while
    %% the request is still in flight.
    ok = barrel_mcp_registry:reg(tool, <<"slow">>, ?MODULE, slow_handler, #{}),
    {ok, Pid} = start_client(#{}),
    Self = self(),
    Tok = <<"prog-lifecycle-1">>,
    true = register(?GATE, self()),
    Caller = spawn_link(fun() ->
        Res = barrel_mcp_client:call_tool(
            Pid,
            <<"slow">>,
            #{},
            #{progress_token => Tok}
        ),
        Self ! {settled, Res}
    end),
    try
        Worker =
            receive
                {parked, W} -> W
            after 5000 -> error(tool_never_ran)
            end,
        %% The token is visible in the gen_statem's progress map for as
        %% long as the tool stays parked.
        wait_progress_present(Pid, Tok, 50),
        Worker ! release
    after
        unregister(?GATE)
    end,
    receive
        {settled, {ok, _}} -> ok
    after 5000 ->
        exit(Caller, kill),
        ?assert(false)
    end,
    %% Once settled, the entry must be gone.
    wait_progress_absent(Pid, Tok, 50),
    ok = barrel_mcp_registry:unreg(tool, <<"slow">>),
    barrel_mcp_client:close(Pid).

start_client(Extras) ->
    Spec = maps:merge(
        #{
            transport => {http, ?URL},
            %% ping is a handshake-era method, so pin the era it
            %% belongs to rather than probing into one without it.
            protocol_version => <<"2025-11-25">>,
            handler => {barrel_mcp_client_handler_default, []}
        },
        Extras
    ),
    {ok, Pid} = barrel_mcp_client:start(Spec),
    wait_ready(Pid, 30),
    {ok, Pid}.

%% Parks until the test releases it, so the window in which the
%% progress entry is observable is as long as the test needs instead of
%% a sleep the poller has to land inside.
slow_handler(_Args) ->
    case whereis(?GATE) of
        undefined ->
            ok;
        Gate ->
            Gate ! {parked, self()},
            receive
                release -> ok
            after 10000 -> ok
            end
    end,
    <<"done">>.

wait_progress_present(_Pid, _Tok, 0) ->
    error({progress_not_seen});
wait_progress_present(Pid, Tok, N) ->
    case progress_map(Pid) of
        #{Tok := _} ->
            ok;
        _ ->
            timer:sleep(20),
            wait_progress_present(Pid, Tok, N - 1)
    end.

wait_progress_absent(_Pid, _Tok, 0) ->
    error({progress_lingered});
wait_progress_absent(Pid, Tok, N) ->
    case progress_map(Pid) of
        #{Tok := _} ->
            timer:sleep(20),
            wait_progress_absent(Pid, Tok, N - 1);
        _ ->
            ok
    end.

%% Same record-layout contract as progress_map/1 below.
request_id(Pid) ->
    {_State, Data} = sys:get_state(Pid),
    element(4, Data).

progress_map(Pid) ->
    {_State, Data} = sys:get_state(Pid),
    %% data record: progress is the 10th element (1-based: 1=record_tag,
    %% 2=spec, 3=transport, 4=request_id, 5=pending, 6=handler_mod,
    %% 7=handler_state, 8=async_replies, 9=subscriptions, 10=progress).
    %% This layout is load-bearing: new fields go at the end of the
    %% record, or this reads the wrong one.
    element(10, Data).
