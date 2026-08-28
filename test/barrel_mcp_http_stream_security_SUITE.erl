%%%-------------------------------------------------------------------
%%% @doc Security and spec-conformance suite for the Streamable HTTP
%%% transport. Locks in the behaviour added by the transport
%%% hardening change: Origin validation, default loopback bind,
%%% session 400/404 distinction, MCP-Protocol-Version validation,
%%% notification 202 response shape, JSON-RPC id strictness, batch
%%% rejection.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_stream_security_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(barrel_mcp_test_helpers, [url/1]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    origin_loopback_default_allows/1,
    origin_loopback_rejects_external/1,
    origin_null_rejected_by_default/1,
    public_bind_requires_allowed_origins/1,
    session_init_creates/1,
    session_missing_returns_400/1,
    session_unknown_returns_404/1,
    notification_returns_202/1,
    response_post_returns_202/1,
    protocol_version_unsupported_returns_400/1,
    protocol_version_present_supported_ok/1,
    batch_rejected/1,
    id_null_rejected/1,
    id_object_rejected/1,
    ets_session_table_protected/1,
    accept_only_json_rejected/1,
    accept_only_sse_rejected/1,
    accept_wildcard_ok/1,
    initialize_with_unknown_session_returns_404/1,
    prm_endpoint_serves_metadata/1,
    bearer_challenge_includes_resource_metadata/1,
    get_sse_requires_auth/1,
    delete_requires_auth/1
]).

-define(BASE_PORT, 21100).

all() ->
    [
        origin_loopback_default_allows,
        origin_loopback_rejects_external,
        origin_null_rejected_by_default,
        public_bind_requires_allowed_origins,
        session_init_creates,
        session_missing_returns_400,
        session_unknown_returns_404,
        notification_returns_202,
        response_post_returns_202,
        protocol_version_unsupported_returns_400,
        protocol_version_present_supported_ok,
        batch_rejected,
        id_null_rejected,
        id_object_rejected,
        ets_session_table_protected,
        accept_only_json_rejected,
        accept_only_sse_rejected,
        accept_wildcard_ok,
        initialize_with_unknown_session_returns_404,
        prm_endpoint_serves_metadata,
        bearer_challenge_includes_resource_metadata,
        get_sse_requires_auth,
        delete_requires_auth
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    Config.

end_per_suite(_Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    application:stop(barrel_mcp),
    ok.

init_per_testcase(TC, Config) ->
    Port = ?BASE_PORT + erlang:phash2(TC, 100),
    [{port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    timer:sleep(50),
    ok.

%%====================================================================
%% Origin validation
%%====================================================================

origin_loopback_default_allows(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    %% Loopback Origin is allowed by default.
    {200, _, _} = post_init(Port, [{<<"origin">>, <<"http://localhost:5173">>}]),
    ok.

origin_loopback_rejects_external(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    {ok, 403, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"origin">>, <<"https://attacker.example">>}
        ],
        init_body(),
        [with_body]
    ),
    ok.

origin_null_rejected_by_default(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    {ok, 403, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"origin">>, <<"null">>}
        ],
        init_body(),
        [with_body]
    ),
    ok.

public_bind_requires_allowed_origins(_Config) ->
    %% Bind 0.0.0.0 without explicit allowed_origins must refuse.
    ?assertEqual(
        {error, allowed_origins_required},
        barrel_mcp:start_http_stream(#{
            port => 21199,
            ip => {0, 0, 0, 0}
        })
    ).

%%====================================================================
%% Session lookup
%%====================================================================

session_init_creates(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true
    }),
    {200, Headers, _} = post_init(Port, []),
    SessionId = proplists:get_value(<<"mcp-session-id">>, Headers),
    ?assertMatch(<<"mcp_", _/binary>>, SessionId),
    ok.

session_missing_returns_400(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true
    }),
    %% A non-initialize request without Mcp-Session-Id is 400.
    {ok, 400, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        ping_body(),
        [with_body]
    ),
    ok.

session_unknown_returns_404(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true
    }),
    {ok, 404, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"mcp-session-id">>, <<"mcp_not_a_real_session">>}
        ],
        ping_body(),
        [with_body]
    ),
    ok.

