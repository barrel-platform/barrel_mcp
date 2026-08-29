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
    {setup, fun setup/0, fun cleanup/1, [
        {"Start and stop server", fun test_start_stop/0},
        {"POST request returns JSON response", fun test_post_json/0},
        {"POST without Accept header defaults to JSON", fun test_post_default_accept/0},
        {"OPTIONS returns CORS headers", fun test_options_cors/0},
        {"Auth required when configured", fun test_auth_required/0},
        {"Auth passes with valid key", fun test_auth_valid/0},
        {"Batch accepted on a revision that has it", fun test_batch_accepted/0},
        {"Batch refused once the revision removed it", fun test_batch_refused/0},
        {"Batch of responses is accepted silently", fun test_batch_responses/0}
    ]}.

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
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
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
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => 19091,
        session_enabled => false
    }),

    Request = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>
    }),

    {ok, Status, Headers, Body} = hackney:request(
        post,
        <<"http://localhost:19091/mcp">>,
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        Request,
        []
    ),

    ?assertEqual(200, Status),

    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertEqual(<<"application/json">>, ContentType),

    Response = json:decode(Body),
    ?assertEqual(<<"2.0">>, maps:get(<<"jsonrpc">>, Response)),
    ?assertEqual(1, maps:get(<<"id">>, Response)),

    barrel_mcp:stop_http_stream().

test_post_default_accept() ->
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => 19092,
        session_enabled => false
    }),

    Request = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"ping">>
    }),

    {ok, Status, Headers, _Body} = hackney:request(
        post,
        <<"http://localhost:19092/mcp">>,
        [{<<"content-type">>, <<"application/json">>}],
        Request,
        []
    ),

    ?assertEqual(200, Status),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertEqual(<<"application/json">>, ContentType),

    barrel_mcp:stop_http_stream().

test_options_cors() ->
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => 19093,
        session_enabled => false
    }),

    %% No Origin header: server omits Access-Control-Allow-Origin.
    {ok, Status1, H1, _} = hackney:request(
        options,
        <<"http://localhost:19093/mcp">>,
        [],
        <<>>,
        []
    ),
    ?assertEqual(204, Status1),
    ?assertEqual(
        undefined,
        proplists:get_value(<<"access-control-allow-origin">>, H1)
    ),

    %% With a loopback Origin: server echoes it back.
    {ok, Status2, H2, _} = hackney:request(
        options,
        <<"http://localhost:19093/mcp">>,
        [{<<"origin">>, <<"http://localhost:5173">>}],
        <<>>,
        []
    ),
    ?assertEqual(204, Status2),
    ?assertEqual(
        <<"http://localhost:5173">>,
        proplists:get_value(<<"access-control-allow-origin">>, H2)
    ),
    ?assertMatch(
        <<"POST", _/binary>>,
        proplists:get_value(<<"access-control-allow-methods">>, H2)
    ),

    barrel_mcp:stop_http_stream().

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

    {ok, Status, _, _Body} = hackney:request(
        post,
        <<"http://localhost:19097/mcp">>,
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ],
        Request,
        []
    ),

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

    {ok, Status, _, _Body} = hackney:request(
        post,
        <<"http://localhost:19098/mcp">>,
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"x-api-key">>, <<"test-key">>}
        ],
        Request,
        []
    ),

    ?assertEqual(200, Status),

    barrel_mcp:stop_http_stream().

%%====================================================================
%% Batches over the wire
%%
%% 2025-03-26 requires receiving them; 2025-06-18 removed them. The
%% header names the revision, so one listener answers both ways.
%%====================================================================

%% Each case owns its listener, as the rest of this suite does.
with_batch_server(Port, Fun) ->
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, session_enabled => false}),
    try
        Fun()
    after
        barrel_mcp:stop_http_stream()
    end.

batch_post(Port, Revision, Body) ->
    hackney:request(
        post,
        iolist_to_binary(io_lib:format("http://localhost:~B/mcp", [Port])),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>},
            {<<"mcp-protocol-version">>, Revision}
        ],
        iolist_to_binary(json:encode(Body)),
        []
    ).

ping(Id) ->
    #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"method">> => <<"ping">>}.

test_batch_accepted() ->
    with_batch_server(19096, fun() ->
        {ok, 200, _, Body} = batch_post(19096, <<"2025-03-26">>, [ping(1), ping(2)]),
        Decoded = json:decode(Body),
        ?assert(is_list(Decoded)),
        ?assertEqual([1, 2], [maps:get(<<"id">>, R) || R <- Decoded])
    end).

test_batch_refused() ->
    with_batch_server(19097, fun() ->
        {ok, 400, _, Body} = batch_post(19097, <<"2025-11-25">>, [ping(1)]),
        Error = maps:get(<<"error">>, json:decode(Body)),
        ?assertEqual(-32600, maps:get(<<"code">>, Error))
    end).

%% Nothing to answer, so the acceptance is the status alone.
test_batch_responses() ->
    Responses = [
        #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 1, <<"result">> => #{}},
        #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => 2, <<"result">> => #{}}
    ],
    with_batch_server(19098, fun() ->
        {ok, Status, _, Body} = batch_post(19098, <<"2025-03-26">>, Responses),
        ?assertEqual(202, Status),
        ?assertEqual(<<>>, Body)
    end).
