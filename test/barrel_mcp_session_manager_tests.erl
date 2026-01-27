%%%-------------------------------------------------------------------
%%% @doc Tests for barrel_mcp_session (session manager).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_session_manager_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test Fixtures
%%====================================================================

session_manager_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        {"Generate ID creates unique IDs", fun test_generate_id/0},
        {"Create session returns ID", fun test_create_session/0},
        {"Get session returns session data", fun test_get_session/0},
        {"Get nonexistent session returns not_found", fun test_get_not_found/0},
        {"Update activity updates timestamp", fun test_update_activity/0},
        {"Delete session removes it", fun test_delete_session/0},
        {"List sessions returns all", fun test_list_sessions/0},
        {"Cleanup expired removes old sessions", fun test_cleanup_expired/0}
     ]
    }.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    %% Clear any existing sessions
    lists:foreach(fun(#{id := Id}) ->
        barrel_mcp_session:delete(Id)
    end, barrel_mcp_session:list()),
    ok.

cleanup(_) ->
    %% Clear sessions
    lists:foreach(fun(#{id := Id}) ->
        barrel_mcp_session:delete(Id)
    end, barrel_mcp_session:list()),
    ok.

%%====================================================================
%% Tests
%%====================================================================

test_generate_id() ->
    Id1 = barrel_mcp_session:generate_id(),
    Id2 = barrel_mcp_session:generate_id(),
    %% IDs should be binaries starting with mcp_
    ?assert(is_binary(Id1)),
    ?assert(is_binary(Id2)),
    ?assertMatch(<<"mcp_", _/binary>>, Id1),
    ?assertMatch(<<"mcp_", _/binary>>, Id2),
    %% IDs should be unique
    ?assertNotEqual(Id1, Id2).

test_create_session() ->
    {ok, SessionId} = barrel_mcp_session:create(#{}),
    ?assert(is_binary(SessionId)),
    ?assertMatch(<<"mcp_", _/binary>>, SessionId),
    %% Cleanup
    barrel_mcp_session:delete(SessionId).

test_get_session() ->
    {ok, SessionId} = barrel_mcp_session:create(#{
        client_info => #{name => <<"test_client">>},
        protocol_version => <<"2025-03-26">>
    }),
    {ok, Session} = barrel_mcp_session:get(SessionId),
    ?assertEqual(SessionId, maps:get(id, Session)),
    ?assertEqual(<<"2025-03-26">>, maps:get(protocol_version, Session)),
    ?assertEqual(#{name => <<"test_client">>}, maps:get(client_info, Session)),
    ?assert(maps:is_key(created_at, Session)),
    ?assert(maps:is_key(last_activity, Session)),
    %% Cleanup
    barrel_mcp_session:delete(SessionId).

test_get_not_found() ->
    ?assertEqual({error, not_found}, barrel_mcp_session:get(<<"nonexistent">>)).

test_update_activity() ->
    {ok, SessionId} = barrel_mcp_session:create(#{}),
    {ok, Session1} = barrel_mcp_session:get(SessionId),
    LastActivity1 = maps:get(last_activity, Session1),

    %% Wait a bit and update
    timer:sleep(10),
    ok = barrel_mcp_session:update_activity(SessionId),

    {ok, Session2} = barrel_mcp_session:get(SessionId),
    LastActivity2 = maps:get(last_activity, Session2),

    ?assert(LastActivity2 > LastActivity1),
    %% Cleanup
    barrel_mcp_session:delete(SessionId).

test_delete_session() ->
    {ok, SessionId} = barrel_mcp_session:create(#{}),
    {ok, _} = barrel_mcp_session:get(SessionId),
    ok = barrel_mcp_session:delete(SessionId),
    ?assertEqual({error, not_found}, barrel_mcp_session:get(SessionId)).

test_list_sessions() ->
    %% Create multiple sessions
    {ok, Id1} = barrel_mcp_session:create(#{}),
    {ok, Id2} = barrel_mcp_session:create(#{}),
    {ok, Id3} = barrel_mcp_session:create(#{}),

    Sessions = barrel_mcp_session:list(),
    Ids = [maps:get(id, S) || S <- Sessions],

    ?assert(lists:member(Id1, Ids)),
    ?assert(lists:member(Id2, Ids)),
    ?assert(lists:member(Id3, Ids)),

    %% Cleanup
    barrel_mcp_session:delete(Id1),
    barrel_mcp_session:delete(Id2),
    barrel_mcp_session:delete(Id3).

test_cleanup_expired() ->
    %% Create sessions
    {ok, Id1} = barrel_mcp_session:create(#{}),
    {ok, Id2} = barrel_mcp_session:create(#{}),

    %% Use a very short TTL - 1ms
    %% Wait a bit for sessions to "expire"
    timer:sleep(50),

    %% Cleanup with 1ms TTL should remove sessions
    Cleaned = barrel_mcp_session:cleanup_expired(1),
    ?assert(Cleaned >= 2),

    %% Sessions should be gone
    ?assertEqual({error, not_found}, barrel_mcp_session:get(Id1)),
    ?assertEqual({error, not_found}, barrel_mcp_session:get(Id2)).
