%%%-------------------------------------------------------------------
%%% @doc The client auth handle: construction, the header it produces,
%%% and what a 401 does to it.
%%%
%%% The OAuth handles have their own suites. What is left here is the
%%% static bearer one, which had no test at all, and the dispatch in
%%% `barrel_mcp_client_auth' that chooses between them.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth_tests).

-include_lib("eunit/include/eunit.hrl").

none_carries_no_header_test() ->
    ?assertEqual(none, barrel_mcp_client_auth:new(none)),
    ?assertEqual(none, barrel_mcp_client_auth:header(none)),
    ?assertEqual(
        {error, no_auth_configured},
        barrel_mcp_client_auth:refresh(none, undefined)
    ).

bearer_handle_test() ->
    Handle = barrel_mcp_client_auth:new({bearer, <<"tok">>}),
    ?assertEqual({barrel_mcp_client_auth_bearer, <<"tok">>}, Handle),
    ?assertEqual({ok, <<"Bearer tok">>}, barrel_mcp_client_auth:header(Handle)).

%% A static token cannot be rotated by the library, so a 401 is the end
%% of the road rather than a retry.
bearer_refresh_is_unauthorized_test() ->
    Handle = barrel_mcp_client_auth:new({bearer, <<"tok">>}),
    ?assertEqual(
        {error, unauthorized},
        barrel_mcp_client_auth:refresh(Handle, <<"Bearer realm=\"x\"">>)
    ).

bearer_rejects_an_unusable_token_test() ->
    ?assertEqual({error, invalid_token}, barrel_mcp_client_auth:new({bearer, <<>>})),
    ?assertEqual({error, invalid_token}, barrel_mcp_client_auth_bearer:init(not_a_binary)).