%%====================================================================
%% Response shape
%%====================================================================

notification_returns_202(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    Notif = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/initialized">>
    }),
    {ok, 202, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        Notif,
        [with_body]
    ),
    ok.

response_post_returns_202(Config) ->
    %% A JSON-RPC RESPONSE (carries result) for a server-initiated
    %% request must return 202.
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    Resp = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => <<"sampling-1">>,
        <<"result">> => #{<<"ok">> => true}
    }),
    {ok, 202, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        Resp,
        [with_body]
    ),
    ok.

%%====================================================================
%% Protocol version validation
%%====================================================================

protocol_version_unsupported_returns_400(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true
    }),
    {200, Headers, _} = post_init(Port, []),
    SessionId = proplists:get_value(<<"mcp-session-id">>, Headers),
    {ok, 400, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"mcp-session-id">>, SessionId},
            {<<"mcp-protocol-version">>, <<"1999-01-01">>}
        ],
        ping_body(),
        [with_body]
    ),
    ok.

protocol_version_present_supported_ok(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true
    }),
    {200, Headers, _} = post_init(Port, []),
    SessionId = proplists:get_value(<<"mcp-session-id">>, Headers),
    {ok, 200, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"mcp-session-id">>, SessionId},
            {<<"mcp-protocol-version">>, <<"2025-11-25">>}
        ],
        ping_body(),
        [with_body]
    ),
    ok.

%%====================================================================
%% JSON-RPC strictness
%%====================================================================

batch_rejected(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    Batch = json:encode([
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 1,
            <<"method">> => <<"ping">>
        }
    ]),
    {ok, 400, _, Body} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        Batch,
        [with_body]
    ),
    Resp = json:decode(Body),
    ?assertEqual(
        -32600,
        maps:get(
            <<"code">>,
            maps:get(<<"error">>, Resp)
        )
    ),
    ok.

id_null_rejected(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    Body0 = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => null,
        <<"method">> => <<"ping">>
    }),
    {ok, _, _, Body} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        Body0,
        [with_body]
    ),
    Resp = json:decode(Body),
    ?assertEqual(
        -32600,
        maps:get(
            <<"code">>,
            maps:get(<<"error">>, Resp)
        )
    ).

id_object_rejected(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    Body0 = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => #{<<"foo">> => 1},
        <<"method">> => <<"ping">>
    }),
    {ok, _, _, Body} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        Body0,
        [with_body]
    ),
    Resp = json:decode(Body),
    ?assertEqual(
        -32600,
        maps:get(
            <<"code">>,
            maps:get(<<"error">>, Resp)
        )
    ).

%%====================================================================
%% Accept-header strictness
%%====================================================================

accept_only_json_rejected(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    {ok, 406, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json">>}
        ],
        ping_body(),
        [with_body]
    ),
    ok.

accept_only_sse_rejected(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    {ok, 406, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"text/event-stream">>}
        ],
        ping_body(),
        [with_body]
    ),
    ok.

accept_wildcard_ok(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => false
    }),
    {ok, 200, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"*/*">>}
        ],
        ping_body(),
        [with_body]
    ),
    ok.

%%====================================================================
%% Initialize with unknown session id
%%====================================================================

initialize_with_unknown_session_returns_404(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true
    }),
    {ok, 404, _, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"mcp-session-id">>, <<"mcp_does_not_exist">>}
        ],
        init_body(),
        [with_body]
    ),
    ok.

%%====================================================================
%% ETS visibility
%%====================================================================

