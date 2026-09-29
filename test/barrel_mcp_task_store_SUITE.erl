%%%-------------------------------------------------------------------
%%% @doc barrel_mcp's own tasks kept in a configured store that outlives
%%% the application, as a durable one would.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_task_store_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    completed_task_survives/1,
    working_task_interrupted/1,
    input_required_task_resumes/1,
    admission_without_count/1
]).
-export([quick_tool/1, stuck_tool/1, asking_tool/2]).

-define(PORT, 22380).
-define(MODERN, <<"2026-07-28">>).
-define(OWNER, {principal, anonymous}).

all() ->
    [
        completed_task_survives,
        working_task_interrupted,
        input_required_task_resumes,
        admission_without_count
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hackney),
    Holder = barrel_mcp_test_task_store:start_table(),
    _ = application:stop(barrel_mcp),
    _ = application:load(barrel_mcp),
    application:set_env(barrel_mcp, task_store, barrel_mcp_test_task_store),
    {ok, _} = application:ensure_all_started(barrel_mcp),
    [{holder, Holder} | Config].

end_per_suite(Config) ->
    ok = application:stop(barrel_mcp),
    application:unset_env(barrel_mcp, task_store),
    {ok, _} = application:ensure_all_started(barrel_mcp),
    barrel_mcp_test_task_store:stop_table(?config(holder, Config)).

init_per_testcase(_TC, Config) ->
    ok = serve(),
    Config.

end_per_testcase(_TC, _Config) ->
    _ = barrel_mcp:stop_http_stream(),
    ok.

serve() ->
    ok = barrel_mcp_registry:wait_for_ready(),
    Opts = #{task_support => optional},
    ok = barrel_mcp:reg_tool(<<"quick">>, ?MODULE, quick_tool, Opts),
    ok = barrel_mcp:reg_tool(<<"stuck">>, ?MODULE, stuck_tool, Opts),
    ok = barrel_mcp:reg_tool(<<"asking">>, ?MODULE, asking_tool, Opts),
    {ok, _} = barrel_mcp:start_http_stream(#{port => ?PORT}),
    ok.

restart() ->
    _ = barrel_mcp:stop_http_stream(),
    ok = application:stop(barrel_mcp),
    {ok, _} = application:ensure_all_started(barrel_mcp),
    serve().

%% Longer than the inline window, so each call becomes a task.
quick_tool(_Args) ->
    timer:sleep(300),
    <<"finished">>.

stuck_tool(_Args) ->
    timer:sleep(60000),
    <<"never">>.

asking_tool(_Args, Ctx) ->
    timer:sleep(300),
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

%%====================================================================
%% Cases
%%====================================================================

completed_task_survives(_Config) ->
    TaskId = task_id(call(1, <<"quick">>)),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, poll(TaskId, <<"working">>, 40))),
    ok = restart(),
    Task = get_task(TaskId),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Task)),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Task)),
    ?assertEqual(<<"finished">>, maps:get(<<"text">>, Block)),
    ok.

working_task_interrupted(_Config) ->
    TaskId = task_id(call(1, <<"stuck">>)),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, get_task(TaskId))),
    ok = restart(),
    Task = get_task(TaskId),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, Task)),
    ?assertEqual(
        <<"Task interrupted by a restart">>,
        maps:get(<<"message">>, maps:get(<<"error">>, Task))
    ),
    %% A result arriving from the old run does not revive it.
    ok = barrel_mcp_tasks:finish(?OWNER, TaskId, #{<<"content">> => []}),
    ?assertEqual(<<"failed">>, maps:get(<<"status">>, get_task(TaskId))),
    ok.

input_required_task_resumes(_Config) ->
    TaskId = task_id(call(1, <<"asking">>)),
    Parked = poll(TaskId, <<"working">>, 40),
    ?assertEqual(<<"input_required">>, maps:get(<<"status">>, Parked)),
    ok = restart(),
    ?assertEqual(<<"input_required">>, maps:get(<<"status">>, get_task(TaskId))),
    {200, _, Ack} = rpc(2, <<"tasks/update">>, #{
        <<"taskId">> => TaskId,
        <<"inputResponses">> => #{
            <<"who">> => #{
                <<"action">> => <<"accept">>, <<"content">> => #{<<"name">> => <<"ada">>}
            }
        }
    }),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, result_of(Ack))),
    Done = poll(TaskId, <<"working">>, 40),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Done)),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Done)),
    ?assertEqual(<<"hello ada">>, maps:get(<<"text">>, Block)),
    ok.

admission_without_count(_Config) ->
    application:set_env(barrel_mcp, max_tasks_per_principal, 1),
    try
        Owner = {principal, {?MODULE, admission}},
        {ok, _} = barrel_mcp_tasks:create(Owner, <<"tools/call">>, #{}),
        ?assertEqual(
            {error, too_many_tasks}, barrel_mcp_tasks:create(Owner, <<"tools/call">>, #{})
        )
    after
        application:unset_env(barrel_mcp, max_tasks_per_principal)
    end.

%%====================================================================
%% Helpers
%%====================================================================

tasks_caps() -> #{<<"extensions">> => #{?MCP_EXT_TASKS => #{}}}.

task_id({200, _, Body}) ->
    Result = result_of(Body),
    ?assertEqual(<<"task">>, maps:get(<<"resultType">>, Result)),
    maps:get(<<"taskId">>, Result).

get_task(TaskId) ->
    {200, _, Body} = rpc(50, <<"tasks/get">>, #{<<"taskId">> => TaskId}),
    result_of(Body).

poll(_TaskId, _While, 0) ->
    error(task_never_settled);
poll(TaskId, While, N) ->
    Task = get_task(TaskId),
    case maps:get(<<"status">>, Task) of
        While ->
            timer:sleep(50),
            poll(TaskId, While, N - 1);
        _ ->
            Task
    end.

meta() ->
    #{
        ?MCP_META_PROTOCOL_VERSION => ?MODERN,
        ?MCP_META_CLIENT_CAPABILITIES => tasks_caps()
    }.

call(Id, Name) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{<<"name">> => Name, <<"arguments">> => #{}, <<"_meta">> => meta()}
    }),
    post(Body, [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, Name}
    ]).

rpc(Id, Method, Params) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => meta()}
    }),
    post(Body, [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, Method},
        {<<"mcp-name">>, maps:get(<<"taskId">>, Params)}
    ]).

post(Body, Extra) ->
    Headers =
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ] ++ Extra,
    Url = list_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [?PORT])),
    {ok, Status, RespHeaders, RespBody} = hackney:request(
        post, Url, Headers, Body, [with_body]
    ),
    {Status, RespHeaders, RespBody}.

result_of(Body) -> maps:get(<<"result">>, json:decode(Body)).
