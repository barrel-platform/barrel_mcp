%%%-------------------------------------------------------------------
%%% @doc One listener, both protocol eras.
%%%
%%% MCP 2026-07-28 is stateless: no `initialize', no `Mcp-Session-Id'.
%%% 2025-11-25 and earlier need both. The spec permits one server to
%%% serve both on the same endpoint, and this suite is the proof: the
%%% same assertions are run twice against one listener, once as a
%%% legacy client with a session and once as a modern client without
%%% one, plus the negotiation and status-code vectors specific to the
%%% modern binding.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_dual_era_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    modern_tools_list_without_session/1,
    modern_tools_call_without_session/1,
    modern_resources_read/1,
    legacy_still_needs_session/1,
    legacy_and_modern_on_one_listener/1,
    modern_never_mints_a_session/1,
    modern_ignores_session_header/1,
    unsupported_version_returns_400/1,
    unknown_method_returns_404/1,
    missing_capabilities_returns_400/1,
    resource_not_found_status/1,
    modern_notification_returns_202/1,
    modern_tool_error_stays_200/1,
    modern_progress_on_response_stream/1,
    modern_without_progress_token_is_plain_json/1,
    discover_over_http/1,
    missing_protocol_version_header/1,
    protocol_version_header_mismatch/1,
    non_binary_protocol_version/1,
    method_header_mismatch/1,
    name_header_mismatch/1,
    param_header_mirrored/1,
    param_header_mismatch/1,
    legacy_needs_no_metadata_headers/1,
    cors_allows_metadata_headers/1,
    modern_sse_carries_no_event_id/1,
    modern_only_refuses_get_and_delete/1,
    modern_logs_only_when_opted_in/1,
    modern_logs_below_requested_level_are_dropped/1,
    modern_unknown_log_level_is_invalid_params/1
]).

-define(BASE_PORT, 21400).
-define(MODERN, <<"2026-07-28">>).

%% A tool per outcome we need to observe on the wire.
-export([
    echo_tool/1, boom_tool/1, a_resource/1, counting_tool/2, region_tool/1, chatty_tool/2
]).

all() ->
    [
        modern_tools_list_without_session,
        modern_tools_call_without_session,
        modern_resources_read,
        legacy_still_needs_session,
        legacy_and_modern_on_one_listener,
        modern_never_mints_a_session,
        modern_ignores_session_header,
        unsupported_version_returns_400,
        unknown_method_returns_404,
        missing_capabilities_returns_400,
        resource_not_found_status,
        modern_notification_returns_202,
        modern_tool_error_stays_200,
        modern_progress_on_response_stream,
        modern_without_progress_token_is_plain_json,
        discover_over_http,
        missing_protocol_version_header,
        protocol_version_header_mismatch,
        non_binary_protocol_version,
        method_header_mismatch,
        name_header_mismatch,
        param_header_mirrored,
        param_header_mismatch,
        legacy_needs_no_metadata_headers,
        cors_allows_metadata_headers,
        modern_sse_carries_no_event_id,
        modern_only_refuses_get_and_delete,
        modern_logs_only_when_opted_in,
        modern_logs_below_requested_level_are_dropped,
        modern_unknown_log_level_is_invalid_params
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echoes its input">>
    }),
    ok = barrel_mcp:reg_tool(<<"boom">>, ?MODULE, boom_tool, #{
        description => <<"Always crashes">>
    }),
    ok = barrel_mcp:reg_tool(<<"counter">>, ?MODULE, counting_tool, #{
        description => <<"Reports progress, then finishes">>
    }),
    ok = barrel_mcp:reg_tool(<<"chatty">>, ?MODULE, chatty_tool, #{
        description => <<"Logs at two levels, then finishes">>
    }),
    ok = barrel_mcp:reg_tool(<<"regional">>, ?MODULE, region_tool, #{
        description => <<"Mirrors its region argument into a header">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"region">> => #{
                    <<"type">> => <<"string">>,
                    <<"x-mcp-header">> => <<"Region">>
                },
                <<"query">> => #{<<"type">> => <<"string">>}
            }
        }
    }),
    ok = barrel_mcp:reg_resource(<<"res">>, ?MODULE, a_resource, #{
        uri => <<"file:///present">>,
        description => <<"A resource">>
    }),
    Config.

