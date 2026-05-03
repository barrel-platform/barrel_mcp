%%%-------------------------------------------------------------------
%%% @doc Common-test coverage for tasks, structured tool output,
%%% completions, metadata fields, and SSE replay.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_spec_additives_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([
    metadata_surfaces_in_list/1,
    structured_output_round_trip/1,
    structured_output_validation_fails/1,
    completion_dispatch/1,
    long_running_returns_taskid/1,
    sse_replay_after_reconnect/1
]).

%% Tool / completion handlers.
-export([
    titled_tool/1,
    structured_tool/1,
    bad_structured_tool/1,
    long_tool/2,
    suggest_lengths/2
]).

-define(BASE_PORT, 27300).

all() -> [
    metadata_surfaces_in_list,
    structured_output_round_trip,
    structured_output_validation_fails,
    completion_dispatch,
    long_running_returns_taskid,
    sse_replay_after_reconnect
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
    %% Use a stable index per case so re-runs reuse the same port
    %% only after end_per_testcase has stopped the listener.
    Port = ?BASE_PORT + case TC of
                            metadata_surfaces_in_list -> 1;
                            structured_output_round_trip -> 2;
                            structured_output_validation_fails -> 3;
                            completion_dispatch -> 4;
                            long_running_returns_taskid -> 5;
                            sse_replay_after_reconnect -> 6
                        end,
    [{port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    catch barrel_mcp:stop_http_stream(),
    timer:sleep(200),
    ok.

%%====================================================================
%% Metadata
%%====================================================================

metadata_surfaces_in_list(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                             session_enabled => false}),
    ok = barrel_mcp_registry:reg(tool, <<"titled">>, ?MODULE, titled_tool, #{
        description => <<"A titled tool">>,
        title => <<"Friendly Tool Name">>,
        icons => [#{<<"src">> => <<"https://example.test/icon.png">>,
                    <<"sizes">> => <<"32x32">>}]
    }),
    Body = json:encode(#{<<"jsonrpc">> => <<"2.0">>,
                         <<"id">> => 1,
                         <<"method">> => <<"tools/list">>}),
    {ok, 200, _, Resp} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json">>}],
        Body, [with_body]),
    Result = maps:get(<<"result">>, json:decode(Resp)),
    [Tool] = lists:filter(fun(T) ->
        maps:get(<<"name">>, T) =:= <<"titled">>
    end, maps:get(<<"tools">>, Result)),
    ?assertEqual(<<"Friendly Tool Name">>, maps:get(<<"title">>, Tool)),
    ?assertMatch([_], maps:get(<<"icons">>, Tool)),
    ok = barrel_mcp_registry:unreg(tool, <<"titled">>),
    ok.

%%====================================================================
%% Structured output
%%====================================================================

structured_output_round_trip(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                             session_enabled => false}),
    ok = barrel_mcp_registry:reg(tool, <<"structured">>, ?MODULE,
                                  structured_tool, #{
        output_schema => #{<<"type">> => <<"object">>,
                            <<"required">> => [<<"answer">>]}
    }),
    Body = call_body(<<"structured">>, 5),
    {ok, 200, _, Resp} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json">>}],
        Body, [with_body]),
    Result = maps:get(<<"result">>, json:decode(Resp)),
    Structured = maps:get(<<"structuredContent">>, Result),
    ?assertEqual(<<"42">>, maps:get(<<"answer">>, Structured)),
    ?assertMatch([_ | _], maps:get(<<"content">>, Result)),
    ok = barrel_mcp_registry:unreg(tool, <<"structured">>),
    ok.

structured_output_validation_fails(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                             session_enabled => false}),
    ok = barrel_mcp_registry:reg(tool, <<"badstruct">>, ?MODULE,
                                  bad_structured_tool, #{
        output_schema => #{<<"type">> => <<"object">>,
                            <<"required">> => [<<"answer">>]},
        validate_output => true
    }),
    Body = call_body(<<"badstruct">>, 6),
    {ok, 200, _, Resp} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json">>}],
        Body, [with_body]),
    Result = maps:get(<<"result">>, json:decode(Resp)),
    ?assertEqual(true, maps:get(<<"isError">>, Result)),
    ok = barrel_mcp_registry:unreg(tool, <<"badstruct">>),
    ok.

%%====================================================================
%% Completions
%%====================================================================

