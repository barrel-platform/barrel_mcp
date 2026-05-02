%%%-------------------------------------------------------------------
%%% @doc Common-test suite for the sampling_host example.
%%%
%%% Asserts the full server-to-client sampling round-trip works:
%%% the client's handler answers `sampling/createMessage' and the
%%% server-side tool wraps the reply in its own response.
%%% @end
%%%-------------------------------------------------------------------
-module(sampling_host_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([sampling_round_trip/1]).

all() -> [sampling_round_trip].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    Config.

end_per_suite(_Config) ->
    catch barrel_mcp_http_stream:stop(),
    application:stop(barrel_mcp),
    ok.

sampling_round_trip(_Config) ->
    Text = sampling_host:run(28081),
    <<"got: a canned reply">> = Text,
    ok.
