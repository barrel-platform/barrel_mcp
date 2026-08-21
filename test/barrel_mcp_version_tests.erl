%%%-------------------------------------------------------------------
%%% @doc Protocol revision comparison.
%%%
%%% The point of the module under test is that revisions are an
%%% enumerated set, so these cases are mostly about what must NOT
%%% happen when a string is compared as if it were an ordered scalar.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_version_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

%%====================================================================
%% Membership
%%====================================================================

known_test() ->
    lists:foreach(
        fun(V) -> ?assert(barrel_mcp_version:is_known(V)) end,
        ?MCP_KNOWN_VERSIONS
    ),
    ?assertNot(barrel_mcp_version:is_known(<<"2027-01-01">>)),
    ?assertNot(barrel_mcp_version:is_known(<<>>)),
    ?assertNot(barrel_mcp_version:is_known(not_a_binary)).

era_test() ->
    ?assertEqual(modern, barrel_mcp_version:era(<<"2026-07-28">>)),
    ?assertEqual(legacy, barrel_mcp_version:era(<<"2025-11-25">>)),
    ?assertEqual(legacy, barrel_mcp_version:era(<<"2024-11-05">>)),
    ?assertEqual(unknown, barrel_mcp_version:era(<<"2027-01-01">>)),
    ?assertEqual(unknown, barrel_mcp_version:era(undefined)).

%% The two eras partition everything the library speaks: nothing is in
%% both, nothing is left out.
eras_partition_all_test() ->
    All = lists:sort(barrel_mcp_version:all()),
    Split = lists:sort(?MCP_MODERN_VERSIONS ++ ?MCP_LEGACY_VERSIONS),
    ?assertEqual(All, Split),
    ?assertEqual(All, lists:usort(All)),
    %% And everything we speak is a revision we know.
    lists:foreach(
        fun(V) -> ?assert(barrel_mcp_version:is_known(V)) end,
        All
    ).

%%====================================================================
%% Ordering
%%====================================================================

is_at_least_test() ->
    ?assert(barrel_mcp_version:is_at_least(<<"2026-07-28">>, <<"2025-11-25">>)),
    ?assert(barrel_mcp_version:is_at_least(<<"2025-11-25">>, <<"2025-11-25">>)),
    ?assertNot(barrel_mcp_version:is_at_least(<<"2025-06-18">>, <<"2025-11-25">>)),
    ?assertNot(barrel_mcp_version:is_at_least(<<"2024-11-05">>, <<"2026-07-28">>)).

%% The reason this module exists. Lexicographically <<"zzz">> beats
%% every date we know, which would silently gate a feature on for a
%% peer we cannot place at all.
unknown_version_satisfies_nothing_test() ->
    ?assert(<<"zzz">> > <<"2026-07-28">>),
    ?assertNot(barrel_mcp_version:is_at_least(<<"zzz">>, <<"2024-11-05">>)),
    ?assertNot(barrel_mcp_version:is_at_least(<<"2027-01-01">>, <<"2024-11-05">>)),
    ?assertNot(barrel_mcp_version:is_at_least(<<>>, <<"2024-11-05">>)).

%% An unknown minimum is a bug where it is written, not a condition to
%% handle at runtime.
unknown_minimum_raises_test() ->
    ?assertError(
        {unknown_minimum_version, <<"nope">>},
        barrel_mcp_version:is_at_least(<<"2026-07-28">>, <<"nope">>)
    ).

%%====================================================================
%% Registry consistency
%%====================================================================

%% The named roles have to name revisions that actually exist, or a
%% handshake would offer something no peer can accept.
role_constants_are_known_test() ->
    lists:foreach(
        fun(V) -> ?assert(barrel_mcp_version:is_known(V)) end,
        [
            ?MCP_LATEST_VERSION,
            ?MCP_LATEST_LEGACY_VERSION,
            ?MCP_LATEST_MODERN_VERSION,
            ?MCP_OLDEST_VERSION
        ]
    ).

role_constants_are_in_the_right_era_test() ->
    ?assertEqual(legacy, barrel_mcp_version:era(?MCP_LATEST_LEGACY_VERSION)),
    ?assertEqual(legacy, barrel_mcp_version:era(?MCP_OLDEST_VERSION)),
    ?assertEqual(modern, barrel_mcp_version:era(?MCP_LATEST_MODERN_VERSION)).

%% `latest' and `oldest' have to bracket everything else, or the names
%% are lying.
latest_and_oldest_bracket_the_set_test() ->
    lists:foreach(
        fun(V) ->
            ?assert(barrel_mcp_version:is_at_least(?MCP_LATEST_VERSION, V)),
            ?assert(barrel_mcp_version:is_at_least(V, ?MCP_OLDEST_VERSION))
        end,
        ?MCP_KNOWN_VERSIONS
    ).

%% A modern revision cannot be reached through the handshake, so the
%% counter-offer must never be one.
handshake_offer_is_never_modern_test() ->
    ?assertNot(lists:member(?MCP_LATEST_LEGACY_VERSION, ?MCP_MODERN_VERSIONS)),
    ?assertNot(lists:member(?MCP_LATEST_MODERN_VERSION, ?MCP_LEGACY_VERSIONS)).