ets_session_table_protected(_Config) ->
    %% A non-owning process must not be able to write the session
    %% table. We assert by attempting an `ets:insert/2' from the
    %% test process, which is not the gen_server.
    {ok, _Sid} = barrel_mcp_session:create(#{}),
    Caught =
        try
            _ = ets:insert(barrel_mcp_sessions, {<<"x">>, dummy}),
            false
        catch
            error:badarg -> true
        end,
    ?assert(Caught).

%%====================================================================
%% Helpers (no -include_lib for eunit here; it's at the top)
%%====================================================================

init_body() ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{
                <<"name">> => <<"sec-suite">>,
                <<"version">> => <<"1.0">>
            }
        }
    }).

ping_body() ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 99,
        <<"method">> => <<"ping">>
    }).

%%====================================================================
%% OAuth Protected Resource Metadata (RFC 9728)
%%====================================================================

prm_endpoint_serves_metadata(Config) ->
    Port = ?config(port, Config),
    ResourceUrl = iolist_to_binary(
        io_lib:format(
            "http://127.0.0.1:~B/mcp", [Port]
        )
    ),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true,
        resource_metadata => #{
            resource => ResourceUrl,
            authorization_servers => [<<"https://idp.example.com">>]
        }
    }),
    PrmUrl = iolist_to_binary(
        io_lib:format(
            "http://127.0.0.1:~B/.well-known/oauth-protected-resource",
            [Port]
        )
    ),
    {ok, 200, Headers, Body} = hackney:request(
        get,
        PrmUrl,
        [],
        <<>>,
        [with_body]
    ),
    %% application/json content-type.
    <<"application/json", _/binary>> =
        proplists:get_value(
            <<"content-type">>,
            Headers,
            <<"application/json">>
        ),
    Doc = json:decode(Body),
    ?assertEqual(ResourceUrl, maps:get(<<"resource">>, Doc)),
    ?assertEqual(
        [<<"https://idp.example.com">>],
        maps:get(<<"authorization_servers">>, Doc)
    ),
    ok.

bearer_challenge_includes_resource_metadata(Config) ->
    Port = ?config(port, Config),
    ResourceUrl = iolist_to_binary(
        io_lib:format(
            "http://127.0.0.1:~B/mcp", [Port]
        )
    ),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true,
        auth => #{
            provider => barrel_mcp_auth_bearer,
            provider_opts => #{secret => <<"top-secret">>}
        },
        resource_metadata => #{
            resource => ResourceUrl,
            authorization_servers => [<<"https://idp.example.com">>]
        }
    }),
    %% No Authorization header → 401 with the new challenge.
    {ok, 401, Headers, _} = hackney:request(
        post,
        url(Port),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        ping_body(),
        [with_body]
    ),
    Challenge = proplists:get_value(<<"www-authenticate">>, Headers),
    ?assert(is_binary(Challenge)),
    ExpectedSubstr =
        <<"resource_metadata=\"http://127.0.0.1:", (integer_to_binary(Port))/binary,
            "/.well-known/oauth-protected-resource\"">>,
    ?assertNotEqual(nomatch, binary:match(Challenge, ExpectedSubstr)),
    %% Make sure the legacy non-conformant `resource="..."' is gone.
    ?assertEqual(nomatch, binary:match(Challenge, <<" resource=\"">>)),
    ok.

%%====================================================================
%% Auth is enforced on every verb, not just POST
%%====================================================================

%% A GET (open SSE) with no credentials must be rejected by the auth
%% provider before any session is touched — the session id is not a
%% credential. Regression for the GET/DELETE auth-bypass.
get_sse_requires_auth(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true,
        auth => #{
            provider => barrel_mcp_auth_bearer,
            provider_opts => #{secret => <<"top-secret">>}
        }
    }),
    {ok, 401, _, _} = hackney:request(
        get,
        url(Port),
        [
            {<<"accept">>, <<"text/event-stream">>},
            {<<"mcp-session-id">>, <<"mcp_does_not_matter">>}
        ],
        <<>>,
        [with_body]
    ),
    ok.

%% A DELETE (terminate session) with no credentials must likewise be
%% rejected before the session lookup.
delete_requires_auth(Config) ->
    Port = ?config(port, Config),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true,
        auth => #{
            provider => barrel_mcp_auth_bearer,
            provider_opts => #{secret => <<"top-secret">>}
        }
    }),
    {ok, 401, _, _} = hackney:request(
        delete,
        url(Port),
        [{<<"mcp-session-id">>, <<"mcp_does_not_matter">>}],
        <<>>,
        [with_body]
    ),
    ok.

post_init(Port, ExtraHeaders) ->
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>}
        | ExtraHeaders
    ],
    {ok, S, H, B} = hackney:request(
        post,
        url(Port),
        Headers,
        init_body(),
        [with_body]
    ),
    {S, H, B}.
