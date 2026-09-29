%%%-------------------------------------------------------------------
%%% @doc Principals, provider routing and rendering for hosted tasks,
%%% and the default task store's callbacks.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_task_provider_tests).

-include_lib("eunit/include/eunit.hrl").

%% A provider that crashes on every call.
-export([get/2, cancel/2, update/3]).

get(_Owner, _TaskId) -> error(broken).
cancel(_Owner, _TaskId) -> error(broken).
update(_Owner, _TaskId, _Responses) -> error(broken).

%%====================================================================
%% principal/1
%%====================================================================

principal_test_() ->
    {setup, fun start/0, fun(_) -> ok end, [
        {"Anonymous has no principal", fun anonymous_is_undefined/0},
        {"Same principal, same id", fun principal_is_stable/0},
        {"Different principals differ", fun principals_differ/0},
        {"A session maps to its principal", fun session_principal/0}
    ]}.

start() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok.

anonymous_is_undefined() ->
    ?assertEqual(undefined, barrel_mcp_tasks:principal({principal, anonymous})),
    ?assertEqual(undefined, barrel_mcp_tasks:principal(undefined)),
    ?assertEqual(undefined, barrel_mcp_tasks:principal(<<"no-such-session">>)).

principal_is_stable() ->
    P = {barrel_mcp_auth_bearer, <<"https://idp">>, <<"alice">>},
    A = barrel_mcp_tasks:principal({principal, P}),
    ?assertMatch(<<"p1.", _/binary>>, A),
    ?assertEqual(A, barrel_mcp_tasks:principal({principal, P})),
    %% Map key order does not matter.
    M1 = barrel_mcp_tasks:principal({principal, #{a => 1, b => <<"x">>}}),
    M2 = barrel_mcp_tasks:principal({principal, maps:from_list([{b, <<"x">>}, {a, 1}])}),
    ?assertEqual(M1, M2).

principals_differ() ->
    Enc = fun(P) -> barrel_mcp_tasks:principal({principal, P}) end,
    ?assertNotEqual(
        Enc({barrel_mcp_auth_bearer, <<"idp1">>, <<"alice">>}),
        Enc({barrel_mcp_auth_bearer, <<"idp2">>, <<"alice">>})
    ),
    ?assertNotEqual(
        Enc({barrel_mcp_auth_bearer, <<"idp">>, <<"alice">>}),
        Enc({barrel_mcp_auth_apikey, <<"idp">>, <<"alice">>})
    ),
    %% An atom and a binary of the same text are different terms.
    ?assertNotEqual(Enc(alice), Enc(<<"alice">>)),
    %% A term with no canonical form still never collides.
    ?assertNotEqual(Enc({self()}), Enc({spawn(fun() -> ok end)})).

session_principal() ->
    P = {barrel_mcp_auth_apikey, undefined, <<"alice">>},
    {ok, S1} = barrel_mcp_session:create(#{}),
    {ok, S2} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_principal(S1, P),
    ok = barrel_mcp_session:set_principal(S2, P),
    ?assertEqual(barrel_mcp_tasks:principal({principal, P}), barrel_mcp_tasks:principal(S1)),
    ?assertEqual(barrel_mcp_tasks:principal(S1), barrel_mcp_tasks:principal(S2)).

%%====================================================================
%% Routing
%%====================================================================

routing_test_() ->
    {setup, fun start_providers/0, fun stop_providers/1, [
        {"A crashing provider does not hide the next", fun crash_falls_through/0},
        {"Unknown ids are not found everywhere", fun unknown_not_found/0}
    ]}.

start_providers() ->
    ok = start(),
    Holder = barrel_mcp_test_task_provider:start_table(),
    application:set_env(barrel_mcp, task_providers, [?MODULE, barrel_mcp_test_task_provider]),
    Holder.

stop_providers(Holder) ->
    application:unset_env(barrel_mcp, task_providers),
    barrel_mcp_test_task_provider:stop_table(Holder).

crash_falls_through() ->
    Owner = {principal, {?MODULE, alice}},
    Id = barrel_mcp_test_task_provider:new(Owner, #{}),
    ?assertMatch({ok, #{<<"taskId">> := Id}}, barrel_mcp_tasks:get(Owner, Id, modern)),
    ?assertEqual([Id], barrel_mcp_tasks:owned(Owner, [Id, <<"nope">>])),
    ?assertEqual(ok, barrel_mcp_tasks:update(Owner, Id, #{})),
    ?assertEqual({error, not_found}, barrel_mcp_tasks:get({principal, bob}, Id, modern)).

unknown_not_found() ->
    Owner = {principal, {?MODULE, alice}},
    ?assertEqual({error, not_found}, barrel_mcp_tasks:get(Owner, <<"nope">>, modern)),
    ?assertEqual({error, not_found}, barrel_mcp_tasks:cancel(Owner, <<"nope">>)),
    ?assertEqual({error, not_found}, barrel_mcp_tasks:update(Owner, <<"nope">>, #{})).

%%====================================================================
%% Rendering
%%====================================================================

render_test_() ->
    Task = #{
        id => <<"t1">>,
        status => input_required,
        created_at => 0,
        updated_at => 1000,
        ttl_ms => 5000,
        poll_interval_ms => 200,
        input_requests => #{<<"k">> => #{<<"method">> => <<"elicitation/create">>}}
    },
    Modern = barrel_mcp_task_provider:render(Task, {principal, anonymous}, modern),
    Legacy = barrel_mcp_task_provider:render(Task, <<"sid">>, legacy),
    Failed = barrel_mcp_task_provider:render(
        Task#{status => failed, error => <<"boom">>}, {principal, anonymous}, modern
    ),
    [
        ?_assertEqual(5000, maps:get(<<"ttlMs">>, Modern)),
        ?_assertEqual(200, maps:get(<<"pollIntervalMs">>, Modern)),
        ?_assertEqual(<<"input_required">>, maps:get(<<"status">>, Modern)),
        ?_assert(maps:is_key(<<"inputRequests">>, Modern)),
        ?_assertNot(maps:is_key(<<"sessionId">>, Modern)),
        ?_assertNot(maps:is_key(<<"method">>, Modern)),
        ?_assertEqual(5000, maps:get(<<"ttl">>, Legacy)),
        ?_assertEqual(200, maps:get(<<"pollInterval">>, Legacy)),
        ?_assertEqual(<<"sid">>, maps:get(<<"sessionId">>, Legacy)),
        ?_assertEqual(<<"1970-01-01T00:00:01.000Z">>, maps:get(<<"lastUpdatedAt">>, Legacy)),
        ?_assertEqual(
            #{<<"code">> => -32603, <<"message">> => <<"boom">>}, maps:get(<<"error">>, Failed)
        ),
        ?_assertNot(maps:is_key(<<"inputRequests">>, Failed))
    ].

%%====================================================================
%% Default store
%%====================================================================

ets_store_test_() ->
    {setup, fun start/0, fun(_) -> ok end, [
        {"A created task round-trips through the store", fun store_round_trip/0}
    ]}.

store_round_trip() ->
    ?assertEqual(barrel_mcp_task_store_ets, barrel_mcp_task_store:backend()),
    Owner = {principal, {?MODULE, store}},
    {ok, Id} = barrel_mcp_tasks:create(Owner, <<"tools/call">>, #{params => #{<<"a">> => 1}}),
    ?assertMatch({ok, #{v := 1, id := Id, owner := Owner}}, barrel_mcp_task_store:get(Id)),
    ?assertEqual({ok, #{<<"a">> => 1}}, barrel_mcp_tasks:params(Owner, Id)),
    ?assertEqual(1, barrel_mcp_task_store:count_owned(Owner)),
    ?assertEqual(not_found, barrel_mcp_task_store:get(<<"task_nope">>)).