completion_dispatch(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                             session_enabled => false}),
    ok = barrel_mcp:reg_completion({prompt, <<"summarize">>, <<"length">>},
                                   ?MODULE, suggest_lengths, #{}),
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>, <<"id">> => 7,
        <<"method">> => <<"completion/complete">>,
        <<"params">> => #{
            <<"ref">> => #{<<"type">> => <<"ref/prompt">>,
                            <<"name">> => <<"summarize">>},
            <<"argument">> => #{<<"name">> => <<"length">>,
                                 <<"value">> => <<"sh">>}
        }
    }),
    {ok, 200, _, Resp} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json">>}],
        Body, [with_body]),
    Completion = maps:get(<<"completion">>,
                          maps:get(<<"result">>, json:decode(Resp))),
    Values = maps:get(<<"values">>, Completion),
    ?assertEqual([<<"short">>], Values),
    ok = barrel_mcp:unreg_completion({prompt, <<"summarize">>, <<"length">>}),
    ok.

%%====================================================================
%% Tasks
%%====================================================================

long_running_returns_taskid(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port,
                                             session_enabled => true}),
    ok = barrel_mcp_registry:reg(tool, <<"long">>, ?MODULE, long_tool, #{
        long_running => true
    }),
    {200, IH, _} = post_init(Port),
    SessionId = proplists:get_value(<<"mcp-session-id">>, IH),
    Body = call_body(<<"long">>, 9),
    {ok, 200, _, Resp} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json">>},
         {<<"mcp-session-id">>, SessionId}],
        Body, [with_body]),
    Result = maps:get(<<"result">>, json:decode(Resp)),
    TaskId = maps:get(<<"taskId">>, Result),
    ?assertEqual(<<"running">>, maps:get(<<"status">>, Result)),
    %% Wait for the worker to finish.
    timer:sleep(200),
    {ok, 200, _, GetResp} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json">>},
         {<<"mcp-session-id">>, SessionId}],
        json:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 10,
                      <<"method">> => <<"tasks/get">>,
                      <<"params">> => #{<<"taskId">> => TaskId}}),
        [with_body]),
    GetResult = maps:get(<<"result">>, json:decode(GetResp)),
    ?assertEqual(<<"success">>, maps:get(<<"status">>, GetResult)),
    ok = barrel_mcp_registry:unreg(tool, <<"long">>),
    ok.

%%====================================================================
%% SSE replay
%%====================================================================

sse_replay_after_reconnect(_Config) ->
    %% The buffer + replay mechanics are exercised at the session
    %% API directly; the HTTP-layer integration is exercised in the
    %% async-tools suite via the long-running task notifications.
    {ok, SessionId} = barrel_mcp_session:create(#{}),
    ok = barrel_mcp_session:set_sse_buffer_max(SessionId, 16),
    [ok = barrel_mcp_session:record_sse_event(
            SessionId,
            integer_to_binary(N),
            #{<<"params">> => #{<<"n">> => N}})
     || N <- lists:seq(1, 3)],

    %% Replay events newer than "1" — expect [2, 3] in order.
    {ok, Events} = barrel_mcp_session:events_since(SessionId, <<"1">>),
    ?assertEqual([{<<"2">>, #{<<"params">> => #{<<"n">> => 2}}},
                  {<<"3">>, #{<<"params">> => #{<<"n">> => 3}}}],
                 Events),

    %% A Last-Event-ID outside the window returns `truncated'.
    ?assertEqual(truncated,
                 barrel_mcp_session:events_since(SessionId,
                                                  <<"way-too-old">>)),

    barrel_mcp_session:delete(SessionId),
    ok.

%%====================================================================
%% Tool / completion implementations
%%====================================================================

titled_tool(_) -> <<"hi">>.

structured_tool(_) ->
    {structured, #{<<"answer">> => <<"42">>},
     [#{<<"type">> => <<"text">>, <<"text">> => <<"answer is 42">>}]}.

bad_structured_tool(_) ->
    %% Output doesn't satisfy the schema (missing `answer').
    {structured, #{<<"unrelated">> => <<"oops">>}}.

long_tool(_Args, _Ctx) ->
    timer:sleep(100),
    <<"done">>.

suggest_lengths(<<"sh">>, _Ctx) -> {ok, [<<"short">>]};
suggest_lengths(_, _Ctx) -> {ok, []}.

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
            <<"clientInfo">> => #{<<"name">> => <<"add-suite">>,
                                  <<"version">> => <<"1.0">>}
        }
    }),
    {ok, S, H, B} = hackney:request(post, url(Port),
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json">>}],
        Body, [with_body]),
    {S, H, B}.

call_body(Name, Id) ->
    json:encode(#{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id,
                  <<"method">> => <<"tools/call">>,
                  <<"params">> => #{<<"name">> => Name,
                                    <<"arguments">> => #{}}}).

