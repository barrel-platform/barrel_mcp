%%%-------------------------------------------------------------------
%%% @doc Common-test suite for the echo_client example.
%%%
%%% Runs `echo_client:run/1' on a non-default port and asserts the
%%% returned binary matches the input.
%%% @end
%%%-------------------------------------------------------------------
-module(echo_client_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([round_trip/1]).

all() -> [round_trip].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    Config.

end_per_suite(_Config) ->
    catch barrel_mcp_http_stream:stop(),
    application:stop(barrel_mcp),
    ok.

round_trip(_Config) ->
    Echoed = echo_client:run(28080),
    <<"hello, mcp">> = Echoed,
    ok.
