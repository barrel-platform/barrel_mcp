%%%-------------------------------------------------------------------
%%% @doc Tasks hosted by the application through a task provider, end
%%% to end over Streamable HTTP, in both eras.
%%%
%%% Two API keys stand for two principals. The provider's table lives
%%% outside the application, so a restart of `barrel_mcp' must not lose
%%% a task: nothing about it is stored on the barrel_mcp side.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_task_provider_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    found_after_restart_modern/1,
    found_after_restart_legacy/1,
    other_principal_sees_nothing/1,
    plain_result_in_place/1,
    working_task_handed_back/1,
    done_within_window_in_place/1,
    legacy_gets_wrapped_task/1,
    input_round_through_update/1,
    cancel_may_complete/1,
    legacy_result_and_list/1,
    task_refused_without_extension/1
]).

-define(PORT, 22350).
-define(MODERN, <<"2026-07-28">>).
-define(ALICE, <<"alice-key">>).
-define(BOB, <<"bob-key">>).
-define(PROVIDER, barrel_mcp_test_task_provider).

all() ->
    [
        found_after_restart_modern,
        found_after_restart_legacy,
        other_principal_sees_nothing,
        plain_result_in_place,
        working_task_handed_back,
        done_within_window_in_place,
        legacy_gets_wrapped_task,
        input_round_through_update,
        cancel_may_complete,
        legacy_result_and_list,
        task_refused_without_extension
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    Holder = ?PROVIDER:start_table(),
    %% Registered through the app env as well, so the provider is asked
    %% after a restart even before any tool names it again.
    ok = barrel_mcp:register_task_provider(?PROVIDER),
    [{holder, Holder} | Config].

end_per_suite(Config) ->
    ok = barrel_mcp:unregister_task_provider(?PROVIDER),
    ?PROVIDER:stop_table(?config(holder, Config)),
    ok.

init_per_testcase(_TC, Config) ->
    ok = serve(),
    Config.

end_per_testcase(_TC, _Config) ->
    _ = barrel_mcp:stop_http_stream(),
    _ = barrel_mcp:unreg_tool(<<"hosted">>),
    ok.

serve() ->
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"hosted">>, ?PROVIDER, hosted, #{
        task_support => optional,
        task_provider => ?PROVIDER
    }),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => ?PORT,
        session_enabled => true,
        auth => #{
            provider => barrel_mcp_auth_apikey,
            provider_opts => #{
                keys => #{
                    ?ALICE => #{subject => <<"alice">>},
                    ?BOB => #{subject => <<"bob">>}
                }
            }
        }
    }),
    ok.

restart() ->
    _ = barrel_mcp:stop_http_stream(),
    ok = application:stop(barrel_mcp),
    {ok, _} = application:ensure_all_started(barrel_mcp),
    serve().

%%====================================================================
%% Cases
%%====================================================================

found_after_restart_modern(_Config) ->
    TaskId = task_id(call(?ALICE, 1, <<"working">>, tasks_caps())),
    ok = restart(),
    {200, _, Body} = tasks_get(?ALICE, TaskId),
    Task = result_of(Body),
    ?assertEqual(TaskId, maps:get(<<"taskId">>, Task)),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, Task)),
    ?assert(maps:is_key(<<"ttlMs">>, Task)),
    ok.

%% A legacy task is scoped to its session, which a restart ends. The
%% provider compares the principal, so the same caller on a new session
%% still reaches it.
found_after_restart_legacy(_Config) ->
    S1 = initialize(?ALICE),
    {200, _, Body} = legacy(?ALICE, S1, 2, <<"tools/call">>, #{
        <<"name">> => <<"hosted">>, <<"arguments">> => #{<<"mode">> => <<"working">>}
    }),
    TaskId = maps:get(<<"taskId">>, maps:get(<<"task">>, result_of(Body))),
    ok = restart(),
    S2 = initialize(?ALICE),
    {200, _, Got} = legacy(?ALICE, S2, 3, <<"tasks/get">>, #{<<"taskId">> => TaskId}),
    Task = result_of(Got),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, Task)),
    ?assert(maps:is_key(<<"ttl">>, Task)),
    ?assertEqual(250, maps:get(<<"pollInterval">>, Task)),
    %% Bob's session does not.
    SB = initialize(?BOB),
    {200, _, Denied} = legacy(?BOB, SB, 4, <<"tasks/get">>, #{<<"taskId">> => TaskId}),
    ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, error_of(Denied))),
    ok.

other_principal_sees_nothing(_Config) ->
    TaskId = task_id(call(?ALICE, 1, <<"working">>, tasks_caps())),
    Update = #{<<"taskId">> => TaskId, <<"inputResponses">> => #{}},
    Id = #{<<"taskId">> => TaskId},
    lists:foreach(
        fun({Method, Params}) ->
            {400, _, Body} = rpc(?BOB, 2, Method, Params),
            Error = error_of(Body),
            ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, Error)),
            ?assertEqual(<<"Task not found">>, maps:get(<<"message">>, Error))
        end,
        [{<<"tasks/get">>, Id}, {<<"tasks/update">>, Update}, {<<"tasks/cancel">>, Id}]
    ),
    %% Still Alice's, and still running.
    {200, _, Mine} = tasks_get(?ALICE, TaskId),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, result_of(Mine))),
    ok.

plain_result_in_place(_Config) ->
    Result = result_of(call(?ALICE, 1, <<"plain">>, tasks_caps())),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual([#{<<"type">> => <<"text">>, <<"text">> => <<"plain">>}], content(Result)),
    ok.

working_task_handed_back(_Config) ->
    Result = result_of(call(?ALICE, 1, <<"working">>, tasks_caps())),
    ?assertEqual(<<"task">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, Result)),
    %% The host's own hint wins over the server default.
    ?assertEqual(250, maps:get(<<"pollIntervalMs">>, Result)),
    ?assertEqual(60000, maps:get(<<"ttlMs">>, Result)),
    ok.

done_within_window_in_place(_Config) ->
    Result = result_of(call(?ALICE, 1, <<"done">>, tasks_caps())),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertNot(maps:is_key(<<"taskId">>, Result)),
    ?assertEqual([#{<<"type">> => <<"text">>, <<"text">> => <<"done">>}], content(Result)),
    ok.

legacy_gets_wrapped_task(_Config) ->
    S = initialize(?ALICE),
    {200, _, Body} = legacy(?ALICE, S, 2, <<"tools/call">>, #{
        <<"name">> => <<"hosted">>, <<"arguments">> => #{<<"mode">> => <<"done">>}
    }),
    Result = result_of(Body),
    ?assertNot(maps:is_key(<<"resultType">>, Result)),
    Task = maps:get(<<"task">>, Result),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Task)),
    ?assertEqual(S, maps:get(<<"sessionId">>, Task)),
    ok.

input_round_through_update(_Config) ->
    Created = result_of(call(?ALICE, 1, <<"input">>, tasks_caps())),
    ?assertEqual(<<"input_required">>, maps:get(<<"status">>, Created)),
    TaskId = maps:get(<<"taskId">>, Created),
    {200, _, Got} = tasks_get(?ALICE, TaskId),
    Ask = maps:get(<<"who">>, maps:get(<<"inputRequests">>, result_of(Got))),
    ?assertEqual(<<"elicitation/create">>, maps:get(<<"method">>, Ask)),

    Ref = listen(?ALICE, 9, TaskId),
    Ack = next_event(Ref),
    ?assertEqual([TaskId], maps:get(<<"taskIds">>, notifications_of(Ack))),

    Answer = #{
        <<"who">> => #{<<"action">> => <<"accept">>, <<"content">> => #{<<"name">> => <<"ada">>}}
    },
    {200, _, Ack2} = rpc(?ALICE, 2, <<"tasks/update">>, #{
        <<"taskId">> => TaskId, <<"inputResponses">> => Answer
    }),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, result_of(Ack2))),
    ?assertEqual([Answer], ?PROVIDER:updates(TaskId)),

    Note = next_event(Ref),
    ?assertEqual(<<"notifications/tasks">>, maps:get(<<"method">>, Note)),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, maps:get(<<"params">>, Note))),
    close(Ref),

    {200, _, Final} = tasks_get(?ALICE, TaskId),
    Done = result_of(Final),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Done)),
    ?assertNot(maps:is_key(<<"inputRequests">>, Done)),
    ?assertEqual(
        [#{<<"type">> => <<"text">>, <<"text">> => <<"hello ada">>}],
        content(maps:get(<<"result">>, Done))
    ),
    ok.

%% Cancellation is cooperative: the work may still finish.
cancel_may_complete(_Config) ->
    TaskId = task_id(call(?ALICE, 1, <<"cancel_completes">>, tasks_caps())),
    {200, _, Ack} = rpc(?ALICE, 2, <<"tasks/cancel">>, #{<<"taskId">> => TaskId}),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, result_of(Ack))),
    Task = poll_until_terminal(TaskId, 40),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Task)),
    ok.

legacy_result_and_list(_Config) ->
    S = initialize(?ALICE),
    {200, _, Body} = legacy(?ALICE, S, 2, <<"tools/call">>, #{
        <<"name">> => <<"hosted">>, <<"arguments">> => #{<<"mode">> => <<"working">>}
    }),
    TaskId = maps:get(<<"taskId">>, maps:get(<<"task">>, result_of(Body))),
    {200, _, Listed} = legacy(?ALICE, S, 3, <<"tasks/list">>, #{}),
    Ids = [maps:get(<<"taskId">>, T) || T <- maps:get(<<"tasks">>, result_of(Listed))],
    ?assert(lists:member(TaskId, Ids)),
    %% Finished later by the host; tasks/result waits for it.
    _ = spawn(fun() ->
        timer:sleep(300),
        ?PROVIDER:set(TaskId, #{
            status => completed,
            result => #{<<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => <<"late">>}]}
        })
    end),
    {200, _, Res} = legacy(?ALICE, S, 4, <<"tasks/result">>, #{<<"taskId">> => TaskId}),
    ?assertEqual([#{<<"type">> => <<"text">>, <<"text">> => <<"late">>}], content(result_of(Res))),
    ok.

%% A client that did not declare the extension cannot follow a task.
%% The handler can tell, and one that ignores it fails the call.
task_refused_without_extension(_Config) ->
    Auto = result_of(call(?ALICE, 1, <<"auto">>, #{})),
    ?assertEqual([#{<<"type">> => <<"text">>, <<"text">> => <<"no task">>}], content(Auto)),
    Forced = result_of(call(?ALICE, 2, <<"force">>, #{})),
    ?assertEqual(true, maps:get(<<"isError">>, Forced)),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

tasks_caps() -> #{<<"extensions">> => #{?MCP_EXT_TASKS => #{}}}.

task_id({200, _, Body}) -> maps:get(<<"taskId">>, result_of(Body)).

content(Result) -> maps:get(<<"content">>, Result).

notifications_of(Envelope) ->
    maps:get(<<"notifications">>, maps:get(<<"params">>, Envelope)).

poll_until_terminal(_TaskId, 0) ->
    error(task_never_settled);
poll_until_terminal(TaskId, N) ->
    {200, _, Body} = tasks_get(?ALICE, TaskId),
    Task = result_of(Body),
    case maps:get(<<"status">>, Task) of
        <<"working">> ->
            timer:sleep(50),
            poll_until_terminal(TaskId, N - 1);
        _ ->
            Task
    end.

tasks_get(Key, TaskId) ->
    rpc(Key, 50, <<"tasks/get">>, #{<<"taskId">> => TaskId}).

modern_meta(Capabilities) ->
    #{
        ?MCP_META_PROTOCOL_VERSION => ?MODERN,
        ?MCP_META_CLIENT_CAPABILITIES => Capabilities
    }.

call(Key, Id, Mode, Capabilities) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{
            <<"name">> => <<"hosted">>,
            <<"arguments">> => #{<<"mode">> => Mode},
            <<"_meta">> => modern_meta(Capabilities)
        }
    }),
    post(Key, Body, [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, <<"hosted">>}
    ]).

rpc(Key, Id, Method, Params) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => modern_meta(tasks_caps())}
    }),
    post(Key, Body, [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, Method},
        {<<"mcp-name">>, maps:get(<<"taskId">>, Params)}
    ]).

initialize(Key) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{<<"tasks">> => #{}},
            <<"clientInfo">> => #{<<"name">> => <<"hosted">>, <<"version">> => <<"1.0">>}
        }
    }),
    {200, Headers, _} = post(Key, Body, []),
    proplists:get_value(<<"mcp-session-id">>, Headers).

legacy(Key, SessionId, Id, Method, Params) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }),
    post(Key, Body, [
        {<<"mcp-session-id">>, SessionId},
        {<<"mcp-protocol-version">>, <<"2025-11-25">>}
    ]).

post(Key, Body, Extra) ->
    Headers =
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"x-api-key">>, Key}
        ] ++ Extra,
    {ok, Status, RespHeaders, RespBody} = hackney:request(
        post, url(), Headers, Body, [with_body]
    ),
    {Status, RespHeaders, RespBody}.

listen(Key, Id, TaskId) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"subscriptions/listen">>,
        <<"params">> => #{
            <<"notifications">> => #{<<"taskIds">> => [TaskId]},
            <<"_meta">> => modern_meta(tasks_caps())
        }
    }),
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>},
        {<<"x-api-key">>, Key},
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"subscriptions/listen">>}
    ],
    {ok, Ref} = hackney:request(
        post, url(), Headers, Body, [async, {pool, false}, {recv_timeout, 10000}]
    ),
    Ref.

close(Ref) ->
    try
        hackney:close(Ref)
    catch
        _:_ -> ok
    end,
    ok.

%% Bytes read past the last event are kept for the next call, per
%% stream.
next_event(Ref) ->
    Buf = erase({sse_buf, Ref}),
    collect(Ref, erlang:monotonic_time(millisecond) + 5000, buffered(Buf)).

buffered(undefined) -> <<>>;
buffered(Buf) -> Buf.

collect(Ref, Deadline, Buf) ->
    case take(Buf) of
        {ok, Event, Rest} ->
            put({sse_buf, Ref}, Rest),
            Event;
        more ->
            receive
                {hackney_response, Ref, {status, _, _}} ->
                    collect(Ref, Deadline, Buf);
                {hackney_response, Ref, {headers, _}} ->
                    collect(Ref, Deadline, Buf);
                {hackney_response, Ref, Chunk} when is_binary(Chunk) ->
                    collect(Ref, Deadline, <<Buf/binary, Chunk/binary>>);
                {hackney_response, Ref, done} ->
                    closed
            after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
                timeout
            end
    end.

take(Buf) ->
    case binary:split(Buf, <<"\n\n">>) of
        [Block, Rest] ->
            case [V || <<"data: ", V/binary>> <- binary:split(Block, <<"\n">>, [global])] of
                [Data | _] -> {ok, json:decode(Data), Rest};
                [] -> take(Rest)
            end;
        _ ->
            more
    end.

envelope_of(Body) ->
    case binary:match(Body, <<"data: ">>) of
        nomatch ->
            json:decode(Body);
        _ ->
            Datas = [D || <<"data: ", D/binary>> <- binary:split(Body, <<"\n">>, [global])],
            json:decode(lists:last(Datas))
    end.

result_of({_, _, Body}) -> result_of(Body);
result_of(Body) -> maps:get(<<"result">>, envelope_of(Body)).

error_of(Body) -> maps:get(<<"error">>, envelope_of(Body)).

url() ->
    list_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [?PORT])).
