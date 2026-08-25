%%%-------------------------------------------------------------------
%%% @doc A legacy task that needs input from the client.
%%%
%%% Both eras have the `input_required' status and neither reaches it
%%% the same way. A legacy task has a session with a stream to send
%%% down, so the server issues a real `elicitation/create' and waits,
%%% exactly as a non-task handler does. Only a modern task, which has
%%% no back-channel, parks and waits for `tasks/update'.
%%%
%%% The outbound request goes through the session's own pending-request
%%% registry, the one sampling and roots already use, so an id is never
%%% allocated twice for a session.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_legacy_task_input_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([asking_tool/2]).

legacy_task_input_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"A legacy task asks over the session stream", fun asks_and_completes/0},
        {"The request carries related-task metadata", fun carries_related_task/0}
    ]}.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp_registry:reg(tool, <<"legacy_asking">>, ?MODULE, asking_tool, #{
        long_running => true
    }),
    ok.

cleanup(_) ->
    barrel_mcp_registry:unreg(tool, <<"legacy_asking">>),
    ok.

asking_tool(_Args, Ctx) ->
    case barrel_mcp:input(Ctx, <<"who">>) of
        {ok, #{<<"content">> := #{<<"name">> := Name}}} ->
            <<"hello ", Name/binary>>;
        _ ->
            {input_required,
                #{
                    <<"who">> => #{
                        method => <<"elicitation/create">>,
                        params => #{<<"message">> => <<"Your name?">>}
                    }
                },
                seed}
    end.

%% Stands in for the client's SSE stream: captures what the server
%% sends and answers it the way a client would.
fake_client(Test, Answer) ->
    spawn(fun() -> fake_client_loop(Test, Answer) end).

fake_client_loop(Test, Answer) ->
    receive
        {sse_send_message, #{<<"id">> := Id, <<"method">> := Method} = Request} ->
            Test ! {sent, Request},
            _ = barrel_mcp_session:deliver_response(Id, #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => Id,
                <<"result">> => Answer
            }),
            _ = Method,
            fake_client_loop(Test, Answer);
        _Other ->
            fake_client_loop(Test, Answer)
    end.

start_session(Answer) ->
    {ok, SessionId} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_client_capabilities(SessionId, #{<<"elicitation">> => #{}}),
    Pid = fake_client(self(), Answer),
    ok = barrel_mcp_session:set_sse_pid(SessionId, Pid),
    SessionId.

drive(SessionId) ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{
            <<"name">> => <<"legacy_asking">>,
            <<"arguments">> => #{}
        }
    },
    {async, Plan} = barrel_mcp_protocol:handle(Request, #{session_id => SessionId}),
    barrel_mcp_protocol:drive_async_plan(Plan, 5000, undefined).

wait_for(SessionId, TaskId, Status, 0) ->
    {ok, T} = barrel_mcp_tasks:get(SessionId, TaskId),
    error({never_reached, Status, maps:get(<<"status">>, T)});
wait_for(SessionId, TaskId, Status, N) ->
    {ok, T} = barrel_mcp_tasks:get(SessionId, TaskId),
    case maps:get(<<"status">>, T) of
        Status ->
            T;
        _ ->
            timer:sleep(25),
            wait_for(SessionId, TaskId, Status, N - 1)
    end.

flush_sent() ->
    receive
        {sent, _} -> flush_sent()
    after 0 -> ok
    end.

asks_and_completes() ->
    SessionId = start_session(#{
        <<"action">> => <<"accept">>,
        <<"content">> => #{<<"name">> => <<"ada">>}
    }),
    Resp = drive(SessionId),
    TaskId = maps:get(<<"taskId">>, maps:get(<<"task">>, maps:get(<<"result">>, Resp))),
    %% The server asked, the client answered, and the handler ran again.
    Task = wait_for(SessionId, TaskId, <<"completed">>, 80),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Task)),
    ?assertEqual(<<"hello ada">>, maps:get(<<"text">>, Block)).

carries_related_task() ->
    %% Both cases report into this process, so anything left from the
    %% previous one would be read as this one's request.
    flush_sent(),
    SessionId = start_session(#{
        <<"action">> => <<"accept">>,
        <<"content">> => #{<<"name">> => <<"ada">>}
    }),
    Resp = drive(SessionId),
    TaskId = maps:get(<<"taskId">>, maps:get(<<"task">>, maps:get(<<"result">>, Resp))),
    Sent =
        receive
            {sent, Request} -> Request
        after 5000 -> error(no_request_sent)
        end,
    ?assertEqual(<<"elicitation/create">>, maps:get(<<"method">>, Sent)),
    Meta = maps:get(<<"_meta">>, maps:get(<<"params">>, Sent)),
    Related = maps:get(?MCP_META_RELATED_TASK, Meta),
    %% The task it belongs to, not the session it travelled on.
    ?assertEqual(TaskId, maps:get(<<"taskId">>, Related)).
