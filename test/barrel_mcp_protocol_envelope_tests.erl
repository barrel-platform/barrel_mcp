%%%-------------------------------------------------------------------
%%% @doc Pure tests for the JSON-RPC envelope helpers in
%%% `barrel_mcp_protocol'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_protocol_envelope_tests).

-include_lib("eunit/include/eunit.hrl").

encode_request_test() ->
    M = barrel_mcp_protocol:encode_request(7, <<"tools/call">>, #{<<"a">> => 1}),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, M)),
    ?assertEqual(7, maps:get(<<"id">>, M)),
    ?assertEqual(<<"tools/call">>, maps:get(<<"method">>, M)),
    ?assertEqual(#{<<"a">> => 1}, maps:get(<<"params">>, M)).

encode_notification_test() ->
    M = barrel_mcp_protocol:encode_notification(<<"notifications/initialized">>, #{}),
    ?assertNot(maps:is_key(<<"id">>, M)),
    ?assertEqual(<<"notifications/initialized">>, maps:get(<<"method">>, M)).

decode_request_test() ->
    M = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>,
        <<"params">> => #{}
    },
    ?assertEqual(
        {request, 1, <<"ping">>, #{}},
        barrel_mcp_protocol:decode_envelope(M)
    ).

decode_notification_test() ->
    M = #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"x">>},
    ?assertEqual(
        {notification, <<"x">>, #{}},
        barrel_mcp_protocol:decode_envelope(M)
    ).

decode_response_test() ->
    M = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 9,
        <<"result">> => #{<<"ok">> => true}
    },
    ?assertEqual(
        {response, 9, #{<<"ok">> => true}},
        barrel_mcp_protocol:decode_envelope(M)
    ).

decode_error_test() ->
    M = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 9,
        <<"error">> => #{<<"code">> => -32601, <<"message">> => <<"nope">>}
    },
    ?assertMatch(
        {error, 9, -32601, <<"nope">>, undefined},
        barrel_mcp_protocol:decode_envelope(M)
    ).

decode_invalid_test() ->
    ?assertMatch(
        {invalid, _},
        barrel_mcp_protocol:decode_envelope(#{})
    ).

%%====================================================================
%% Strictness: ids and batches
%%====================================================================

decode_id_null_is_invalid_test() ->
    ?assertEqual(
        {invalid, bad_id},
        barrel_mcp_protocol:decode_envelope(
            #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => null,
                <<"method">> => <<"ping">>
            }
        )
    ).

decode_id_object_is_invalid_test() ->
    ?assertEqual(
        {invalid, bad_id},
        barrel_mcp_protocol:decode_envelope(
            #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => #{<<"foo">> => 1},
                <<"method">> => <<"ping">>
            }
        )
    ).

decode_batch_is_invalid_test() ->
    ?assertEqual(
        {invalid, batch_unsupported},
        barrel_mcp_protocol:decode_envelope(
            [
                #{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"id">> => 1,
                    <<"method">> => <<"ping">>
                }
            ]
        )
    ).

handle_id_null_returns_invalid_request_test() ->
    Resp = barrel_mcp_protocol:handle(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => null,
            <<"method">> => <<"ping">>
        }
    ),
    ?assertMatch(#{<<"error">> := #{<<"code">> := -32600}}, Resp).

handle_id_object_returns_invalid_request_test() ->
    Resp = barrel_mcp_protocol:handle(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => #{<<"foo">> => 1},
            <<"method">> => <<"ping">>
        }
    ),
    ?assertMatch(#{<<"error">> := #{<<"code">> := -32600}}, Resp).

handle_id_integer_ok_test() ->
    Resp = barrel_mcp_protocol:handle(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 42,
            <<"method">> => <<"ping">>
        }
    ),
    ?assertMatch(#{<<"result">> := _, <<"id">> := 42}, Resp).

handle_id_binary_ok_test() ->
    Resp = barrel_mcp_protocol:handle(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => <<"abc">>,
            <<"method">> => <<"ping">>
        }
    ),
    ?assertMatch(#{<<"result">> := _, <<"id">> := <<"abc">>}, Resp).

handle_notification_returns_no_response_test() ->
    ?assertEqual(
        no_response,
        barrel_mcp_protocol:handle(
            #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"method">> => <<"notifications/initialized">>
            }
        )
    ).

%% Batches are revision gated, and `handle/1' names no revision, so
%% this is the unnegotiated case rather than a blanket refusal.
handle_batch_without_a_revision_is_refused_test() ->
    Resp = barrel_mcp_protocol:handle([
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 1,
            <<"method">> => <<"ping">>
        }
    ]),
    ?assertMatch(
        #{
            <<"error">> := #{
                <<"code">> := -32600,
                <<"message">> :=
                    <<"Batch requests are not supported">>
            }
        },
        Resp
    ).

