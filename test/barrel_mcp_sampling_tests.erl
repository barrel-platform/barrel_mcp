%% @doc Tests for the new server-to-client primitives:
%%   - client capability tracking
%%   - resource subscriptions and notifications
%%   - sampling/createMessage round-trip
-module(barrel_mcp_sampling_tests).

-include_lib("eunit/include/eunit.hrl").

%% ============================================================================
%% Capability tracking
%% ============================================================================

capability_tracking_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"set + has_sampling", fun test_has_sampling/0},
            {"list sampling-capable sessions",
             fun test_list_sampling_capable/0}
        ]
    end}.

test_has_sampling() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ?assertNot(barrel_mcp_session:has_sampling(S1)),
    ok = barrel_mcp_session:set_client_capabilities(S1, #{
        <<"sampling">> => #{}
    }),
    ?assert(barrel_mcp_session:has_sampling(S1)).

test_list_sampling_capable() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    {ok, S2} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(
        S2, #{<<"sampling">> => #{}}),
    Capable = barrel_mcp_session:list_sampling_capable(),
    ?assertNot(lists:member(S1, Capable)),
    ?assert(lists:member(S2, Capable)).

%% ============================================================================
%% Resource subscriptions
%% ============================================================================

resource_subscriptions_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"subscribe + subscribers_for",
             fun test_subscribe/0},
            {"notify_resource_updated reaches subscriber",
             fun test_notify_resource_updated/0}
        ]
    end}.

test_subscribe() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    Uri = <<"live://alerts/active">>,
    ok = barrel_mcp_session:subscribe_resource(S1, Uri),
    Subs = barrel_mcp_session:subscribers_for(Uri),
    ?assert(lists:member(S1, Subs)),
    ok = barrel_mcp_session:unsubscribe_resource(S1, Uri),
    ?assertNot(lists:member(S1,
                            barrel_mcp_session:subscribers_for(Uri))).

test_notify_resource_updated() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    Self = self(),
    Pid = spawn(fun() -> capture_loop(Self) end),
    ok = barrel_mcp_session:set_sse_pid(S1, Pid),
    Uri = <<"live://alerts/active">>,
    ok = barrel_mcp_session:subscribe_resource(S1, Uri),
    ok = barrel_mcp:notify_resource_updated(Uri),
    receive
        {captured, {sse_send_message, Msg}} ->
            ?assertEqual(<<"notifications/resources/updated">>,
                         maps:get(<<"method">>, Msg)),
            ?assertEqual(Uri,
                         maps:get(<<"uri">>,
                                  maps:get(<<"params">>, Msg)))
    after 1000 -> ?assert(false)
    end,
    exit(Pid, kill).

%% ============================================================================
%% sampling_create_message round-trip
%% ============================================================================

sampling_round_trip_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"declines without sampling capability",
             fun test_sampling_not_supported/0},
            {"declines without an SSE pid",
             fun test_sampling_no_sse/0},
            {"happy path: response routed to caller",
             fun test_sampling_round_trip/0},
            {"timeout when no response arrives",
             fun test_sampling_timeout/0}
        ]
    end}.

