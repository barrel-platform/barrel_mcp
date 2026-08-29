%%%-------------------------------------------------------------------
%%% @doc Tests for the per-request context and era classification.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_ctx_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

%%====================================================================
%% Helpers
%%====================================================================

modern_meta() ->
    #{
        ?MCP_META_PROTOCOL_VERSION => <<"2026-07-28">>,
        ?MCP_META_CLIENT_CAPABILITIES => #{},
        ?MCP_META_CLIENT_INFO => #{
            <<"name">> => <<"ExampleClient">>,
            <<"version">> => <<"1.0.0">>
        }
    }.

request(Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => Method,
        <<"params">> => Params
    }.

modern_request(Method) ->
    modern_request(Method, #{}).

modern_request(Method, Params) ->
    request(Method, Params#{<<"_meta">> => modern_meta()}).

%%====================================================================
%% Era classification
%%====================================================================

era_modern_test() ->
    Ctx = barrel_mcp_ctx:from_request(modern_request(<<"tools/list">>)),
    ?assertEqual(modern, barrel_mcp_ctx:era(Ctx)),
    ?assert(barrel_mcp_ctx:is_modern(Ctx)),
    ?assertEqual(<<"2026-07-28">>, barrel_mcp_ctx:protocol_version(Ctx)).

era_legacy_without_meta_test() ->
    Ctx = barrel_mcp_ctx:from_request(request(<<"tools/list">>, #{})),
    ?assertEqual(legacy, barrel_mcp_ctx:era(Ctx)),
    ?assertNot(barrel_mcp_ctx:is_modern(Ctx)).

%% `_meta' exists but carries no protocol version: still legacy. A
%% progress token alone must not promote a request to the modern era.
era_legacy_with_unrelated_meta_test() ->
    Req = request(<<"tools/call">>, #{
        <<"_meta">> => #{<<"progressToken">> => <<"tok">>}
    }),
    ?assertEqual(legacy, barrel_mcp_ctx:era(barrel_mcp_ctx:from_request(Req))).

%% `initialize' is a legacy handshake by definition, even if some
%% confused client attaches modern metadata to it.
era_initialize_is_always_legacy_test() ->
    Ctx = barrel_mcp_ctx:from_request(modern_request(<<"initialize">>)),
    ?assertEqual(legacy, barrel_mcp_ctx:era(Ctx)).

era_notification_test() ->
    Notification = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/cancelled">>,
        <<"params">> => #{<<"_meta">> => modern_meta()}
    },
    ?assertEqual(modern, barrel_mcp_ctx:era(barrel_mcp_ctx:from_request(Notification))).

%%====================================================================
%% Malformed input is coerced, never crashes
%%====================================================================

malformed_params_test() ->
    Ctx = barrel_mcp_ctx:from_request(request(<<"tools/list">>, <<"not a map">>)),
    ?assertEqual(legacy, barrel_mcp_ctx:era(Ctx)),
    ?assertEqual(#{}, barrel_mcp_ctx:client_capabilities(Ctx)).

malformed_meta_test() ->
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/list">>, #{<<"_meta">> => [1, 2, 3]})
    ),
    ?assertEqual(legacy, barrel_mcp_ctx:era(Ctx)),
    ?assertEqual(#{}, barrel_mcp_ctx:meta(Ctx)).

malformed_capabilities_test() ->
    Meta = (modern_meta())#{?MCP_META_CLIENT_CAPABILITIES => <<"nope">>},
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/list">>, #{<<"_meta">> => Meta})
    ),
    ?assertEqual(modern, barrel_mcp_ctx:era(Ctx)),
    ?assertEqual(#{}, barrel_mcp_ctx:client_capabilities(Ctx)).

malformed_client_info_test() ->
    Meta = (modern_meta())#{?MCP_META_CLIENT_INFO => <<"nope">>},
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/list">>, #{<<"_meta">> => Meta})
    ),
    ?assertEqual(undefined, barrel_mcp_ctx:client_info(Ctx)).

missing_params_test() ->
    Req = #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1, <<"method">> => <<"ping">>},
    ?assertEqual(legacy, barrel_mcp_ctx:era(barrel_mcp_ctx:from_request(Req))).

%%====================================================================
%% Validation
%%====================================================================

validate_modern_ok_test() ->
    Ctx = barrel_mcp_ctx:from_request(modern_request(<<"tools/list">>)),
    ?assertEqual(ok, barrel_mcp_ctx:validate(Ctx)).

validate_modern_missing_capabilities_test() ->
    Meta = maps:remove(?MCP_META_CLIENT_CAPABILITIES, modern_meta()),
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/list">>, #{<<"_meta">> => Meta})
    ),
    ?assertEqual(
        {error, {missing_meta, ?MCP_META_CLIENT_CAPABILITIES}},
        barrel_mcp_ctx:validate(Ctx)
    ).

%% `clientInfo' is only SHOULD, so its absence must not fail validation.
validate_modern_without_client_info_test() ->
    Meta = maps:remove(?MCP_META_CLIENT_INFO, modern_meta()),
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/list">>, #{<<"_meta">> => Meta})
    ),
    ?assertEqual(ok, barrel_mcp_ctx:validate(Ctx)),
    ?assertEqual(undefined, barrel_mcp_ctx:client_info(Ctx)).

validate_legacy_always_ok_test() ->
    Ctx = barrel_mcp_ctx:from_request(request(<<"tools/list">>, #{})),
    ?assertEqual(ok, barrel_mcp_ctx:validate(Ctx)).

%%====================================================================
%% Capabilities
%%====================================================================

supports_test() ->
    Meta = (modern_meta())#{
        ?MCP_META_CLIENT_CAPABILITIES => #{
            <<"elicitation">> => #{},
            <<"roots">> => #{<<"listChanged">> => true}
        }
    },
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/call">>, #{<<"_meta">> => Meta})
    ),
    ?assert(barrel_mcp_ctx:supports(Ctx, elicitation)),
    ?assert(barrel_mcp_ctx:supports(Ctx, <<"roots">>)),
    ?assertNot(barrel_mcp_ctx:supports(Ctx, sampling)).

supports_extension_test() ->
    Meta = (modern_meta())#{
        ?MCP_META_CLIENT_CAPABILITIES => #{
            <<"extensions">> => #{?MCP_EXT_TASKS => #{}}
        }
    },
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/call">>, #{<<"_meta">> => Meta})
    ),
    ?assert(barrel_mcp_ctx:supports_extension(Ctx, ?MCP_EXT_TASKS)),
    ?assertNot(barrel_mcp_ctx:supports_extension(Ctx, <<"com.example/other">>)).

supports_extension_absent_test() ->
    Ctx = barrel_mcp_ctx:from_request(modern_request(<<"tools/call">>)),
    ?assertNot(barrel_mcp_ctx:supports_extension(Ctx, ?MCP_EXT_TASKS)).

%% Legacy capabilities come from the session, not from `_meta'.
legacy_capabilities_from_extra_test() ->
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/call">>, #{}),
        #{
            client_capabilities => #{<<"sampling">> => #{}},
            protocol_version => <<"2025-11-25">>,
            session_id => <<"sess-1">>
        }
    ),
    ?assertEqual(legacy, barrel_mcp_ctx:era(Ctx)),
    ?assert(barrel_mcp_ctx:supports(Ctx, sampling)),
    ?assertEqual(<<"2025-11-25">>, barrel_mcp_ctx:protocol_version(Ctx)),
    ?assertEqual(<<"sess-1">>, barrel_mcp_ctx:session_id(Ctx)).

