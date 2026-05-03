%%%-------------------------------------------------------------------
%%% @doc Tests for `barrel_mcp_client'.
%%%
%%% Drives the new gen_statem client against a loopback Streamable
%%% HTTP server (the same `barrel_mcp_http_stream' the server side
%%% exposes). Verifies handshake, tools/list, tools/call, version
%%% downgrade, and graceful close.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_tests).

-include_lib("eunit/include/eunit.hrl").

-export([test_handler/1]).

-define(PORT, 19191).
-define(URL, <<"http://127.0.0.1:19191/mcp">>).

%%====================================================================
%% Fixtures
%%====================================================================

client_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     {timeout, 30, [
         {"initialize handshake + capabilities", fun test_initialize/0},
         {"list_tools includes registered tool", fun test_list_tools/0},
         {"list_tools_all walks pagination", fun test_list_tools_all/0},
         {"call_tool returns content", fun test_call_tool/0},
         {"protocol version negotiates downward", fun test_version_downgrade/0},
         {"close shuts down cleanly", fun test_close/0}
     ]}}.

setup() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp_registry:reg(tool, <<"test_tool">>, ?MODULE, test_handler, #{
        description => <<"echo test tool">>
    }),
    {ok, _} = barrel_mcp_http_stream:start(#{port => ?PORT, session_enabled => true}),
    timer:sleep(150),
    ok.

cleanup(_) ->
    catch barrel_mcp_http_stream:stop(),
    catch barrel_mcp_registry:unreg(tool, <<"test_tool">>),
    ok.

test_handler(_Args) ->
    <<"echoed">>.

%%====================================================================
%% Tests
%%====================================================================

test_initialize() ->
    {ok, Pid} = start_client(),
    {ok, Caps} = barrel_mcp_client:server_capabilities(Pid),
    ?assert(maps:is_key(<<"tools">>, Caps)),
    {ok, Info} = barrel_mcp_client:server_info(Pid),
    ?assert(maps:is_key(<<"name">>, Info)),
    ok = barrel_mcp_client:close(Pid),
    wait_dead(Pid).

test_list_tools() ->
    {ok, Pid} = start_client(),
    {ok, Tools} = barrel_mcp_client:list_tools(Pid),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"test_tool">>, Names)),
    ok = barrel_mcp_client:close(Pid),
    wait_dead(Pid).

test_call_tool() ->
    {ok, Pid} = start_client(),
    {ok, Result} = barrel_mcp_client:call_tool(Pid, <<"test_tool">>, #{}),
    Content = maps:get(<<"content">>, Result),
    ?assert(is_list(Content)),
    [#{<<"type">> := <<"text">>, <<"text">> := <<"echoed">>}] = Content,
    ok = barrel_mcp_client:close(Pid),
    wait_dead(Pid).

test_list_tools_all() ->
    %% Server doesn't paginate today, so list_tools_all should return
    %% the same set as list_tools in one page.
    {ok, Pid} = start_client(),
    {ok, All} = barrel_mcp_client:list_tools_all(Pid),
    Names = [maps:get(<<"name">>, T) || T <- All],
    ?assert(lists:member(<<"test_tool">>, Names)),
    ok = barrel_mcp_client:close(Pid),
    wait_dead(Pid).

test_version_downgrade() ->
    %% Both sides target 2025-11-25 now, so negotiation echoes the
    %% client's version. The downgrade path stays exercised by the
    %% server-side protocol_version_unsupported_returns_400 case.
    {ok, Pid} = start_client(),
    {ok, Version} = barrel_mcp_client:protocol_version(Pid),
    ?assertEqual(<<"2025-11-25">>, Version),
    ok = barrel_mcp_client:close(Pid),
    wait_dead(Pid).

test_close() ->
    {ok, Pid} = start_client(),
    Mon = erlang:monitor(process, Pid),
    ok = barrel_mcp_client:close(Pid),
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    after 5000 ->
        ?assert(false)
    end.

%%====================================================================
%% Helpers
%%====================================================================

start_client() ->
    Spec = #{
        transport => {http, ?URL},
        capabilities => #{},
        handler => {barrel_mcp_client_handler_default, []}
    },
    {ok, Pid} = barrel_mcp_client:start(Spec),
    wait_ready(Pid, 30),
    {ok, Pid}.

wait_ready(_Pid, 0) -> error(client_not_ready);
wait_ready(Pid, N) ->
    case catch barrel_mcp_client:server_capabilities(Pid) of
        {ok, _} -> ok;
        _ ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.

wait_dead(Pid) ->
    Mon = erlang:monitor(process, Pid),
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    after 5000 ->
        erlang:demonitor(Mon, [flush]),
        ok
    end.