%%====================================================================
%% drive_async_plan/2
%%====================================================================

drive_async_plan_result_test() ->
    %% Stand in for `barrel_mcp_registry:run_tool/3': spawn a worker
    %% that immediately reports a string result.
    Plan = #{
        request_id => 42,
        spawn => fun(Ctx) ->
            ReplyTo = maps:get(reply_to, Ctx),
            Id = maps:get(request_id, Ctx),
            spawn(fun() -> ReplyTo ! {tool_result, Id, <<"hello">>} end)
        end
    },
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, 1000),
    ?assertEqual(42, maps:get(<<"id">>, Resp)),
    Result = maps:get(<<"result">>, Resp),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"hello">>, maps:get(<<"text">>, Block)).

drive_async_plan_tool_error_test() ->
    Content = [#{<<"type">> => <<"text">>, <<"text">> => <<"boom">>}],
    Plan = #{
        request_id => 7,
        spawn => fun(Ctx) ->
            ReplyTo = maps:get(reply_to, Ctx),
            spawn(fun() -> ReplyTo ! {tool_error, 7, Content} end)
        end
    },
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, 1000),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(true, maps:get(<<"isError">>, Result)),
    ?assertEqual(Content, maps:get(<<"content">>, Result)).

drive_async_plan_tool_failed_test() ->
    Plan = #{
        request_id => 9,
        spawn => fun(Ctx) ->
            ReplyTo = maps:get(reply_to, Ctx),
            spawn(fun() -> ReplyTo ! {tool_failed, 9, {error, kaboom}} end)
        end
    },
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, 1000),
    %% An error result, not a protocol error, as the reference
    %% implementation does. The crash reason is never echoed.
    #{<<"result">> := Result} = Resp,
    ?assertEqual(true, maps:get(<<"isError">>, Result)),
    [#{<<"text">> := Text}] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"Internal tool error">>, Text),
    ?assertEqual(nomatch, binary:match(Text, <<"kaboom">>)).

%% An unknown tool is the one failure that carries a name, in the exact
%% text the reference implementation uses.
drive_async_plan_unknown_tool_test() ->
    Plan = #{
        request_id => 10,
        spawn => fun(Ctx) ->
            ReplyTo = maps:get(reply_to, Ctx),
            spawn(fun() ->
                ReplyTo ! {tool_failed, 10, {error, {not_found, tool, <<"nope">>}}}
            end)
        end
    },
    #{<<"result">> := Result} = barrel_mcp_protocol:drive_async_plan(Plan, 1000),
    ?assertEqual(true, maps:get(<<"isError">>, Result)),
    ?assertMatch([#{<<"text">> := <<"Unknown tool: nope">>}], maps:get(<<"content">>, Result)).

drive_async_plan_timeout_test() ->
    Plan = #{
        request_id => 13,
        spawn => fun(_Ctx) -> spawn(fun() -> timer:sleep(infinity) end) end
    },
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, 50),
    ?assertMatch(
        #{
            <<"error">> := #{
                <<"code">> := -32000,
                <<"message">> := <<"Tool timed out">>
            }
        },
        Resp
    ).

%%====================================================================
%% _meta propagation on JSON-RPC envelopes and tool outcomes
%%====================================================================

%% `_meta' is a field of the result object, not a sibling of it: the
%% MCP schema declares it on `Result', so an envelope-level `_meta'
%% never reaches a conforming client.
result_meta(Resp) ->
    maps:get(<<"_meta">>, maps:get(<<"result">>, Resp)).