end_per_suite(_Config) ->
    barrel_mcp_registry:unreg(tool, <<"echo">>),
    barrel_mcp_registry:unreg(tool, <<"boom">>),
    barrel_mcp_registry:unreg(tool, <<"counter">>),
    barrel_mcp_registry:unreg(tool, <<"chatty">>),
    barrel_mcp_registry:unreg(tool, <<"regional">>),
    barrel_mcp_registry:unreg(resource, <<"res">>),
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    application:stop(barrel_mcp),
    ok.

init_per_testcase(TC, Config) ->
    Port = ?BASE_PORT + case_index(TC),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true
    }),
    [{port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    timer:sleep(50),
    ok.

echo_tool(Args) ->
    <<"Echo: ", (maps:get(<<"input">>, Args, <<"none">>))/binary>>.

boom_tool(_Args) ->
    error(deliberate_crash).

a_resource(_Args) ->
    <<"resource body">>.

region_tool(Args) ->
    maps:get(<<"region">>, Args, <<"none">>).

%% Arity 2 so it can reach the progress hook in Ctx.
chatty_tool(_Args, Ctx) ->
    ok = barrel_mcp:log(Ctx, debug, <<"db">>, <<"opening">>),
    ok = barrel_mcp:log(Ctx, error, <<"db">>, <<"it broke">>),
    <<"chatted">>.

counting_tool(_Args, Ctx) ->
    Emit = maps:get(emit_progress, Ctx),
    Emit(1, 3, <<"step one">>),
    Emit(2, 3, <<"step two">>),
    Emit(3, 3, <<"step three">>),
    <<"counted">>.

%%====================================================================
%% Modern requests need no session
%%====================================================================

modern_tools_list_without_session(Config) ->
    Port = ?config(port, Config),
    {200, Headers, Body} = post_modern(Port, modern_request(1, <<"tools/list">>, #{}), []),
    Result = result_of(Body),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assert(is_list(maps:get(<<"tools">>, Result))),
    %% Stateless: nothing to resume, nothing to echo.
    ?assertEqual(undefined, header(<<"mcp-session-id">>, Headers)),
    %% And the server identified itself.
    Meta = maps:get(<<"_meta">>, Result),
    ?assert(maps:is_key(?MCP_META_SERVER_INFO, Meta)),
    ok.

modern_tools_call_without_session(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"echo">>, <<"arguments">> => #{<<"input">> => <<"hi">>}},
    {200, _, Body} = post_modern(Port, modern_request(2, <<"tools/call">>, Params), []),
    Result = result_of(Body),
    %% The async tool path builds its own envelope, so this is the
    %% assertion that the transport decorates it too.
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"Echo: hi">>, maps:get(<<"text">>, Block)),
    ok.

modern_resources_read(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"uri">> => <<"file:///present">>},
    {200, _, Body} = post_modern(Port, modern_request(3, <<"resources/read">>, Params), []),
    Result = result_of(Body),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    [Content] = maps:get(<<"contents">>, Result),
    ?assertEqual(<<"resource body">>, maps:get(<<"text">>, Content)),
    ok.

%%====================================================================
%% Legacy is untouched
%%====================================================================

legacy_still_needs_session(Config) ->
    Port = ?config(port, Config),
    %% A legacy request with no session is rejected exactly as before.
    {400, _, Body} = post(Port, legacy_request(1, <<"tools/list">>, #{}), []),
    ?assertMatch(#{<<"error">> := _}, json:decode(Body)),
    ok.

%% The headline test: both eras served concurrently on one listener,
%% neither disturbing the other.
legacy_and_modern_on_one_listener(Config) ->
    Port = ?config(port, Config),

    %% Legacy client: handshake, get a session, use it.
    {200, InitHeaders, _} = post(Port, init_body(), []),
    SessionId = header(<<"mcp-session-id">>, InitHeaders),
    ?assert(is_binary(SessionId)),
    SessionHdr = [{<<"mcp-session-id">>, SessionId}],

    %% Modern client interleaved, holding no session at all.
    {200, _, ModernBody} = post_modern(Port, modern_request(10, <<"tools/list">>, #{}), []),
    ModernResult = result_of(ModernBody),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, ModernResult)),

    %% Legacy call still works, and is still undecorated.
    LegacyParams = #{<<"name">> => <<"echo">>, <<"arguments">> => #{<<"input">> => <<"legacy">>}},
    {200, _, LegacyBody} = post(
        Port, legacy_request(11, <<"tools/call">>, LegacyParams), SessionHdr
    ),
    LegacyResult = result_of(LegacyBody),
    ?assertNot(maps:is_key(<<"resultType">>, LegacyResult)),
    [LegacyBlock] = maps:get(<<"content">>, LegacyResult),
    ?assertEqual(<<"Echo: legacy">>, maps:get(<<"text">>, LegacyBlock)),

    %% Modern call after the legacy one: still stateless, still decorated.
    ModernParams = #{<<"name">> => <<"echo">>, <<"arguments">> => #{<<"input">> => <<"modern">>}},
    {200, ModernHeaders, ModernCallBody} = post_modern(
        Port, modern_request(12, <<"tools/call">>, ModernParams), []
    ),
    ModernCallResult = result_of(ModernCallBody),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, ModernCallResult)),
    [ModernBlock] = maps:get(<<"content">>, ModernCallResult),
    ?assertEqual(<<"Echo: modern">>, maps:get(<<"text">>, ModernBlock)),
    ?assertEqual(undefined, header(<<"mcp-session-id">>, ModernHeaders)),

    %% The legacy session survived the modern traffic.
    {200, _, StillBody} = post(Port, legacy_request(13, <<"tools/list">>, #{}), SessionHdr),
    ?assert(maps:is_key(<<"tools">>, result_of(StillBody))),
    ok.

modern_never_mints_a_session(Config) ->
    Port = ?config(port, Config),
    Before = length(barrel_mcp_session:list()),
    {200, _, _} = post_modern(Port, modern_request(1, <<"tools/list">>, #{}), []),
    {200, _, _} = post_modern(Port, modern_request(2, <<"tools/list">>, #{}), []),
    ?assertEqual(Before, length(barrel_mcp_session:list())),
    ok.

%% An older intermediary may still attach one. It has no meaning in
%% this era, so it must be ignored rather than rejected.
modern_ignores_session_header(Config) ->
    Port = ?config(port, Config),
    Hdrs = [{<<"mcp-session-id">>, <<"no-such-session">>}],
    {200, RespHeaders, Body} = post_modern(Port, modern_request(1, <<"tools/list">>, #{}), Hdrs),
    ?assert(maps:is_key(<<"tools">>, result_of(Body))),
    ?assertEqual(undefined, header(<<"mcp-session-id">>, RespHeaders)),
    ok.

%%====================================================================
%% Status codes on the modern binding
%%====================================================================

unsupported_version_returns_400(Config) ->
    Port = ?config(port, Config),
    Body0 = request_at_version(1, <<"tools/list">>, #{}, <<"1900-01-01">>),
    {400, _, Body} = post_modern(Port, Body0, []),
    Error = error_of(Body),
    ?assertEqual(?MCP_UNSUPPORTED_PROTOCOL_VERSION, maps:get(<<"code">>, Error)),
    Data = maps:get(<<"data">>, Error),
    ?assertEqual(<<"1900-01-01">>, maps:get(<<"requested">>, Data)),
    ?assertEqual(?MCP_MODERN_VERSIONS, maps:get(<<"supported">>, Data)),
    ok.

unknown_method_returns_404(Config) ->
    Port = ?config(port, Config),
    {404, _, Body} = post_modern(Port, modern_request(1, <<"no/such/method">>, #{}), []),
    ?assertEqual(?JSONRPC_METHOD_NOT_FOUND, maps:get(<<"code">>, error_of(Body))),
    %% A method the 2026-07-28 revision removed is unknown too, and the
    %% JSON-RPC body is what distinguishes this 404 from a legacy
    %% HTTP+SSE server that does not host the endpoint at all.
    {404, _, PingBody} = post_modern(Port, modern_request(2, <<"ping">>, #{}), []),
    ?assertEqual(?JSONRPC_METHOD_NOT_FOUND, maps:get(<<"code">>, error_of(PingBody))),
    ok.

missing_capabilities_returns_400(Config) ->
    Port = ?config(port, Config),
    Body0 = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"tools/list">>,
        <<"params">> => #{
            <<"_meta">> => #{?MCP_META_PROTOCOL_VERSION => ?MODERN}
        }
    }),
    {400, _, Body} = post_modern(Port, Body0, []),
    ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, error_of(Body))),
    ok.

resource_not_found_status(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"uri">> => <<"file:///absent">>},
    {400, _, Body} = post_modern(Port, modern_request(1, <<"resources/read">>, Params), []),
    ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, error_of(Body))),
    ok.

modern_notification_returns_202(Config) ->
    Port = ?config(port, Config),
    Notification = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/progress">>,
        <<"params">> => #{<<"_meta">> => modern_meta()}
    }),
    {202, _, Body} = post_modern(Port, Notification, []),
    ?assertEqual(<<>>, Body),
    ok.

%% A tool that crashes is an application failure, not a malformed
%% request: it stays 200 with the error in the body.
modern_tool_error_stays_200(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"boom">>, <<"arguments">> => #{}},
    {200, _, Body} = post_modern(Port, modern_request(1, <<"tools/call">>, Params), []),
    ?assertEqual(?MCP_TOOL_ERROR, maps:get(<<"code">>, error_of(Body))),
    ok.

%%====================================================================
%% Request metadata headers
%%====================================================================

%% Sent without post_modern/3, so no mirrored headers are attached.
missing_protocol_version_header(Config) ->
    Port = ?config(port, Config),
    {400, _, Body} = post(Port, modern_request(1, <<"tools/list">>, #{}), []),
    Error = error_of(Body),
    ?assertEqual(?MCP_HEADER_MISMATCH, maps:get(<<"code">>, Error)),
    ok.

protocol_version_header_mismatch(Config) ->
    Port = ?config(port, Config),
    Hdrs = [
        {<<"mcp-protocol-version">>, <<"2025-11-25">>},
        {<<"mcp-method">>, <<"tools/list">>}
    ],
    {400, _, Body} = post(Port, modern_request(1, <<"tools/list">>, #{}), Hdrs),
    ?assertEqual(?MCP_HEADER_MISMATCH, maps:get(<<"code">>, error_of(Body))),
    ok.

%% The declared version comes from a peer's _meta and is interpolated
%% into the mismatch message. A number or a null there used to be a
%% badarg while building that message, not an error response.
non_binary_protocol_version(Config) ->
    Port = ?config(port, Config),
    Hdrs = [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"tools/list">>}
    ],
    lists:foreach(
        fun(Version) ->
            Body0 = #{
                <<"jsonrpc">> => <<"2.0">>,
                <<"id">> => 1,
                <<"method">> => <<"tools/list">>,
                <<"params">> => #{
                    <<"_meta">> => #{
                        ?MCP_META_PROTOCOL_VERSION => Version,
                        ?MCP_META_CLIENT_CAPABILITIES => #{}
                    }
                }
            },
            {Status, _, Body} = post(Port, iolist_to_binary(json:encode(Body0)), Hdrs),
            ?assertEqual(400, Status),
            ?assertEqual(?MCP_HEADER_MISMATCH, maps:get(<<"code">>, error_of(Body)))
        end,
        [42, null, #{<<"a">> => 1}, [?MODERN]]
    ),
    ok.

method_header_mismatch(Config) ->
    Port = ?config(port, Config),
    Hdrs = [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"tools/call">>}
    ],
    {400, _, Body} = post(Port, modern_request(1, <<"tools/list">>, #{}), Hdrs),
    ?assertEqual(?MCP_HEADER_MISMATCH, maps:get(<<"code">>, error_of(Body))),
    ok.

name_header_mismatch(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"echo">>, <<"arguments">> => #{}},
    Hdrs = [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, <<"boom">>}
    ],
    {400, _, Body} = post(Port, modern_request(1, <<"tools/call">>, Params), Hdrs),
    ?assertEqual(?MCP_HEADER_MISMATCH, maps:get(<<"code">>, error_of(Body))),
    ok.

%% A tool whose schema opts a parameter in must have it mirrored.
param_header_mirrored(Config) ->
    Port = ?config(port, Config),
    Params = #{
        <<"name">> => <<"regional">>,
        <<"arguments">> => #{<<"region">> => <<"us-west1">>}
    },
    Hdrs = [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, <<"regional">>},
        {<<"mcp-param-region">>, <<"us-west1">>}
    ],
    {200, _, Body} = post(Port, modern_request(1, <<"tools/call">>, Params), Hdrs),
    [Block] = maps:get(<<"content">>, result_of(Body)),
    ?assertEqual(<<"us-west1">>, maps:get(<<"text">>, Block)),

    %% Omitting it is a mismatch: an intermediary may have routed on it.
    {400, _, Missing} = post(
        Port, modern_request(2, <<"tools/call">>, Params), lists:droplast(Hdrs)
    ),
    ?assertEqual(?MCP_HEADER_MISMATCH, maps:get(<<"code">>, error_of(Missing))),
    ok.

%% The routing case the validation exists for: a gateway sends traffic
%% to one region while the body asks for another.
param_header_mismatch(Config) ->
    Port = ?config(port, Config),
    Params = #{
        <<"name">> => <<"regional">>,
        <<"arguments">> => #{<<"region">> => <<"us-west1">>}
    },
    Hdrs = [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, <<"regional">>},
        {<<"mcp-param-region">>, <<"eu-central1">>}
    ],
    {400, _, Body} = post(Port, modern_request(1, <<"tools/call">>, Params), Hdrs),
    ?assertEqual(?MCP_HEADER_MISMATCH, maps:get(<<"code">>, error_of(Body))),
    ok.

%% None of this applies to a legacy client, which predates the headers.
legacy_needs_no_metadata_headers(Config) ->
    Port = ?config(port, Config),
    {200, InitHeaders, _} = post(Port, init_body(), []),
    SessionId = header(<<"mcp-session-id">>, InitHeaders),
    {200, _, Body} = post(
        Port,
        legacy_request(2, <<"tools/list">>, #{}),
        [{<<"mcp-session-id">>, SessionId}]
    ),
    ?assert(maps:is_key(<<"tools">>, result_of(Body))),
    ok.

%% A browser client cannot send a header the preflight did not allow,
%% and Access-Control-Allow-Headers has no prefix form, so every
%% mirrored parameter has to be named.
cors_allows_metadata_headers(Config) ->
    Port = ?config(port, Config),
    {ok, 204, Headers, _} = hackney:request(
        options,
        url(Port),
        [
            {<<"origin">>, <<"http://localhost:5173">>},
            {<<"access-control-request-method">>, <<"POST">>}
        ],
        <<>>,
        [with_body]
    ),
    Allowed = header(<<"access-control-allow-headers">>, Headers),
    lists:foreach(
        fun(Name) ->
            ?assertNotEqual(nomatch, binary:match(Allowed, Name))
        end,
        [
            <<"mcp-protocol-version">>,
            <<"mcp-method">>,
            <<"mcp-name">>,
            %% From the `regional' tool's x-mcp-header annotation.
            <<"mcp-param-region">>
        ]
    ),
    ok.

%%====================================================================
%% Discovery
%%====================================================================

%% Reachable without a session, and reachable by a bare probe carrying
%% no metadata at all.
discover_over_http(Config) ->
    Port = ?config(port, Config),
    {200, Headers, Body} = post_modern(Port, modern_request(1, <<"server/discover">>, #{}), []),
    ?assertEqual(undefined, header(<<"mcp-session-id">>, Headers)),
    Result = result_of(Body),
    ?assertEqual(?MCP_MODERN_VERSIONS, maps:get(<<"supportedVersions">>, Result)),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),

    {200, _, ProbeBody} = post(Port, legacy_request(2, <<"server/discover">>, #{}), []),
    ?assertEqual(
        ?MCP_MODERN_VERSIONS,
        maps:get(<<"supportedVersions">>, result_of(ProbeBody))
    ),
    ok.

%%====================================================================
%% Progress
%%====================================================================

%% 2026-07-28 puts request-scoped notifications on the response stream
%% of the request they relate to, not on a side channel.
modern_progress_on_response_stream(Config) ->
    Port = ?config(port, Config),
    Params = #{
        <<"name">> => <<"counter">>,
        <<"arguments">> => #{}
    },
    Body = modern_request_with_progress(1, <<"tools/call">>, Params, <<"tok-1">>),
    {200, Headers, Events} = post_sse(Port, Body),

    <<"text/event-stream", _/binary>> = header(<<"content-type">>, Headers),
    %% Proxies must not buffer a progress stream.
    ?assertEqual(<<"no">>, header(<<"x-accel-buffering">>, Headers)),

    {Notifications, [Final]} = lists:splitwith(
        fun(E) -> maps:is_key(<<"method">>, E) end, Events
    ),
    ?assertEqual(3, length(Notifications)),
    lists:foreach(
        fun(N) ->
            ?assertEqual(<<"notifications/progress">>, maps:get(<<"method">>, N)),
            P = maps:get(<<"params">>, N),
            ?assertEqual(<<"tok-1">>, maps:get(<<"progressToken">>, P)),
            ?assertEqual(3, maps:get(<<"total">>, P))
        end,
        Notifications
    ),
    [First | _] = Notifications,
    ?assertEqual(
        <<"step one">>,
        maps:get(<<"message">>, maps:get(<<"params">>, First))
    ),

    %% The final response terminates the stream and is decorated.
    Result = maps:get(<<"result">>, Final),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"counted">>, maps:get(<<"text">>, Block)),
    ok.

%% No progress token means nothing to stream, so the reply stays a
%% single JSON object.
modern_without_progress_token_is_plain_json(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"counter">>, <<"arguments">> => #{}},
    {200, Headers, Body} = post_modern(Port, modern_request(1, <<"tools/call">>, Params), []),
    <<"application/json", _/binary>> = header(<<"content-type">>, Headers),
    [Block] = maps:get(<<"content">>, result_of(Body)),
    ?assertEqual(<<"counted">>, maps:get(<<"text">>, Block)),
    ok.

%%====================================================================
%% Modern stream shape
%%====================================================================

%% "Resumable SSE streams via `Last-Event-ID' are not supported"
%% (2026-07-28/basic/transports/streamable-http.mdx:157). An `id:' line
%% is what a client resumes from, so emitting one would advertise a
%% replay this revision cannot serve.
modern_sse_carries_no_event_id(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"counter">>, <<"arguments">> => #{}},
    Body = modern_request_with_progress(1, <<"tools/call">>, Params, <<"tok-1">>),
    {200, Headers, Raw} = post_sse_raw(Port, Body),
    <<"text/event-stream", _/binary>> = header(<<"content-type">>, Headers),
    %% Every block still carries data, so the absence is of ids alone.
    ?assert(length(decode_sse(Raw)) >= 2),
    ?assertEqual(nomatch, binary:match(Raw, <<"\nid: ">>)),
    ?assertNotMatch(<<"id: ", _/binary>>, Raw),
    ok.

%% With sessions off only 2026-07-28 is served, and that revision has
%% neither a standalone GET stream nor a DELETE to end a session
%% (streamable-http.mdx:683).
modern_only_refuses_get_and_delete(Config) ->
    Port = ?config(port, Config),
    ok = barrel_mcp:stop_http_stream(),
    timer:sleep(50),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    lists:foreach(
        fun(Method) ->
            {ok, Status, RespHeaders, _} = hackney:request(
                Method, url(Port), [], <<>>, [with_body]
            ),
            ?assertEqual(405, Status),
            ?assertEqual(<<"POST, OPTIONS">>, header(<<"allow">>, RespHeaders))
        end,
        [get, delete]
    ),
    %% POST still works, so the listener is refusing the method rather
    %% than being broken.
    Body = modern_request(1, <<"tools/list">>, #{}),
    {200, _, _} = post_modern(Port, Body, []),
    ok.

%%====================================================================
%% Logging opt-in
%%====================================================================

%% "The server MUST NOT emit notifications/message for a request that
%% does not include this field"
%% (2026-07-28/server/utilities/logging.mdx:64). The same tool logs
%% either way, so the request's `_meta' is the only thing deciding it.
modern_logs_only_when_opted_in(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"chatty">>, <<"arguments">> => #{}},

    {200, Silent, SilentBody} = post_modern(
        Port, modern_request(1, <<"tools/call">>, Params), []
    ),
    <<"application/json", _/binary>> = header(<<"content-type">>, Silent),
    ?assertEqual(nomatch, binary:match(SilentBody, <<"notifications/message">>)),

    Body = modern_request_with_log_level(1, <<"tools/call">>, Params, <<"debug">>),
    {200, Headers, Events} = post_sse(Port, Body),
    <<"text/event-stream", _/binary>> = header(<<"content-type">>, Headers),
    {Notifications, [Final]} = lists:splitwith(
        fun(E) -> maps:is_key(<<"method">>, E) end, Events
    ),
    ?assertEqual(
        [<<"notifications/message">>, <<"notifications/message">>],
        [maps:get(<<"method">>, N) || N <- Notifications]
    ),
    [First, Second] = [maps:get(<<"params">>, N) || N <- Notifications],
    ?assertEqual(<<"debug">>, maps:get(<<"level">>, First)),
    ?assertEqual(<<"db">>, maps:get(<<"logger">>, First)),
    ?assertEqual(<<"opening">>, maps:get(<<"data">>, First)),
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Second)),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Final)),
    ?assertEqual(<<"chatted">>, maps:get(<<"text">>, Block)),
    ok.

%% The level names a floor, so the `debug' line is dropped and the
%% `error' one survives.
modern_logs_below_requested_level_are_dropped(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"chatty">>, <<"arguments">> => #{}},
    Body = modern_request_with_log_level(1, <<"tools/call">>, Params, <<"warning">>),
    {200, _Headers, Events} = post_sse(Port, Body),
    {Notifications, [_Final]} = lists:splitwith(
        fun(E) -> maps:is_key(<<"method">>, E) end, Events
    ),
    ?assertEqual(1, length(Notifications)),
    [Only] = [maps:get(<<"params">>, N) || N <- Notifications],
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Only)),
    ok.

%% "If the io.modelcontextprotocol/logLevel value ... is not a
%% recognized log level, the server SHOULD reject that request" with
%% -32602 (logging.mdx:100).
modern_unknown_log_level_is_invalid_params(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"echo">>, <<"arguments">> => #{}},
    Body = modern_request_with_log_level(1, <<"tools/call">>, Params, <<"chatty">>),
    {400, _, RespBody} = post_modern(Port, Body, []),
    Error = maps:get(<<"error">>, json:decode(RespBody)),
    ?assertEqual(-32602, maps:get(<<"code">>, Error)),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

url(Port) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])).

%% Derive the mirrored metadata headers from the body itself, exactly
%% as a conforming client does. Using the same module the server
%% validates with is deliberate: if the two ever disagree, these tests
%% fail rather than some downstream client.
post_modern(Port, Body, ExtraHeaders) ->
    Decoded = json:decode(iolist_to_binary(Body)),
    Params =
        case maps:get(<<"params">>, Decoded, #{}) of
            P when is_map(P) -> P;
            _ -> #{}
        end,
    Meta = maps:get(<<"_meta">>, Params, #{}),
    Version = maps:get(?MCP_META_PROTOCOL_VERSION, Meta, ?MODERN),
    Method = maps:get(<<"method">>, Decoded, <<>>),
    Headers =
        [{<<"mcp-protocol-version">>, Version}] ++
            barrel_mcp_headers:standard(Method, Params) ++
            ExtraHeaders,
    post(Port, Body, Headers).

post(Port, Body, ExtraHeaders) ->
    Headers =
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ] ++ ExtraHeaders,
    {ok, Status, RespHeaders, RespBody} = hackney:request(
        post, url(Port), Headers, Body, [with_body]
    ),
    {Status, RespHeaders, RespBody}.

header(Name, Headers) ->
    Lower = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(K) =:= Lower end, Headers) of
        {value, {_, V}} -> V;
        false -> undefined
    end.

modern_meta() ->
    #{
        ?MCP_META_PROTOCOL_VERSION => ?MODERN,
        ?MCP_META_CLIENT_CAPABILITIES => #{},
        ?MCP_META_CLIENT_INFO => #{
            <<"name">> => <<"dual-era-suite">>,
            <<"version">> => <<"1.0">>
        }
    }.

modern_request(Id, Method, Params) ->
    request_at_version(Id, Method, Params, ?MODERN).

request_at_version(Id, Method, Params, Version) ->
    Meta = (modern_meta())#{?MCP_META_PROTOCOL_VERSION => Version},
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => Meta}
    }).

