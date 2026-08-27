%%%-------------------------------------------------------------------
%%% @doc Era dispatch in the protocol core: what a modern request gets
%%% back versus a legacy one, driven through
%%% `barrel_mcp_protocol:handle/2' with no transport involved.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_era_dispatch_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([echo_tool/1, a_resource/1]).

%%====================================================================
%% Fixture
%%====================================================================

era_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"Modern result carries resultType complete", fun modern_result_type/0},
        {"Modern result carries serverInfo in _meta", fun modern_server_info/0},
        {"Legacy result carries neither", fun legacy_undecorated/0},
        {"serverInfo can be switched off", fun server_info_disabled/0},
        {"Existing result _meta survives decoration", fun modern_preserves_meta/0},
        {"Modern tool call is decorated", fun modern_tool_call/0},
        {"Legacy-only methods are unknown to modern", fun legacy_only_methods/0},
        {"Legacy-only methods still work for legacy", fun legacy_only_still_served/0},
        {"initialize is legacy even with modern _meta", fun initialize_stays_legacy/0},
        {"Modern request without clientCapabilities is invalid", fun modern_missing_caps/0},
        {"Resource not found is era dependent", fun resource_not_found_code/0},
        {"Errors are never decorated", fun errors_undecorated/0},
        {"Unknown method is method-not-found in both eras", fun unknown_method/0},
        {"subscriptions/listen needs a streaming transport", fun listen_needs_streaming/0},
        {"subscriptions/listen yields a stream when it can", fun listen_when_streaming/0},
        {"Unknown modern version is rejected", fun unsupported_version/0},
        {"advertise_versions=all lists both eras", fun advertise_all_versions/0},
        {"Version is checked before _meta validation", fun version_checked_first/0},
        {"Legacy requests skip the version check", fun legacy_skips_version_check/0},
        {"server/discover describes the modern surface", fun discover_shape/0},
        {"server/discover answers a legacy probe", fun discover_legacy_probe/0},
        {"server/discover omits absent instructions", fun discover_no_instructions/0},
        {"server/discover carries instructions when set", fun discover_instructions/0},
        {"Cacheable results carry freshness hints", fun cache_hints/0},
        {"A multi round-trip retry carries none", fun cache_hints_not_on_retries/0},
        {"Legacy results carry none", fun cache_hints_legacy/0},
        {"Freshness hints are configurable", fun cache_hints_configurable/0},
        {"Non-cacheable methods carry none", fun cache_hints_only_where_defined/0},
        {"A resource may set its own ttl", fun cache_hints_resource_override/0}
    ]}.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{}),
    ok = barrel_mcp_registry:reg(resource, <<"res">>, ?MODULE, a_resource, #{
        uri => <<"file:///present">>
    }),
    ok.

cleanup(_) ->
    application:unset_env(barrel_mcp, instructions),
    application:unset_env(barrel_mcp, cache_ttl_ms),
    application:unset_env(barrel_mcp, cache_scope),
    barrel_mcp_registry:unreg(resource, <<"volatile">>),
    barrel_mcp_registry:unreg(tool, <<"echo">>),
    barrel_mcp_registry:unreg(resource, <<"res">>),
    application:unset_env(barrel_mcp, send_server_info),
    application:unset_env(barrel_mcp, advertise_versions),
    ok.

echo_tool(_Args) -> <<"pong">>.

a_resource(_Args) -> <<"body">>.

%%====================================================================
%% Helpers
%%====================================================================

modern_meta() ->
    #{
        ?MCP_META_PROTOCOL_VERSION => <<"2026-07-28">>,
        ?MCP_META_CLIENT_CAPABILITIES => #{}
    }.

modern(Method) -> modern(Method, #{}).

modern(Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => modern_meta()}
    }.

legacy(Method) -> legacy(Method, #{}).

legacy(Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => Method,
        <<"params">> => Params
    }.

result_of(Request) ->
    maps:get(<<"result">>, barrel_mcp_protocol:handle(Request)).

error_code_of(Request) ->
    Resp = barrel_mcp_protocol:handle(Request),
    maps:get(<<"code">>, maps:get(<<"error">>, Resp)).

%%====================================================================
%% Result decoration
%%====================================================================

modern_result_type() ->
    Result = result_of(modern(<<"tools/list">>)),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)).

modern_server_info() ->
    Result = result_of(modern(<<"tools/list">>)),
    Info = maps:get(?MCP_META_SERVER_INFO, maps:get(<<"_meta">>, Result)),
    ?assert(maps:is_key(<<"name">>, Info)),
    ?assert(maps:is_key(<<"version">>, Info)).

legacy_undecorated() ->
    Result = result_of(legacy(<<"tools/list">>)),
    ?assertNot(maps:is_key(<<"resultType">>, Result)),
    ?assertNot(maps:is_key(<<"_meta">>, Result)).

server_info_disabled() ->
    application:set_env(barrel_mcp, send_server_info, false),
    try
        Result = result_of(modern(<<"tools/list">>)),
        %% resultType is required and stays; only the identity goes.
        ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
        ?assertNot(maps:is_key(<<"_meta">>, Result))
    after
        application:unset_env(barrel_mcp, send_server_info)
    end.

%% Decoration must merge into any `_meta' the handler already produced,
%% not replace it.
modern_preserves_meta() ->
    Base = barrel_mcp_protocol:success_response(
        1,
        #{<<"k">> => 1},
        #{<<"handlerKey">> => <<"kept">>}
    ),
    Ctx = barrel_mcp_ctx:from_request(modern(<<"tools/list">>)),
    Result = maps:get(<<"result">>, barrel_mcp_protocol:finalize(Base, Ctx)),
    Meta = maps:get(<<"_meta">>, Result),
    ?assertEqual(<<"kept">>, maps:get(<<"handlerKey">>, Meta)),
    ?assert(maps:is_key(?MCP_META_SERVER_INFO, Meta)).