success_response_without_meta_omits_field_test() ->
    Resp = barrel_mcp_protocol:success_response(1, #{<<"k">> => 1}),
    ?assertNot(maps:is_key(<<"_meta">>, Resp)),
    ?assertNot(maps:is_key(<<"_meta">>, maps:get(<<"result">>, Resp))).

success_response_with_meta_carries_field_test() ->
    Meta = #{<<"requestId">> => <<"abc">>},
    Resp = barrel_mcp_protocol:success_response(1, #{<<"k">> => 1}, Meta),
    ?assertEqual(Meta, result_meta(Resp)),
    ?assertNot(maps:is_key(<<"_meta">>, Resp)).

success_response_with_empty_meta_omits_field_test() ->
    Resp = barrel_mcp_protocol:success_response(1, #{<<"k">> => 1}, #{}),
    ?assertNot(maps:is_key(<<"_meta">>, maps:get(<<"result">>, Resp))).

error_response_with_meta_carries_field_test() ->
    Meta = #{<<"trace">> => <<"xyz">>},
    Resp = barrel_mcp_protocol:error_response(1, -32000, <<"boom">>, Meta),
    ?assertEqual(Meta, maps:get(<<"_meta">>, maps:get(<<"error">>, Resp))),
    ?assertNot(maps:is_key(<<"_meta">>, Resp)).

drive_async_plan_result_meta_test() ->
    Meta = #{<<"requestId">> => <<"abc">>},
    Plan = #{
        request_id => 21,
        spawn => fun(Ctx) ->
            ReplyTo = maps:get(reply_to, Ctx),
            spawn(fun() ->
                ReplyTo ! {tool_result_meta, 21, <<"ok">>, Meta}
            end)
        end
    },
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, 1000),
    ?assertEqual(Meta, result_meta(Resp)).

drive_async_plan_structured_meta_test() ->
    Meta = #{<<"version">> => 1},
    Data = #{<<"x">> => 1},
    Content = [#{<<"type">> => <<"text">>, <<"text">> => <<"x=1">>}],
    Plan = #{
        request_id => 22,
        spawn => fun(Ctx) ->
            ReplyTo = maps:get(reply_to, Ctx),
            spawn(fun() ->
                ReplyTo ! {tool_structured_meta, 22, Data, Content, Meta}
            end)
        end
    },
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, 1000),
    ?assertEqual(Meta, result_meta(Resp)),
    ?assertEqual(
        Data,
        maps:get(
            <<"structuredContent">>,
            maps:get(<<"result">>, Resp)
        )
    ).

drive_async_plan_tool_error_meta_test() ->
    Meta = #{<<"hint">> => <<"retryable">>},
    Content = [#{<<"type">> => <<"text">>, <<"text">> => <<"oops">>}],
    Plan = #{
        request_id => 23,
        spawn => fun(Ctx) ->
            ReplyTo = maps:get(reply_to, Ctx),
            spawn(fun() ->
                ReplyTo ! {tool_error_meta, 23, Content, Meta}
            end)
        end
    },
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, 1000),
    ?assertEqual(Meta, result_meta(Resp)),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(true, maps:get(<<"isError">>, Result)).

%%====================================================================
%% Peer-controlled envelope shapes
%%
%% The method is interpolated into binaries and the params are read
%% with maps:get/3 several frames deeper, so a wrong shape here used to
%% be a badarg rather than an error response. Over stdio that ended the
%% server, and reaching it needed no authentication.
%%====================================================================