modern_request_with_log_level(Id, Method, Params, Level) ->
    Meta = (modern_meta())#{?MCP_META_LOG_LEVEL => Level},
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => Meta}
    }).

modern_request_with_progress(Id, Method, Params, Token) ->
    Meta = (modern_meta())#{<<"progressToken">> => Token},
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => Meta}
    }).

legacy_request(Id, Method, Params) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }).

init_body() ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{
                <<"name">> => <<"dual-era-suite">>,
                <<"version">> => <<"1.0">>
            }
        }
    }).

%% Read a streamed response to completion and return its SSE events in
%% order, decoded.
post_sse(Port, Body) ->
    {Status, Headers, Raw} = post_sse_raw(Port, Body),
    {Status, Headers, decode_sse(Raw)}.

%% The same request, left as bytes: a case that asserts on the SSE
%% framing itself cannot use the decoded events.
post_sse_raw(Port, Body) ->
    Decoded = json:decode(iolist_to_binary(Body)),
    Params = maps:get(<<"params">>, Decoded, #{}),
    Headers =
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"mcp-protocol-version">>, ?MODERN}
        ] ++
            barrel_mcp_headers:standard(maps:get(<<"method">>, Decoded, <<>>), Params),
    {ok, Status, RespHeaders, Raw} = hackney:request(
        post, url(Port), Headers, Body, [with_body]
    ),
    {Status, RespHeaders, Raw}.

decode_sse(Raw) ->
    Blocks = binary:split(Raw, <<"\n\n">>, [global]),
    lists:filtermap(
        fun(Block) ->
            case sse_data(Block) of
                undefined -> false;
                Data -> {true, json:decode(Data)}
            end
        end,
        Blocks
    ).

sse_data(Block) ->
    Lines = binary:split(Block, <<"\n">>, [global]),
    case [V || <<"data: ", V/binary>> <- Lines] of
        [] -> undefined;
        Datas -> iolist_to_binary(lists:join(<<"\n">>, Datas))
    end.

result_of(Body) ->
    maps:get(<<"result">>, json:decode(Body)).

error_of(Body) ->
    maps:get(<<"error">>, json:decode(Body)).

%% A port per case, by position rather than by hash: two case names
%% hashing to the same slot means the second one gets eaddrinuse while
%% the first listener is still releasing its socket.
case_index(TC) ->
    case_index(TC, all(), 0).

case_index(TC, [TC | _], N) -> N;
case_index(TC, [_ | Rest], N) -> case_index(TC, Rest, N + 1);
case_index(_TC, [], N) -> N.
