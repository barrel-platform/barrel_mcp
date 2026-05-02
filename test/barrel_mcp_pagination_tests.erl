%%%-------------------------------------------------------------------
%%% @doc Tests for `barrel_mcp_pagination'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_pagination_tests).

-include_lib("eunit/include/eunit.hrl").

single_page_test() ->
    Fetch = fun(undefined) -> {ok, [a, b, c]} end,
    ?assertEqual({ok, [a, b, c]}, barrel_mcp_pagination:walk(Fetch)).

single_page_with_undefined_cursor_test() ->
    Fetch = fun(undefined) -> {ok, [a, b], undefined} end,
    ?assertEqual({ok, [a, b]}, barrel_mcp_pagination:walk(Fetch)).

multi_page_test() ->
    Pages = #{undefined => {[a, b], <<"c1">>},
              <<"c1">>  => {[c, d], <<"c2">>},
              <<"c2">>  => {[e],    undefined}},
    Fetch = fun(C) ->
        {Items, Next} = maps:get(C, Pages),
        {ok, Items, Next}
    end,
    ?assertEqual({ok, [a, b, c, d, e]}, barrel_mcp_pagination:walk(Fetch)).

empty_cursor_string_terminates_test() ->
    Pages = #{undefined => {[a], <<>>}},
    Fetch = fun(C) ->
        {Items, Next} = maps:get(C, Pages),
        {ok, Items, Next}
    end,
    ?assertEqual({ok, [a]}, barrel_mcp_pagination:walk(Fetch)).

error_propagates_test() ->
    Fetch = fun(undefined) -> {error, boom} end,
    ?assertEqual({error, boom}, barrel_mcp_pagination:walk(Fetch)).

max_pages_guard_test() ->
    %% Always returns a cursor — would loop forever without the cap.
    Fetch = fun(_) -> {ok, [x], <<"more">>} end,
    ?assertEqual({error, max_pages}, barrel_mcp_pagination:walk(Fetch, 3)).
