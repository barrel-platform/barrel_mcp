%%%-------------------------------------------------------------------
%%% @doc Common-test suite for async tool execution: cancel and
%%% progress round-trips.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_async_tools_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([cancel_returns_empty_body/1,
         progress_emits_events/1,
         tool_error_returns_isError/1]).

%% Tool handlers used by the suite.
-export([slow_tool/2, progress_tool/2, error_tool/1]).

-define(BASE_PORT, 22200).

all() -> [
    cancel_returns_empty_body,
    progress_emits_events,
    tool_error_returns_isError
].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    catch barrel_mcp:stop_http_stream(),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(TC, Config) ->
    Port = ?BASE_PORT + erlang:phash2(TC, 100),
    [{port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    catch barrel_mcp:stop_http_stream(),
    timer:sleep(50),
    ok.

%%====================================================================
%% Cancel
%%====================================================================

cancel_returns_empty_body(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                             session_enabled => true}),
    ok = barrel_mcp_registry:reg(tool, <<"slow">>, ?MODULE, slow_tool, #{}),

    {200, IH, _} = post_init(Port),
    SessionId = proplists:get_value(<<"mcp-session-id">>, IH),

    %% Issue the slow tool call asynchronously so we can fire the
    %% cancel from a separate process.
    Self = self(),
    Caller = spawn_link(fun() ->
        {ok, S, _, B} = hackney:request(post, url(Port),
            [{<<"content-type">>, <<"application/json">>},
             {<<"accept">>, <<"application/json, text/event-stream">>},
             {<<"mcp-session-id">>, SessionId}],
            tool_call_body(<<"slow">>, 7), [with_body]),
        Self ! {tool_call_returned, S, B}
    end),

    %% Give the worker a moment to register as in-flight.
    timer:sleep(150),

    %% Send cancel.
    Cancel = json:encode(#{<<"jsonrpc">> => <<"2.0">>,
                           <<"method">> => <<"notifications/cancelled">>,
                           <<"params">> => #{<<"requestId">> => 7}}),
    {ok, 202, _, _} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>},
         {<<"mcp-session-id">>, SessionId}],
        Cancel, [with_body]),

    receive
        {tool_call_returned, Status, Body} ->
            ?assertEqual(200, Status),
            ?assertEqual(<<>>, Body)
    after 5000 ->
        exit(Caller, kill),
        ?assert(false)
    end,
    ok = barrel_mcp_registry:unreg(tool, <<"slow">>),
    ok.

%%====================================================================
%% Progress
%%====================================================================

progress_emits_events(Config) ->
    process_flag(trap_exit, true),
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                             session_enabled => true}),
    ok = barrel_mcp_registry:reg(tool, <<"prog">>, ?MODULE, progress_tool, #{}),

    {200, IH, _} = post_init(Port),
    SessionId = proplists:get_value(<<"mcp-session-id">>, IH),

    Self = self(),
    Sse = spawn(fun() ->
        {ok, Ref} = hackney:request(get, url(Port),
            [{<<"accept">>, <<"text/event-stream">>},
             {<<"mcp-session-id">>, SessionId}],
            <<>>, [async, {recv_timeout, infinity}]),
        sse_collect(Ref, Self)
    end),
    timer:sleep(150),

    %% Call the tool with a progressToken; the tool emits 3 events.
    Body = tool_call_with_progress(<<"prog">>, 11, <<"tok-1">>),
    {ok, 200, _, RespBody} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>},
         {<<"mcp-session-id">>, SessionId}],
        Body, [with_body]),
    Resp = json:decode(RespBody),
    ?assertEqual(11, maps:get(<<"id">>, Resp)),
    ?assert(maps:is_key(<<"result">>, Resp)),

    %% Drain progress events from the SSE collector. Three are
    %% expected before the run completes; the response above already
    %% returned, so the events are buffered in the collector mailbox.
    Events = collect_progress(3, []),
    ?assertEqual(3, length(Events)),
    [E1 | _] = Events,
    ?assertEqual(<<"notifications/progress">>, maps:get(<<"method">>, E1)),
    ?assertEqual(<<"tok-1">>,
                 maps:get(<<"progressToken">>, maps:get(<<"params">>, E1))),
    exit(Sse, kill),
    ok = barrel_mcp_registry:unreg(tool, <<"prog">>),
    ok.

%%====================================================================
%% isError
%%====================================================================