%% tools/call goes through the async plan, so the context has to reach
%% the transport that finishes it.
modern_tool_call() ->
    Request = modern(<<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{}
    }),
    {async, Plan} = barrel_mcp_protocol:handle(Request),
    ?assert(maps:is_key(ctx, Plan)),
    ?assert(barrel_mcp_ctx:is_modern(maps:get(ctx, Plan))),
    Resp = barrel_mcp_protocol:drive_async_plan(Plan, 2000),
    Result = maps:get(<<"result">>, Resp),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assert(maps:is_key(<<"content">>, Result)).

%%====================================================================
%% Era gating
%%====================================================================

legacy_only_methods() ->
    Removed = [
        <<"ping">>,
        <<"logging/setLevel">>,
        <<"resources/subscribe">>,
        <<"resources/unsubscribe">>,
        <<"tasks/list">>,
        <<"tasks/result">>
    ],
    lists:foreach(
        fun(Method) ->
            ?assertEqual(
                ?JSONRPC_METHOD_NOT_FOUND,
                error_code_of(modern(Method))
            )
        end,
        Removed
    ).

legacy_only_still_served() ->
    Resp = barrel_mcp_protocol:handle(legacy(<<"ping">>)),
    ?assertEqual(#{}, maps:get(<<"result">>, Resp)).

initialize_stays_legacy() ->
    %% A confused client attaching modern metadata to `initialize' must
    %% not get a half-modern handshake.
    Result = result_of(modern(<<"initialize">>)),
    ?assertNot(maps:is_key(<<"resultType">>, Result)),
    ?assert(maps:is_key(<<"protocolVersion">>, Result)),
    %% And the negotiated version stays legacy.
    ?assertEqual(?MCP_LATEST_LEGACY_VERSION, maps:get(<<"protocolVersion">>, Result)).

modern_missing_caps() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>,
        <<"params">> => #{
            <<"_meta">> => #{?MCP_META_PROTOCOL_VERSION => <<"2026-07-28">>}
        }
    },
    ?assertEqual(?JSONRPC_INVALID_PARAMS, error_code_of(Request)).

%%====================================================================
%% Era-dependent error codes
%%====================================================================

resource_not_found_code() ->
    Params = #{<<"uri">> => <<"file:///absent">>},
    ?assertEqual(
        ?MCP_RESOURCE_NOT_FOUND,
        error_code_of(legacy(<<"resources/read">>, Params))
    ),
    ?assertEqual(
        ?JSONRPC_INVALID_PARAMS,
        error_code_of(modern(<<"resources/read">>, Params))
    ).

%% A present resource still reads fine in both eras, and only the
%% modern one is decorated.
errors_undecorated() ->
    Resp = barrel_mcp_protocol:handle(
        modern(<<"resources/read">>, #{<<"uri">> => <<"file:///absent">>})
    ),
    ?assertNot(maps:is_key(<<"result">>, Resp)),
    ?assertNot(maps:is_key(<<"_meta">>, maps:get(<<"error">>, Resp))).

unknown_method() ->
    ?assertEqual(
        ?JSONRPC_METHOD_NOT_FOUND,
        error_code_of(modern(<<"no/such/method">>))
    ),
    ?assertEqual(
        ?JSONRPC_METHOD_NOT_FOUND,
        error_code_of(legacy(<<"no/such/method">>))
    ).

%% stdio has one output channel and the plain HTTP transport answers
%% once, so neither can hold a subscription open. Handing either a
%% `{subscribe, _}' it cannot serve crashes it on the way out, so the
%% method simply does not exist without a transport that says it can.
listen_needs_streaming() ->
    Resp = barrel_mcp_protocol:handle(modern(<<"subscriptions/listen">>)),
    ?assertEqual(
        ?JSONRPC_METHOD_NOT_FOUND,
        maps:get(<<"code">>, maps:get(<<"error">>, Resp))
    ),
    %% And it is an envelope the transport can actually write.
    ?assert(is_binary(barrel_mcp_protocol:encode(Resp))).

listen_when_streaming() ->
    ?assertMatch(
        {subscribe, #{id := 1}},
        barrel_mcp_protocol:handle(
            modern(<<"subscriptions/listen">>), #{streaming => true}
        )
    ).

%%====================================================================
%% Version negotiation
%%====================================================================

at_version(Version) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>,
        <<"params">> => #{
            <<"_meta">> => #{
                ?MCP_META_PROTOCOL_VERSION => Version,
                ?MCP_META_CLIENT_CAPABILITIES => #{}
            }
        }
    }.

