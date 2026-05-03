%%%-------------------------------------------------------------------
%%% @doc Common-test suite for the agent_host example.
%%%
%%% Runs the federation aggregator end to end: starts an in-process
%%% MCP server, connects two clients under different ServerIds,
%%% asserts that `barrel_mcp_agent:list_tools/0' surfaces the same
%%% tool under both `alpha:' and `beta:' prefixes, and that
%%% `call_tool/2' routes a `<<"beta:echo">>' to the right client.
%%% @end
%%%-------------------------------------------------------------------
-module(agent_host_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([federation_round_trip/1]).

all() -> [federation_round_trip].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    Config.

end_per_suite(_Config) ->
    catch barrel_mcp_http_stream:stop(),
    application:stop(barrel_mcp),
    ok.

federation_round_trip(_Config) ->
    {Catalog, Routed} = agent_host:run(28091),
    Names = [maps:get(<<"name">>, T) || T <- Catalog],
    true = lists:member(<<"alpha:echo">>, Names),
    true = lists:member(<<"beta:echo">>, Names),
    [#{<<"text">> := <<"hello from beta">>} | _] =
        maps:get(<<"content">>, Routed),
    ok.