tool_error_returns_isError(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                             session_enabled => true}),
    ok = barrel_mcp_registry:reg(tool, <<"err">>, ?MODULE, error_tool, #{}),
    {200, IH, _} = post_init(Port),
    SessionId = proplists:get_value(<<"mcp-session-id">>, IH),
    Body = tool_call_body(<<"err">>, 21),
    {ok, 200, _, RB} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>},
         {<<"mcp-session-id">>, SessionId}],
        Body, [with_body]),
    Resp = json:decode(RB),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(true, maps:get(<<"isError">>, Result)),
    [Block | _] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)),
    ok = barrel_mcp_registry:unreg(tool, <<"err">>),
    ok.

%%====================================================================
%% Tool implementations
%%====================================================================

slow_tool(_Args, _Ctx) ->
    receive
        {cancel, _} -> {tool_error, [#{<<"type">> => <<"text">>,
                                        <<"text">> => <<"cancelled">>}]}
    after 30000 ->
        <<"slept">>
    end.

progress_tool(_Args, Ctx) ->
    Emit = maps:get(emit_progress, Ctx),
    Emit(0.25, 1.0, undefined),
    Emit(0.50, 1.0, undefined),
    Emit(0.75, 1.0, undefined),
    timer:sleep(80),
    <<"done">>.

error_tool(_Args) ->
    {tool_error, [#{<<"type">> => <<"text">>, <<"text">> => <<"boom">>}]}.

%%====================================================================
%% Helpers
%%====================================================================

url(Port) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])).

post_init(Port) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{<<"name">> => <<"async-suite">>,
                                  <<"version">> => <<"1.0">>}
        }
    }),
    {ok, S, H, B} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>}],
        Body, [with_body]),
    {S, H, B}.

tool_call_body(Name, Id) ->
    json:encode(#{<<"jsonrpc">> => <<"2.0">>,
                  <<"id">> => Id,
                  <<"method">> => <<"tools/call">>,
                  <<"params">> => #{<<"name">> => Name,
                                    <<"arguments">> => #{}}}).

tool_call_with_progress(Name, Id, Token) ->
    json:encode(#{<<"jsonrpc">> => <<"2.0">>,
                  <<"id">> => Id,
                  <<"method">> => <<"tools/call">>,
                  <<"params">> => #{<<"name">> => Name,
                                    <<"arguments">> => #{},
                                    <<"_meta">> =>
                                        #{<<"progressToken">> => Token}}}).

%% Collect SSE events from an async hackney stream. Forwards each
%% parsed `data:' JSON envelope to `Reporter' as `{progress, Map}'.
sse_collect(Ref, Reporter) ->
    sse_collect(Ref, Reporter, <<>>).

sse_collect(Ref, Reporter, Buf) ->
    receive
        {hackney_response, Ref, {status, _, _}} ->
            sse_collect(Ref, Reporter, Buf);
        {hackney_response, Ref, {headers, _}} ->
            sse_collect(Ref, Reporter, Buf);
        {hackney_response, Ref, Chunk} when is_binary(Chunk) ->
            {Events, NewBuf} = split_sse(<<Buf/binary, Chunk/binary>>),
            lists:foreach(fun(D) ->
                try Reporter ! {progress, json:decode(D)}
                catch _:_ -> ok end
            end, Events),
            sse_collect(Ref, Reporter, NewBuf);
        {hackney_response, Ref, done} -> ok
    end.

split_sse(Buf) ->
    case binary:split(Buf, <<"\n\n">>, [global]) of
        [_] -> {[], Buf};
        Parts ->
            {Events, [Tail]} = lists:split(length(Parts) - 1, Parts),
            Datas = [extract_data(E) || E <- Events],
            {[D || D <- Datas, D =/= undefined], Tail}
    end.

extract_data(Block) ->
    Lines = binary:split(Block, <<"\n">>, [global]),
    Datas = lists:filtermap(fun
        (<<"data: ", V/binary>>) -> {true, V};
        (<<"data:", V/binary>>) -> {true, string:trim(V)};
        (_) -> false
    end, Lines),
    case Datas of
        [] -> undefined;
        [D | _] -> D
    end.

collect_progress(0, Acc) -> lists:reverse(Acc);
collect_progress(N, Acc) ->
    receive
        {progress, Msg} ->
            case maps:get(<<"method">>, Msg, <<>>) of
                <<"notifications/progress">> ->
                    collect_progress(N - 1, [Msg | Acc]);
                _ ->
                    collect_progress(N, Acc)
            end
    after 5000 ->
        lists:reverse(Acc)
    end.