test_sampling_not_supported() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    %% capability not set
    ?assertEqual({error, not_supported},
                 barrel_mcp:sampling_create_message(S1, #{}, #{})).

test_sampling_no_sse() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(
        S1, #{<<"sampling">> => #{}}),
    %% no sse_pid
    ?assertEqual({error, no_sse},
                 barrel_mcp:sampling_create_message(S1, #{}, #{})).

test_sampling_round_trip() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(
        S1, #{<<"sampling">> => #{}}),
    Self = self(),
    Pid = spawn(fun() -> sampling_responder(Self) end),
    ok = barrel_mcp_session:set_sse_pid(S1, Pid),
    spawn(fun() ->
        %% Forward the inbound message back as a response, then deliver.
        Self ! {result, barrel_mcp:sampling_create_message(
            S1, #{<<"messages">> => []}, #{timeout_ms => 2000})}
    end),
    %% The fake responder forwards the request to us.
    Request = receive
        {got_message, Msg} -> Msg
    after 1000 -> ?assert(false), undefined
    end,
    Id = maps:get(<<"id">>, Request),
    ?assertEqual(<<"sampling/createMessage">>,
                 maps:get(<<"method">>, Request)),
    %% Deliver a fake response
    ok = barrel_mcp_session:deliver_response(Id, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{
            <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => <<"hi">>},
            <<"usage">> => #{<<"input_tokens">> => 10}
        }
    }),
    receive
        {result, {ok, Result, Usage}} ->
            ?assertEqual(<<"hi">>,
                         maps:get(<<"text">>,
                                  maps:get(<<"content">>, Result))),
            ?assertEqual(10, maps:get(<<"input_tokens">>, Usage))
    after 2000 ->
        ?assert(false)
    end,
    exit(Pid, kill).

test_sampling_timeout() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(
        S1, #{<<"sampling">> => #{}}),
    Pid = spawn(fun() -> idle_loop() end),
    ok = barrel_mcp_session:set_sse_pid(S1, Pid),
    ?assertEqual({error, timeout},
                 barrel_mcp:sampling_create_message(
                     S1, #{}, #{timeout_ms => 100})),
    exit(Pid, kill).

%% ============================================================================
%% elicit_create round-trip
%% ============================================================================

elicit_round_trip_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"declines without elicitation capability",
             fun test_elicit_not_supported/0},
            {"happy path: response routed to caller",
             fun test_elicit_round_trip/0},
            {"timeout when no response arrives",
             fun test_elicit_timeout/0}
        ]
    end}.

test_elicit_not_supported() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ?assertEqual({error, not_supported},
                 barrel_mcp:elicit_create(S1, #{}, #{})).

test_elicit_round_trip() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(
        S1, #{<<"elicitation">> => #{}}),
    Self = self(),
    Pid = spawn(fun() -> sampling_responder(Self) end),
    ok = barrel_mcp_session:set_sse_pid(S1, Pid),
    spawn(fun() ->
        Self ! {result, barrel_mcp:elicit_create(
            S1,
            #{<<"message">> => <<"Pick a colour">>,
              <<"requestedSchema">> => #{<<"type">> => <<"object">>}},
            #{timeout_ms => 2000})}
    end),
    Request = receive
        {got_message, Msg} -> Msg
    after 1000 -> ?assert(false), undefined
    end,
    Id = maps:get(<<"id">>, Request),
    ?assertEqual(<<"elicitation/create">>,
                 maps:get(<<"method">>, Request)),
    ok = barrel_mcp_session:deliver_response(Id, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{<<"action">> => <<"accept">>,
                          <<"content">> => #{<<"colour">> => <<"blue">>}}
    }),
    receive
        {result, {ok, Result}} ->
            ?assertEqual(<<"accept">>, maps:get(<<"action">>, Result)),
            ?assertEqual(<<"blue">>,
                         maps:get(<<"colour">>,
                                  maps:get(<<"content">>, Result)))
    after 2000 ->
        ?assert(false)
    end,
    exit(Pid, kill).

test_elicit_timeout() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(
        S1, #{<<"elicitation">> => #{}}),
    Pid = spawn(fun() -> idle_loop() end),
    ok = barrel_mcp_session:set_sse_pid(S1, Pid),
    ?assertEqual({error, timeout},
                 barrel_mcp:elicit_create(
                     S1, #{}, #{timeout_ms => 100})),
    exit(Pid, kill).

%% ============================================================================
%% roots_list round-trip
%% ============================================================================

roots_list_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        [
            {"declines without roots capability",
             fun test_roots_not_supported/0},
            {"happy path: response routed to caller",
             fun test_roots_round_trip/0},
            {"timeout when no response arrives",
             fun test_roots_timeout/0}
        ]
    end}.

test_roots_not_supported() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ?assertEqual({error, not_supported},
                 barrel_mcp:roots_list(S1)).

test_roots_round_trip() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(
        S1, #{<<"roots">> => #{}}),
    Self = self(),
    Pid = spawn(fun() -> sampling_responder(Self) end),
    ok = barrel_mcp_session:set_sse_pid(S1, Pid),
    spawn(fun() ->
        Self ! {result,
                barrel_mcp:roots_list(S1, #{timeout_ms => 2000})}
    end),
    Request = receive
        {got_message, Msg} -> Msg
    after 1000 -> ?assert(false), undefined
    end,
    Id = maps:get(<<"id">>, Request),
    ?assertEqual(<<"roots/list">>, maps:get(<<"method">>, Request)),
    ok = barrel_mcp_session:deliver_response(Id, #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{<<"roots">> =>
            [#{<<"uri">> => <<"file:///workspace">>,
               <<"name">> => <<"Workspace">>}]}
    }),
    receive
        {result, {ok, Roots}} ->
            ?assertMatch([#{<<"uri">> := <<"file:///workspace">>}], Roots)
    after 2000 ->
        ?assert(false)
    end,
    exit(Pid, kill).

test_roots_timeout() ->
    {ok, S1} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(
        S1, #{<<"roots">> => #{}}),
    Pid = spawn(fun() -> idle_loop() end),
    ok = barrel_mcp_session:set_sse_pid(S1, Pid),
    ?assertEqual({error, timeout},
                 barrel_mcp:roots_list(S1, #{timeout_ms => 100})),
    exit(Pid, kill).

%% ============================================================================
%% Helpers
%% ============================================================================

setup() ->
    %% Restart application to get a clean ETS state.
    catch application:stop(barrel_mcp),
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok.

teardown(_) ->
    application:stop(barrel_mcp).

capture_loop(Reporter) ->
    receive
        Msg ->
            Reporter ! {captured, Msg},
            capture_loop(Reporter)
    end.

sampling_responder(Reporter) ->
    receive
        {sse_send_message, Msg} ->
            Reporter ! {got_message, Msg},
            sampling_responder(Reporter);
        _ -> sampling_responder(Reporter)
    end.

idle_loop() ->
    receive _ -> idle_loop() end.