%% A modern request never inherits session state, even if the transport
%% mistakenly passes some.
modern_ignores_session_capabilities_test() ->
    Ctx = barrel_mcp_ctx:from_request(
        modern_request(<<"tools/call">>),
        #{client_capabilities => #{<<"sampling">> => #{}}}
    ),
    ?assertNot(barrel_mcp_ctx:supports(Ctx, sampling)).

%%====================================================================
%% MRTR fields
%%====================================================================

input_responses_test() ->
    Params = #{
        <<"inputResponses">> => #{
            <<"confirm">> => #{
                <<"action">> => <<"accept">>,
                <<"content">> => #{<<"approved">> => true}
            }
        },
        <<"requestState">> => <<"opaque-blob">>
    },
    Ctx = barrel_mcp_ctx:from_request(modern_request(<<"tools/call">>, Params)),
    ?assertMatch(
        {ok, #{<<"action">> := <<"accept">>}},
        barrel_mcp_ctx:input_response(Ctx, <<"confirm">>)
    ),
    ?assertEqual(none, barrel_mcp_ctx:input_response(Ctx, <<"missing">>)),
    ?assertEqual(<<"opaque-blob">>, barrel_mcp_ctx:request_state(Ctx)).

no_input_responses_test() ->
    Ctx = barrel_mcp_ctx:from_request(modern_request(<<"tools/call">>)),
    ?assertEqual(#{}, barrel_mcp_ctx:input_responses(Ctx)),
    ?assertEqual(none, barrel_mcp_ctx:input_response(Ctx, <<"confirm">>)),
    ?assertEqual(undefined, barrel_mcp_ctx:request_state(Ctx)).

%% A non-binary `requestState' is a malformed client, not a crash.
malformed_request_state_test() ->
    Params = #{<<"requestState">> => #{<<"not">> => <<"a binary">>}},
    Ctx = barrel_mcp_ctx:from_request(modern_request(<<"tools/call">>, Params)),
    ?assertEqual(undefined, barrel_mcp_ctx:request_state(Ctx)).

%%====================================================================
%% Log level and auth
%%====================================================================

log_level_test() ->
    Meta = (modern_meta())#{?MCP_META_LOG_LEVEL => <<"debug">>},
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/call">>, #{<<"_meta">> => Meta})
    ),
    ?assertEqual(<<"debug">>, barrel_mcp_ctx:log_level(Ctx)).

log_level_absent_test() ->
    Ctx = barrel_mcp_ctx:from_request(modern_request(<<"tools/call">>)),
    ?assertEqual(undefined, barrel_mcp_ctx:log_level(Ctx)).

auth_info_test() ->
    Auth = #{<<"sub">> => <<"user-1">>},
    Ctx = barrel_mcp_ctx:from_request(
        modern_request(<<"tools/call">>),
        #{auth_info => Auth}
    ),
    ?assertEqual(Auth, barrel_mcp_ctx:auth_info(Ctx)).

meta_passthrough_test() ->
    Meta = (modern_meta())#{<<"progressToken">> => <<"tok-1">>},
    Ctx = barrel_mcp_ctx:from_request(
        request(<<"tools/call">>, #{<<"_meta">> => Meta})
    ),
    ?assertEqual(<<"tok-1">>, maps:get(<<"progressToken">>, barrel_mcp_ctx:meta(Ctx))).
