%%%-------------------------------------------------------------------
%%% @doc Tests for barrel_mcp_http_stream (Streamable HTTP transport).
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_stream_tests).

-include_lib("eunit/include/eunit.hrl").

-export([test_tool/1]).

%%====================================================================
%% Test Fixtures
%%====================================================================

http_stream_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        {"Start and stop server", fun test_start_stop/0},
        {"POST request returns JSON response", fun test_post_json/0},
        {"POST without Accept header defaults to JSON", fun test_post_default_accept/0},
        {"OPTIONS returns CORS headers", fun test_options_cors/0},
        {"Session created on first request", fun test_session_created/0},
        {"Session ID in response header", fun test_session_header/0},
        {"DELETE terminates session", fun test_delete_session/0},
        {"Auth required when configured", fun test_auth_required/0},
        {"Auth passes with valid key", fun test_auth_valid/0}
     ]
    }.

setup() ->
    application:ensure_all_started(hackney),
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    %% Register a test tool
    barrel_mcp:reg_tool(<<"test_tool">>, ?MODULE, test_tool, #{
        description => <<"Test tool">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"value">> => #{<<"type">> => <<"string">>}
            }
        }
    }),
    ok.

cleanup(_) ->
    catch barrel_mcp:stop_http_stream(),
    barrel_mcp:unreg_tool(<<"test_tool">>),
    ok.

%%====================================================================
%% Test Handler
%%====================================================================

test_tool(Args) ->
    Value = maps:get(<<"value">>, Args, <<"default">>),
    <<"echo: ", Value/binary>>.

%%====================================================================
%% Tests
%%====================================================================

test_start_stop() ->
    %% Start server
    {ok, _Pid} = barrel_mcp:start_http_stream(#{port => 19090}),

    %% Verify it's running by making a request
    {ok, Status, _, _} = hackney:request(options, <<"http://localhost:19090/mcp">>, [], <<>>, []),
    ?assertEqual(204, Status),

    %% Stop server
    ok = barrel_mcp:stop_http_stream().

test_post_json() ->
    %% Sessions disabled — `ping' goes through without one.
    {ok, _} = barrel_mcp:start_http_stream(#{port => 19091,
                                             session_enabled => false}),

    Request = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>
    }),

    {ok, Status, Headers, Body} = hackney:request(post,
        <<"http://localhost:19091/mcp">>,
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>}],
        Request, []),

    ?assertEqual(200, Status),

    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertEqual(<<"application/json">>, ContentType),

    Response = json:decode(Body),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Response)),
    ?assertEqual(1, maps:get(<<"id">>, Response)),

    barrel_mcp:stop_http_stream().

test_post_default_accept() ->
    {ok, _} = barrel_mcp:start_http_stream(#{port => 19092,
                                             session_enabled => false}),

    Request = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>
    }),

    {ok, Status, Headers, _Body} = hackney:request(post,
        <<"http://localhost:19092/mcp">>,
        [{<<"content-type">>, <<"application/json">>}],
        Request, []),

    ?assertEqual(200, Status),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertEqual(<<"application/json">>, ContentType),

    barrel_mcp:stop_http_stream().

test_options_cors() ->
    {ok, _} = barrel_mcp:start_http_stream(#{port => 19093,
                                             session_enabled => false}),

    %% No Origin header: server omits Access-Control-Allow-Origin.
    {ok, Status1, H1, _} = hackney:request(options,
        <<"http://localhost:19093/mcp">>,
        [], <<>>, []),
    ?assertEqual(204, Status1),
    ?assertEqual(undefined,
                 proplists:get_value(<<"access-control-allow-origin">>, H1)),

    %% With a loopback Origin: server echoes it back.
    {ok, Status2, H2, _} = hackney:request(options,
        <<"http://localhost:19093/mcp">>,
        [{<<"origin">>, <<"http://localhost:5173">>}], <<>>, []),
    ?assertEqual(204, Status2),
    ?assertEqual(<<"http://localhost:5173">>,
                 proplists:get_value(<<"access-control-allow-origin">>, H2)),
    ?assertMatch(<<"POST", _/binary>>,
                 proplists:get_value(<<"access-control-allow-methods">>, H2)),

    barrel_mcp:stop_http_stream().

test_session_created() ->
    {ok, _} = barrel_mcp:start_http_stream(#{port => 19094, session_enabled => true}),
    {200, Headers, _} = post_initialize(<<"http://localhost:19094/mcp">>),
    SessionId = proplists:get_value(<<"mcp-session-id">>, Headers),
    ?assertMatch(<<"mcp_", _/binary>>, SessionId),
    barrel_mcp:stop_http_stream().

test_session_header() ->
    {ok, _} = barrel_mcp:start_http_stream(#{port => 19095, session_enabled => true}),
    %% First request: initialize creates a session.
    {200, Headers1, _} = post_initialize(<<"http://localhost:19095/mcp">>),
    SessionId = proplists:get_value(<<"mcp-session-id">>, Headers1),
    %% Subsequent ping with the same id reuses the session.
    Ping = json:encode(#{<<"jsonrpc">> => <<"2.0">>,
                         <<"id">> => 2,
                         <<"method">> => <<"ping">>}),
    {ok, 200, Headers2, _} = hackney:request(post,
        <<"http://localhost:19095/mcp">>,
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>},
         {<<"mcp-session-id">>, SessionId}],
        Ping, []),
    ?assertEqual(SessionId, proplists:get_value(<<"mcp-session-id">>, Headers2)),
    barrel_mcp:stop_http_stream().

test_delete_session() ->
    {ok, _} = barrel_mcp:start_http_stream(#{port => 19096, session_enabled => true}),
    {200, Headers, _} = post_initialize(<<"http://localhost:19096/mcp">>),
    SessionId = proplists:get_value(<<"mcp-session-id">>, Headers),
    {ok, Status, _, _} = hackney:request(delete,
        <<"http://localhost:19096/mcp">>,
        [{<<"mcp-session-id">>, SessionId}], <<>>, []),
    ?assertEqual(204, Status),
    barrel_mcp:stop_http_stream().

%% Helper: send an `initialize' request and return
%% `{Status, Headers, Body}'.
post_initialize(Url) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{<<"name">> => <<"test">>,
                                  <<"version">> => <<"1.0">>}
        }
    }),
    {ok, S, H, Resp} = hackney:request(post, Url,
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>}],
        Body, [with_body]),
    {S, H, Resp}.

test_auth_required() ->
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => 19097,
        session_enabled => false,
        auth => #{
            provider => barrel_mcp_auth_apikey,
            provider_opts => #{
                keys => #{<<"test-key">> => #{subject => <<"tester">>}}
            }
        }
    }),

    Request = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>
    }),

    {ok, Status, _, _Body} = hackney:request(post,
        <<"http://localhost:19097/mcp">>,
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>}],
        Request, []),

    ?assertEqual(401, Status),

    barrel_mcp:stop_http_stream().

test_auth_valid() ->
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => 19098,
        session_enabled => false,
        auth => #{
            provider => barrel_mcp_auth_apikey,
            provider_opts => #{
                keys => #{<<"test-key">> => #{subject => <<"tester">>}}
            }
        }
    }),

    Request = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>
    }),

    {ok, Status, _, _Body} = hackney:request(post,
        <<"http://localhost:19098/mcp">>,
        [{<<"content-type">>, <<"application/json">>},
         {<<"accept">>, <<"application/json, text/event-stream">>},
         {<<"x-api-key">>, <<"test-key">>}],
        Request, []),

    ?assertEqual(200, Status),

    barrel_mcp:stop_http_stream().