version_error_data(Version) ->
    Resp = barrel_mcp_protocol:handle(at_version(Version)),
    Error = maps:get(<<"error">>, Resp),
    ?assertEqual(?MCP_UNSUPPORTED_PROTOCOL_VERSION, maps:get(<<"code">>, Error)),
    maps:get(<<"data">>, Error).

unsupported_version() ->
    Data = version_error_data(<<"1900-01-01">>),
    ?assertEqual(<<"1900-01-01">>, maps:get(<<"requested">>, Data)),
    %% The default advertises only the revisions a client can retry
    %% with. Listing a legacy one here would invite a retry that is
    %% rejected identically.
    ?assertEqual(?MCP_MODERN_VERSIONS, maps:get(<<"supported">>, Data)),
    ?assertNot(lists:member(<<"2025-11-25">>, maps:get(<<"supported">>, Data))).

advertise_all_versions() ->
    application:set_env(barrel_mcp, advertise_versions, all),
    try
        Supported = maps:get(<<"supported">>, version_error_data(<<"1900-01-01">>)),
        ?assertEqual(?MCP_ALL_VERSIONS, Supported),
        ?assert(lists:member(<<"2026-07-28">>, Supported)),
        ?assert(lists:member(<<"2025-11-25">>, Supported))
    after
        application:unset_env(barrel_mcp, advertise_versions)
    end.

%% A legacy revision named in modern per-request metadata is still
%% unsupported: those revisions require the handshake.
version_checked_first() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>,
        <<"params">> => #{
            <<"_meta">> => #{?MCP_META_PROTOCOL_VERSION => <<"2025-11-25">>}
        }
    },
    %% clientCapabilities is missing too, but the version error wins.
    ?assertEqual(?MCP_UNSUPPORTED_PROTOCOL_VERSION, error_code_of(Request)).

legacy_skips_version_check() ->
    Result = result_of(legacy(<<"tools/list">>)),
    ?assert(maps:is_key(<<"tools">>, Result)).

%%====================================================================
%% server/discover
%%====================================================================

