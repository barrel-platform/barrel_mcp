%%%-------------------------------------------------------------------
%%% @doc The engine's `tool_filter': one registry, several endpoints,
%%% each listing and calling only its own tools. Driven through
%%% `barrel_mcp_http_engine:handle/6' the way an embedder serves it.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_tool_filter_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([echo/1]).

-define(MODERN, <<"2026-07-28">>).

tool_filter_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 60, [
            {"no filter lists and calls every tool", fun no_filter/0},
            {"a hidden tool is absent and answers as unknown", fun hidden_is_unknown/0},
            {"filtered pages keep their cursors", fun pages_stay_valid/0},
            {"two endpoints side by side", fun two_endpoints/0},
            {"the simple transport honours the filter", fun simple_transport/0},
            {"a legacy session honours the filter", fun legacy_session/0},
            {"a modern request honours the filter", fun modern_request/0},
            {"a hidden task-required tool is not refused", fun hidden_task_required/0},
            {"a hidden tool has no header bindings", fun hidden_header_params/0},
            {"a raising filter hides the tool", fun raising_filter/0}
        ]}}.

setup() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp_http_engine:ensure_session_manager(),
    lists:foreach(fun reg/1, names()),
    ok = barrel_mcp:reg_tool(<<"tf_required">>, ?MODULE, echo, #{
        description => <<"Needs a task">>,
        task_support => required
    }),
    ok = barrel_mcp:reg_tool(<<"tf_regional">>, ?MODULE, echo, #{
        description => <<"Mirrors a header">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"region">> => #{
                    <<"type">> => <<"string">>,
                    <<"x-mcp-header">> => <<"Region">>
                }
            }
        }
    }),
    ok.

cleanup(_) ->
    lists:foreach(fun(N) -> barrel_mcp_registry:unreg(tool, N) end, all_names()),
    ok.

echo(_Args) ->
    <<"ran">>.

%% 120 tools; the even ones are "a", the odd ones "b".
names() ->
    [iolist_to_binary(io_lib:format("tf_~3..0b", [I])) || I <- lists:seq(0, 119)].

all_names() ->
    names() ++ [<<"tf_required">>, <<"tf_regional">>].

reg(Name) ->
    ok = barrel_mcp:reg_tool(Name, ?MODULE, echo, #{description => <<"test">>}).

side(<<"tf_", N/binary>>) ->
    case binary_to_integer(N) rem 2 of
        0 -> a;
        1 -> b
    end.

only(Side) ->
    fun(Name, _Handler) -> is_ours(Name) andalso side(Name) =:= Side end.

is_ours(<<"tf_", N/binary>>) ->
    try binary_to_integer(N) of
        _ -> true
    catch
        error:badarg -> false
    end;
is_ours(_) ->
    false.

%%====================================================================
%% Cases
%%====================================================================

no_filter() ->
    Config = config(#{}),
    Listed = list_all(Config),
    ?assert(lists:all(fun(N) -> lists:member(N, Listed) end, all_names())),
    ?assertEqual(<<"ran">>, call_text(Config, <<"tf_001">>)).

hidden_is_unknown() ->
    Config = config(#{tool_filter => only(a)}),
    Listed = list_all(Config),
    ?assertNot(lists:member(<<"tf_001">>, Listed)),
    ?assert(lists:member(<<"tf_000">>, Listed)),
    assert_unknown(<<"tf_001">>, fun(N) -> call(Config, N) end),
    ?assertEqual(<<"ran">>, call_text(Config, <<"tf_000">>)).

pages_stay_valid() ->
    Config = config(#{tool_filter => only(b)}),
    Pages = list_pages(Config, undefined, []),
    ?assert(length(Pages) >= 2),
    Listed = lists:append(Pages),
    Expected = [N || N <- names(), side(N) =:= b],
    ?assertEqual(60, length(Listed)),
    ?assertEqual(lists:sort(Expected), lists:sort(Listed)),
    ?assertEqual(length(Listed), length(lists:usort(Listed))).

two_endpoints() ->
    A = config(#{tool_filter => only(a)}),
    B = config(#{tool_filter => only(b)}),
    ListedA = list_all(A),
    ListedB = list_all(B),
    ?assertEqual(lists:sort([N || N <- names(), side(N) =:= a]), lists:sort(ListedA)),
    ?assertEqual(lists:sort([N || N <- names(), side(N) =:= b]), lists:sort(ListedB)),
    ?assertEqual(<<"ran">>, call_text(A, <<"tf_010">>)),
    assert_unknown(<<"tf_010">>, fun(N) -> call(B, N) end),
    ?assertEqual(<<"ran">>, call_text(B, <<"tf_011">>)),
    assert_unknown(<<"tf_011">>, fun(N) -> call(A, N) end).

simple_transport() ->
    Config = (config(#{tool_filter => only(a)}))#{mode => simple},
    ?assertEqual(lists:sort([N || N <- names(), side(N) =:= a]), lists:sort(list_all(Config))),
    assert_unknown(<<"tf_001">>, fun(N) -> call(Config, N) end),
    ?assertEqual(<<"ran">>, call_text(Config, <<"tf_002">>)).

legacy_session() ->
    Config = config(#{tool_filter => only(a), session_enabled => true}),
    {200, Hdrs, _} = post(Config, barrel_mcp_test_helpers:init_body(), []),
    Sid = header(<<"mcp-session-id">>, Hdrs),
    ?assert(is_binary(Sid)),
    Extra = [
        {<<"mcp-session-id">>, Sid},
        {<<"mcp-protocol-version">>, ?MCP_LATEST_LEGACY_VERSION}
    ],
    Page = result(post(Config, request(1, <<"tools/list">>, #{}), Extra)),
    Names = [maps:get(<<"name">>, T) || T <- maps:get(<<"tools">>, Page)],
    ?assertNot(lists:member(<<"tf_001">>, Names)),
    assert_unknown(<<"tf_001">>, fun(N) ->
        Params = #{<<"name">> => N, <<"arguments">> => #{}},
        result(post(Config, request(2, <<"tools/call">>, Params), Extra))
    end).

modern_request() ->
    Config = config(#{tool_filter => only(a)}),
    Page = result(post_modern(Config, 1, <<"tools/list">>, #{})),
    Names = [maps:get(<<"name">>, T) || T <- maps:get(<<"tools">>, Page)],
    ?assertNot(lists:member(<<"tf_001">>, Names)),
    assert_unknown(<<"tf_001">>, fun(N) -> modern_call(Config, N, #{}) end).

%% A modern client that never declared tasks is refused a
%% task-required tool. A hidden one must answer as unknown instead.
hidden_task_required() ->
    Visible = config(#{tool_filter => fun(N, _) -> N =:= <<"tf_required">> end}),
    Params = #{<<"name">> => <<"tf_required">>, <<"arguments">> => #{}},
    {200, _, Refused} = post_modern(Visible, 1, <<"tools/call">>, Params),
    ?assertMatch(#{<<"error">> := _}, json:decode(Refused)),
    Hidden = config(#{tool_filter => only(a)}),
    assert_unknown(<<"tf_required">>, fun(N) -> modern_call(Hidden, N, #{}) end).

%% Without the mirrored `Mcp-Param-Region' header, a visible tool is a
%% header mismatch; a hidden one has no bindings and answers as unknown.
hidden_header_params() ->
    Params = #{<<"name">> => <<"tf_regional">>, <<"arguments">> => #{<<"region">> => <<"eu">>}},
    Visible = config(#{tool_filter => fun(N, _) -> N =:= <<"tf_regional">> end}),
    {400, _, Mismatch} = post_modern(Visible, 1, <<"tools/call">>, Params),
    ?assertMatch(#{<<"error">> := #{<<"code">> := ?MCP_HEADER_MISMATCH}}, json:decode(Mismatch)),
    Hidden = config(#{tool_filter => only(a)}),
    assert_unknown(<<"tf_regional">>, fun(N) ->
        modern_call(Hidden, N, #{<<"region">> => <<"eu">>})
    end).

raising_filter() ->
    Config = config(#{tool_filter => fun(_, _) -> error(boom) end}),
    ?assertNot(lists:member(<<"tf_000">>, list_all(Config))),
    assert_unknown(<<"tf_000">>, fun(N) -> call(Config, N) end).

%%====================================================================
%% Helpers
%%====================================================================

%% A hidden tool answers exactly what a name never registered answers
%% over the same endpoint, name aside.
assert_unknown(Name, Call) ->
    Missing = <<"tf_never_registered">>,
    #{<<"content">> := [#{<<"text">> := <<"Unknown tool: ", Missing/binary>>} = Block]} =
        Expected0 = Call(Missing),
    Expected = Expected0#{
        <<"content">> => [Block#{<<"text">> => <<"Unknown tool: ", Name/binary>>}]
    },
    ?assertMatch(#{<<"isError">> := true}, Expected),
    ?assertEqual(Expected, Call(Name)).

modern_call(Config, Name, Args) ->
    Params = #{<<"name">> => Name, <<"arguments">> => Args},
    result(post_modern(Config, 2, <<"tools/call">>, Params)).

config(Extra) ->
    {ok, Auth} = barrel_mcp_http_engine:init_auth(#{}),
    maps:merge(
        #{
            mode => stream,
            auth_config => Auth,
            session_enabled => false,
            allowed_origins => any,
            allow_missing_origin => true,
            sse_buffer_size => 256,
            resource_metadata => undefined
        },
        Extra
    ).

list_all(Config) ->
    lists:append(list_pages(Config, undefined, [])).

list_pages(Config, Cursor, Acc) ->
    Params =
        case Cursor of
            undefined -> #{};
            _ -> #{<<"cursor">> => Cursor}
        end,
    Result = result(post(Config, request(1, <<"tools/list">>, Params), [])),
    Names = [
        N
     || #{<<"name">> := N} <- maps:get(<<"tools">>, Result), is_ours(N) orelse is_extra(N)
    ],
    case maps:get(<<"nextCursor">>, Result, undefined) of
        undefined -> lists:reverse([Names | Acc]);
        Next -> list_pages(Config, Next, [Names | Acc])
    end.

is_extra(N) -> N =:= <<"tf_required">> orelse N =:= <<"tf_regional">>.

call(Config, Name) ->
    Params = #{<<"name">> => Name, <<"arguments">> => #{}},
    result(post(Config, request(2, <<"tools/call">>, Params), [])).

call_text(Config, Name) ->
    #{<<"content">> := [#{<<"text">> := Text}]} = call(Config, Name),
    Text.

request(Id, Method, Params) ->
    barrel_mcp_test_helpers:request(Id, Method, Params).

post_modern(Config, Id, Method, Params) ->
    Envelope = barrel_mcp_test_helpers:modern_request(Id, Method, Params),
    Hdrs =
        [{<<"mcp-protocol-version">>, ?MODERN}] ++
            barrel_mcp_headers:standard(Method, maps:get(<<"params">>, Envelope)),
    post(Config, iolist_to_binary(json:encode(Envelope)), Hdrs).

result({200, _, Body}) ->
    #{<<"result">> := Result} = json:decode(Body),
    Result.

%% Answers either as one JSON body or as an SSE stream; both come back
%% as `{Status, Headers, JsonBody}'.
post(Config, Body, Extra) ->
    Self = self(),
    Ref = make_ref(),
    Responder = #{
        reply => fun(Status, Hdrs, B) ->
            Self ! {Ref, reply, Status, Hdrs, iolist_to_binary(B)},
            ok
        end,
        stream_start => fun(Status, Hdrs) ->
            Self ! {Ref, stream_start, Status, Hdrs},
            ok
        end,
        stream_chunk => fun(Chunk) ->
            Self ! {Ref, chunk, iolist_to_binary(Chunk)},
            ok
        end,
        stream_end => fun() ->
            Self ! {Ref, stream_end},
            ok
        end
    },
    Headers =
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ] ++ Extra,
    ok = barrel_mcp_http_engine:handle(<<"POST">>, <<"/mcp">>, Headers, Body, Responder, Config),
    receive
        {Ref, reply, Status, Hdrs, B} ->
            {Status, Hdrs, B};
        {Ref, stream_start, Status, Hdrs} ->
            {Status, Hdrs, collect(Ref, <<>>)}
    after 5000 ->
        error(no_reply)
    end.

collect(Ref, Acc) ->
    receive
        {Ref, chunk, C} -> collect(Ref, <<Acc/binary, C/binary>>);
        {Ref, stream_end} -> last_data(Acc)
    after 5000 ->
        error(stream_timeout)
    end.

last_data(Sse) ->
    Lines = binary:split(Sse, <<"\n">>, [global]),
    lists:last([D || <<"data: ", D/binary>> <- Lines, D =/= <<>>]).

header(Name, Hdrs) when is_map(Hdrs) -> maps:get(Name, Hdrs, undefined);
header(Name, Hdrs) -> proplists:get_value(Name, Hdrs).
