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
    M = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
          <<"method">> => <<"ping">>, <<"params">> => #{}},
    ?assertEqual({request, 1, <<"ping">>, #{}},
                 barrel_mcp_protocol:decode_envelope(M)).

decode_notification_test() ->
    M = #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => <<"x">>},
    ?assertEqual({notification, <<"x">>, #{}},
                 barrel_mcp_protocol:decode_envelope(M)).

decode_response_test() ->
    M = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 9,
          <<"result">> => #{<<"ok">> => true}},
    ?assertEqual({response, 9, #{<<"ok">> => true}},
                 barrel_mcp_protocol:decode_envelope(M)).

decode_error_test() ->
    M = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 9,
          <<"error">> => #{<<"code">> => -32601, <<"message">> => <<"nope">>}},
    ?assertMatch({error, 9, -32601, <<"nope">>, undefined},
                 barrel_mcp_protocol:decode_envelope(M)).

decode_invalid_test() ->
    ?assertMatch({invalid, _},
                 barrel_mcp_protocol:decode_envelope(#{})).

%%====================================================================
%% Strictness: ids and batches
%%====================================================================

decode_id_null_is_invalid_test() ->
    ?assertEqual({invalid, bad_id},
                 barrel_mcp_protocol:decode_envelope(
                   #{<<"jsonrpc">> => <<"2.0">>,
                     <<"id">> => null,
                     <<"method">> => <<"ping">>})).

decode_id_object_is_invalid_test() ->
    ?assertEqual({invalid, bad_id},
                 barrel_mcp_protocol:decode_envelope(
                   #{<<"jsonrpc">> => <<"2.0">>,
                     <<"id">> => #{<<"foo">> => 1},
                     <<"method">> => <<"ping">>})).

decode_batch_is_invalid_test() ->
    ?assertEqual({invalid, batch_unsupported},
                 barrel_mcp_protocol:decode_envelope(
                   [#{<<"jsonrpc">> => <<"2.0">>,
                      <<"id">> => 1,
                      <<"method">> => <<"ping">>}])).

handle_id_null_returns_invalid_request_test() ->
    Resp = barrel_mcp_protocol:handle(
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"id">> => null,
               <<"method">> => <<"ping">>}),
    ?assertMatch(#{<<"error">> := #{<<"code">> := -32600}}, Resp).

handle_id_object_returns_invalid_request_test() ->
    Resp = barrel_mcp_protocol:handle(
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"id">> => #{<<"foo">> => 1},
               <<"method">> => <<"ping">>}),
    ?assertMatch(#{<<"error">> := #{<<"code">> := -32600}}, Resp).

handle_id_integer_ok_test() ->
    Resp = barrel_mcp_protocol:handle(
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"id">> => 42,
               <<"method">> => <<"ping">>}),
    ?assertMatch(#{<<"result">> := _, <<"id">> := 42}, Resp).

handle_id_binary_ok_test() ->
    Resp = barrel_mcp_protocol:handle(
             #{<<"jsonrpc">> => <<"2.0">>,
               <<"id">> => <<"abc">>,
               <<"method">> => <<"ping">>}),
    ?assertMatch(#{<<"result">> := _, <<"id">> := <<"abc">>}, Resp).

handle_notification_returns_no_response_test() ->
    ?assertEqual(no_response,
                 barrel_mcp_protocol:handle(
                   #{<<"jsonrpc">> => <<"2.0">>,
                     <<"method">> => <<"notifications/initialized">>})).

handle_batch_returns_invalid_request_test() ->
    Resp = barrel_mcp_protocol:handle([
        #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1,
          <<"method">> => <<"ping">>}
    ]),
    ?assertMatch(#{<<"error">> := #{<<"code">> := -32600,
                                    <<"message">> :=
                                        <<"Batch requests are not supported">>}},
                 Resp).