discover_shape() ->
    Result = result_of(modern(<<"server/discover">>)),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual(?MCP_MODERN_VERSIONS, maps:get(<<"supportedVersions">>, Result)),
    ?assert(is_integer(maps:get(<<"ttlMs">>, Result))),
    ?assertEqual(<<"public">>, maps:get(<<"cacheScope">>, Result)),
    ?assert(maps:is_key(?MCP_META_SERVER_INFO, maps:get(<<"_meta">>, Result))),
    Caps = maps:get(<<"capabilities">>, Result),
    ?assert(maps:is_key(<<"tools">>, Caps)),
    ?assert(maps:is_key(<<"prompts">>, Caps)),
    %% The tasks extension is the one we serve; advertising anything
    %% else would be a claim a client acts on.
    ?assertEqual(#{?MCP_EXT_TASKS => #{}}, maps:get(<<"extensions">>, Caps)),
    %% Discovery describes the modern surface only: these three are
    %% gone from 2026-07-28 and advertising them would be a lie.
    ?assertNot(maps:is_key(<<"logging">>, Caps)),
    ?assertNot(maps:is_key(<<"tasks">>, Caps)),
    ?assertNot(maps:is_key(<<"subscribe">>, maps:get(<<"resources">>, Caps))).

%% The stdio backward-compatibility probe arrives with no `_meta' at
%% all. It must still be answered, or a dual-era client cannot tell a
%% modern server from a legacy one.
discover_legacy_probe() ->
    Result = result_of(legacy(<<"server/discover">>)),
    ?assertEqual(?MCP_MODERN_VERSIONS, maps:get(<<"supportedVersions">>, Result)),
    %% Legacy results are not decorated, so no resultType here, but
    %% serverInfo is attached explicitly so the probe can identify us.
    ?assertNot(maps:is_key(<<"resultType">>, Result)),
    ?assert(maps:is_key(?MCP_META_SERVER_INFO, maps:get(<<"_meta">>, Result))).

discover_no_instructions() ->
    application:unset_env(barrel_mcp, instructions),
    ?assertNot(maps:is_key(<<"instructions">>, result_of(modern(<<"server/discover">>)))).

discover_instructions() ->
    application:set_env(barrel_mcp, instructions, <<"Use the echo tool.">>),
    try
        ?assertEqual(
            <<"Use the echo tool.">>,
            maps:get(<<"instructions">>, result_of(modern(<<"server/discover">>)))
        )
    after
        application:unset_env(barrel_mcp, instructions)
    end.

%% initialize keeps advertising the handshake-era capabilities the
%% legacy methods depend on.
legacy_capabilities_intact_test() ->
    Result = maps:get(
        <<"result">>,
        barrel_mcp_protocol:handle(legacy(<<"initialize">>))
    ),
    Caps = maps:get(<<"capabilities">>, Result),
    ?assert(maps:is_key(<<"logging">>, Caps)),
    ?assert(maps:is_key(<<"tasks">>, Caps)),
    ?assertEqual(true, maps:get(<<"subscribe">>, maps:get(<<"resources">>, Caps))).

%% Tasks arrived at 2025-11-25, so what `initialize' advertises depends
%% on the revision it just settled on. Telling an older client the
%% server has them would have it call methods that do not exist there.
capabilities_follow_the_negotiated_revision_test() ->
    Advertises = fun(Requested) ->
        Result = maps:get(
            <<"result">>,
            barrel_mcp_protocol:handle(
                legacy(<<"initialize">>, #{<<"protocolVersion">> => Requested})
            )
        ),
        Caps = maps:get(<<"capabilities">>, Result),
        {maps:get(<<"protocolVersion">>, Result), maps:is_key(<<"tasks">>, Caps)}
    end,
    ?assertEqual({<<"2024-11-05">>, false}, Advertises(<<"2024-11-05">>)),
    ?assertEqual({<<"2025-03-26">>, false}, Advertises(<<"2025-03-26">>)),
    ?assertEqual({<<"2025-06-18">>, false}, Advertises(<<"2025-06-18">>)),
    ?assertEqual({<<"2025-11-25">>, true}, Advertises(<<"2025-11-25">>)).

%% And a method that did not exist yet is not served either, however the
%% client asks for it.
task_methods_are_absent_before_2025_11_25_test() ->
    Refused = fun(Revision) ->
        Resp = barrel_mcp_protocol:handle(
            legacy(<<"tasks/get">>, #{<<"taskId">> => <<"x">>}),
            #{protocol_version => Revision}
        ),
        maps:get(<<"code">>, maps:get(<<"error">>, Resp))
    end,
    ?assertEqual(-32601, Refused(<<"2024-11-05">>)),
    ?assertEqual(-32601, Refused(<<"2025-06-18">>)),
    %% Present from here on: not found, rather than not a method.
    ?assertEqual(-32602, Refused(<<"2025-11-25">>)).

%%====================================================================
%% Caching hints
%%====================================================================

cacheable_methods() ->
    [
        {<<"tools/list">>, #{}},
        {<<"prompts/list">>, #{}},
        {<<"resources/list">>, #{}},
        {<<"resources/templates/list">>, #{}},
        {<<"resources/read">>, #{<<"uri">> => <<"file:///present">>}}
    ].

%% "Results produced by retrying a request through the multi round-trip
%% requests mechanism, that is, requests carrying inputResponses or
%% requestState, MUST NOT be cached, as they depend on inputs that are
%% not part of the cache key" (2026-07-28/.../caching.mdx:34).
cache_hints_not_on_retries() ->
    Uri = <<"file:///present">>,
    Retry = fun(Params) ->
        result_of(modern(<<"resources/read">>, Params#{<<"uri">> => Uri}))
    end,
    %% The same request without either field is cacheable, so what
    %% follows is the retry and not the method.
    ?assert(maps:is_key(<<"ttlMs">>, Retry(#{}))),

    WithResponses = Retry(#{
        <<"inputResponses">> => #{<<"k">> => #{<<"action">> => <<"accept">>}}
    }),
    ?assertNot(maps:is_key(<<"ttlMs">>, WithResponses)),
    ?assertNot(maps:is_key(<<"cacheScope">>, WithResponses)),

    %% A real sealed state, since a forged one is refused before there
    %% is a result to decorate.
    Sealed = barrel_mcp_request_state:seal(
        #{user => asked, methods => #{}},
        barrel_mcp_request_state:binding(
            anonymous, <<"resources/read">>, #{<<"uri">> => Uri}
        )
    ),
    WithState = Retry(#{<<"requestState">> => Sealed}),
    ?assertNot(maps:is_key(<<"ttlMs">>, WithState)),
    ?assertNot(maps:is_key(<<"cacheScope">>, WithState)).

cache_hints() ->
    lists:foreach(
        fun({Method, Params}) ->
            Result = result_of(modern(Method, Params)),
            ?assert(is_integer(maps:get(<<"ttlMs">>, Result))),
            ?assertEqual(<<"private">>, maps:get(<<"cacheScope">>, Result))
        end,
        cacheable_methods()
    ).

cache_hints_legacy() ->
    lists:foreach(
        fun({Method, Params}) ->
            Result = result_of(legacy(Method, Params)),
            ?assertNot(maps:is_key(<<"ttlMs">>, Result)),
            ?assertNot(maps:is_key(<<"cacheScope">>, Result))
        end,
        cacheable_methods()
    ).

%% `private' is the default because `public' lets a shared intermediary
%% serve one caller's catalogue to another, which is only safe when
%% every caller sees the same one. A deployment that knows it does can
%% say so.
cache_hints_configurable() ->
    application:set_env(barrel_mcp, cache_scope, <<"public">>),
    application:set_env(barrel_mcp, cache_ttl_ms, 1234),
    try
        Result = result_of(modern(<<"tools/list">>)),
        ?assertEqual(1234, maps:get(<<"ttlMs">>, Result)),
        ?assertEqual(<<"public">>, maps:get(<<"cacheScope">>, Result))
    after
        application:unset_env(barrel_mcp, cache_scope),
        application:unset_env(barrel_mcp, cache_ttl_ms)
    end.

%% The revision names which results are cacheable; nothing else gains
%% the fields just for being modern.
cache_hints_only_where_defined() ->
    Result = result_of(modern(<<"completion/complete">>, #{})),
    ?assertNot(maps:is_key(<<"ttlMs">>, Result)),
    ?assertNot(maps:is_key(<<"cacheScope">>, Result)).

%% How long a body stays fresh is a property of the resource, so a
%% resource that says so wins over the server-wide default.
cache_hints_resource_override() ->
    ok = barrel_mcp_registry:reg(resource, <<"volatile">>, ?MODULE, a_resource, #{
        uri => <<"file:///volatile">>,
        cache_ttl_ms => 250
    }),
    Result = result_of(modern(<<"resources/read">>, #{<<"uri">> => <<"file:///volatile">>})),
    ?assertEqual(250, maps:get(<<"ttlMs">>, Result)),
    %% Another resource still takes the default.
    Other = result_of(modern(<<"resources/read">>, #{<<"uri">> => <<"file:///present">>})),
    ?assertNotEqual(250, maps:get(<<"ttlMs">>, Other)),
    barrel_mcp_registry:unreg(resource, <<"volatile">>).
