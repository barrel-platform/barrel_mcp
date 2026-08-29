%%%-------------------------------------------------------------------
%%% @doc JSON-RPC batches, which exist in some revisions and not others.
%%%
%%% 2025-03-26 requires receiving them, 2024-11-05 says nothing so we
%%% accept them there by choice, and 2025-06-18 removed them. The rule
%%% is not a threshold, which is why it lives in a table.
%%%
%%% The two array kinds are answered differently: a malformed request
%%% can be told so, a malformed response cannot, because a response is
%%% not something one replies to.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_batch_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

at(Revision) -> #{protocol_version => Revision}.

req(Id, Method) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"method">> => Method}.

notif(Method) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"method">> => Method}.

resp(Id) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => #{}}.

code_of(#{<<"error">> := #{<<"code">> := C}}) -> C.

%%====================================================================
%% Revision gating
%%====================================================================

accepted_where_required_test() ->
    ?assertEqual(enabled, barrel_mcp_version:feature(batch_receive, <<"2025-03-26">>)),
    Resp = barrel_mcp_protocol:handle([req(1, <<"ping">>)], at(<<"2025-03-26">>)),
    ?assertMatch([#{<<"id">> := 1, <<"result">> := _}], Resp).

accepted_by_compatibility_at_2024_test() ->
    ?assertEqual(compatibility, barrel_mcp_version:feature(batch_receive, <<"2024-11-05">>)),
    ?assertMatch([_], barrel_mcp_protocol:handle([req(1, <<"ping">>)], at(<<"2024-11-05">>))).

rejected_once_removed_test() ->
    lists:foreach(
        fun(Revision) ->
            Resp = barrel_mcp_protocol:handle([req(1, <<"ping">>)], at(Revision)),
            ?assertEqual(?JSONRPC_INVALID_REQUEST, code_of(Resp))
        end,
        [<<"2025-06-18">>, <<"2025-11-25">>, <<"2026-07-28">>]
    ).

%% Before a revision is negotiated we cannot know what the peer speaks,
%% and guessing permissively is what a limit exists to prevent.
rejected_when_unnegotiated_test() ->
    Resp = barrel_mcp_protocol:handle([req(1, <<"ping">>)], #{}),
    ?assertEqual(?JSONRPC_INVALID_REQUEST, code_of(Resp)).

%%====================================================================
%% Envelope categories
%%====================================================================

empty_batch_test() ->
    ?assertEqual(
        ?JSONRPC_INVALID_REQUEST,
        code_of(barrel_mcp_protocol:handle([], at(<<"2025-03-26">>)))
    ).

%% One response per request, notifications omitted.
requests_and_notifications_test() ->
    Batch = [req(1, <<"ping">>), notif(<<"notifications/initialized">>), req(2, <<"ping">>)],
    Resp = barrel_mcp_protocol:handle(Batch, at(<<"2025-03-26">>)),
    ?assertEqual(2, length(Resp)),
    ?assertEqual([1, 2], [maps:get(<<"id">>, R) || R <- Resp]).

notifications_only_produce_nothing_test() ->
    Batch = [notif(<<"notifications/initialized">>), notif(<<"notifications/initialized">>)],
    ?assertEqual(no_response, barrel_mcp_protocol:handle(Batch, at(<<"2025-03-26">>))).

%% A response cannot be answered, so an array of them is accepted in
%% silence and reported by transport status alone.
responses_only_produce_nothing_test() ->
    ?assertEqual(
        no_response,
        barrel_mcp_protocol:handle([resp(1), resp(2)], at(<<"2025-03-26">>))
    ).

%% JSON-RPC allows requests and/or notifications, or responses. Never
%% both in one array.
mixed_batch_is_refused_test() ->
    Resp = barrel_mcp_protocol:handle([req(1, <<"ping">>), resp(2)], at(<<"2025-03-26">>)),
    ?assertEqual(?JSONRPC_INVALID_REQUEST, code_of(Resp)).

%% One bad element earns its own error and never fails the rest.
invalid_element_is_answered_individually_test() ->
    Batch = [req(1, <<"ping">>), #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2, <<"method">> => 42}],
    Resp = barrel_mcp_protocol:handle(Batch, at(<<"2025-03-26">>)),
    ?assertEqual(2, length(Resp)),
    [First, Second] = Resp,
    ?assertMatch(#{<<"result">> := _}, First),
    ?assertEqual(?JSONRPC_INVALID_REQUEST, code_of(Second)).

non_map_element_is_answered_test() ->
    Resp = barrel_mcp_protocol:handle([req(1, <<"ping">>), 42], at(<<"2025-03-26">>)),
    ?assertEqual(2, length(Resp)),
    ?assertEqual(?JSONRPC_INVALID_REQUEST, code_of(lists:last(Resp))).

%% The whole array has to be encodable, which is what a transport does
%% with it.
batch_response_encodes_test() ->
    Resp = barrel_mcp_protocol:handle(
        [req(1, <<"ping">>), req(2, <<"ping">>)], at(<<"2025-03-26">>)
    ),
    ?assert(is_binary(barrel_mcp_protocol:encode(Resp))).