handle_non_binary_method_test() ->
    lists:foreach(
        fun(Method) ->
            Resp = barrel_mcp_protocol:handle(#{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => 1,
                <<"method">> => Method
            }),
            ?assertMatch(#{<<"error">> := #{<<"code">> := -32600}}, Resp),
            %% And the envelope is something a transport can write.
            ?assert(is_binary(barrel_mcp_protocol:encode(Resp)))
        end,
        [42, null, #{<<"a">> => 1}, [<<"tools/list">>], true]
    ).

handle_non_map_params_test() ->
    lists:foreach(
        fun(Params) ->
            Resp = barrel_mcp_protocol:handle(#{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => 1,
                <<"method">> => <<"tools/call">>,
                <<"params">> => Params
            }),
            ?assertMatch(#{<<"error">> := #{<<"code">> := -32600}}, Resp),
            ?assert(is_binary(barrel_mcp_protocol:encode(Resp)))
        end,
        [42, null, <<"a string">>, [#{}], true]
    ).

%% A notification carries no id, so a malformed one cannot be answered.
%% It must still not crash the caller.
handle_malformed_notification_test() ->
    ?assertEqual(
        no_response,
        barrel_mcp_protocol:handle(#{
            <<"jsonrpc">> => <<"2.0">>,
            <<"method">> => <<"notifications/cancelled">>,
            <<"params">> => 42
        })
    ).

%% Absent params stays valid: the field is optional.
handle_absent_params_ok_test() ->
    Resp = barrel_mcp_protocol:handle(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>
    }),
    ?assertMatch(#{<<"result">> := _}, Resp).

%% A malformed id cannot be echoed, so the error carries null.
handle_bad_method_with_bad_id_test() ->
    Resp = barrel_mcp_protocol:handle(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => #{<<"not">> => <<"an id">>},
        <<"method">> => 42
    }),
    ?assertEqual(null, maps:get(<<"id">>, Resp)).

%%====================================================================
%% Decode limits
%%
%% The cap has to stop the document before the term exists. A check on
%% the finished term is too late: building it is the attack.
%%====================================================================

nested(0, Inner) -> Inner;
nested(N, Inner) -> nested(N - 1, <<"[", Inner/binary, "]">>).

decode_rejects_deep_nesting_test() ->
    ?assertEqual({error, too_deep}, barrel_mcp_protocol:decode(nested(500, <<"1">>))),
    %% And the process is still alive to say so.
    ?assertEqual({ok, [[1]]}, barrel_mcp_protocol:decode(nested(2, <<"1">>))).

decode_allows_realistic_nesting_test() ->
    %% Deeper than any MCP message, still accepted.
    ?assertMatch({ok, _}, barrel_mcp_protocol:decode(nested(32, <<"1">>))).

%% Replacing the default decoder must not change what a document means.
%% Duplicate keys are the case that differs if the accumulator is
%% reversed: the default keeps the first occurrence.
decode_matches_default_decoder_test() ->
    lists:foreach(
        fun(Bin) ->
            ?assertEqual({ok, json:decode(Bin)}, barrel_mcp_protocol:decode(Bin))
        end,
        [
            <<"{}">>,
            <<"[]">>,
            <<"{\"a\":1,\"a\":2}">>,
            <<"{\"a\":{\"b\":[1,{\"c\":null}]}}">>,
            <<"{\"n\":1.5,\"e\":1e3,\"neg\":-0.5}">>,
            <<"{\"s\":\"a\\\"b\",\"u\":\"\\u00e9\"}">>,
            <<"[true,false,null]">>,
            <<"{\"big\":123456789012345678901234567890}">>
        ]
    ).

decode_rejects_trailing_data_test() ->
    ?assertEqual({error, parse_error}, barrel_mcp_protocol:decode(<<"{} {}">>)).
