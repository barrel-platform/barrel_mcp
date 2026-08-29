%%%-------------------------------------------------------------------
%%% @doc The legacy HTTP+SSE `endpoint' event must name the stream's
%%% own origin: the POST it directs carries the session's credential.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_http_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A_PORT, 19298).
-define(B_PORT, 19299).
-define(TAB, client_http_tests_hits).

%%====================================================================
%% Pure URL resolution
%%====================================================================

same_origin_relative_path_test() ->
    ?assertEqual(
        {ok, <<"http://host/messages?s=1">>},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"/messages?s=1">>)
    ).

same_origin_absolute_test() ->
    ?assertEqual(
        {ok, <<"http://host/messages">>},
        barrel_mcp_client_http:same_origin_endpoint(
            <<"http://host/sse">>, <<"http://host/messages">>
        )
    ).

same_origin_default_port_http_test() ->
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"http://host:80/x">>)
    ),
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host:80/sse">>, <<"http://host/x">>)
    ).

same_origin_default_port_https_test() ->
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_http:same_origin_endpoint(
            <<"https://host/sse">>, <<"https://host:443/x">>
        )
    ).

same_origin_host_case_test() ->
    ?assertMatch(
        {ok, _},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://Host/sse">>, <<"http://host/x">>)
    ).

cross_origin_scheme_relative_test() ->
    ?assertEqual(
        {error, {cross_origin, <<"http://other/x">>}},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"//other/x">>)
    ).

cross_origin_host_test() ->
    ?assertEqual(
        {error, {cross_origin, <<"http://other/x">>}},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"http://other/x">>)
    ).

cross_origin_scheme_test() ->
    ?assertEqual(
        {error, {cross_origin, <<"https://host/x">>}},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"https://host/x">>)
    ).

cross_origin_port_test() ->
    ?assertEqual(
        {error, {cross_origin, <<"http://host:8081/x">>}},
        barrel_mcp_client_http:same_origin_endpoint(
            <<"http://host:8080/sse">>, <<"http://host:8081/x">>
        )
    ).

bad_endpoint_test() ->
    ?assertEqual(
        {error, {bad_endpoint, <<"http://[">>}},
        barrel_mcp_client_http:same_origin_endpoint(<<"http://host/sse">>, <<"http://[">>)
    ).

%%====================================================================
%% The transport against a stream naming another origin
%%====================================================================

endpoint_origin_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 30, [
            {"a cross-origin endpoint closes the transport and sends nothing",
                fun test_cross_origin_endpoint/0},
            {"a same-origin endpoint receives the queued POST", fun test_same_origin_endpoint/0}
        ]}}.

setup() ->
    {ok, _} = application:ensure_all_started(hackney),
    _ = ets:new(?TAB, [named_table, public, bag]),
    {ok, _} = barrel_mcp_test_http:start(legacy_a, ?A_PORT, fun handle_a/1),
    {ok, _} = barrel_mcp_test_http:start(legacy_b, ?B_PORT, fun handle_b/1),
    ok.

cleanup(_) ->
    [
        try
            barrel_mcp_test_http:stop(N)
        catch
            _:_ -> ok
        end
     || N <- [legacy_a, legacy_b]
    ],
    _ =
        try
            ets:delete(?TAB)
        catch
            _:_ -> ok
        end,
    ok.

url(Port, Path) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B~s", [Port, Path])).

%% Server A hosts only the 2024 pair: the Streamable probe is refused,
%% the stream names the endpoint the test installed.
handle_a(#{path := <<"/sse">>}) ->
    [{endpoint, Endpoint}] = ets:lookup(?TAB, endpoint),
    {200, #{<<"content-type">> => <<"text/event-stream">>},
        <<"event: endpoint\ndata: ", Endpoint/binary, "\n\n">>};
handle_a(#{path := Path} = Req) ->
    true = ets:insert(?TAB, {hit_a, Path, maps:get(method, Req, undefined)}),
    case Path of
        <<"/messages">> -> {202, #{}, <<>>};
        _ -> {404, #{<<"content-type">> => <<"text/plain">>}, <<"Not Found">>}
    end.

handle_b(#{path := Path}) ->
    true = ets:insert(?TAB, {hit_b, Path}),
    {202, #{}, <<>>}.

connect() ->
    barrel_mcp_client_http:connect(self(), #{
        url => url(?A_PORT, "/mcp"),
        legacy_sse_url => url(?A_PORT, "/sse"),
        open_event_stream => false
    }).

test_cross_origin_endpoint() ->
    ets:delete_all_objects(?TAB),
    Foreign = url(?B_PORT, "/messages"),
    true = ets:insert(?TAB, {endpoint, Foreign}),
    {ok, Pid} = connect(),
    ok = barrel_mcp_client_http:send(Pid, <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}">>),
    receive
        {mcp_closed, Pid, Reason} ->
            ?assertEqual({cross_origin, Foreign}, Reason)
    after 5000 ->
        error(no_close)
    end,
    timer:sleep(300),
    ?assertEqual([], ets:lookup(?TAB, hit_b)),
    barrel_mcp_client_http:close(Pid).

test_same_origin_endpoint() ->
    ets:delete_all_objects(?TAB),
    true = ets:insert(?TAB, {endpoint, <<"/messages">>}),
    {ok, Pid} = connect(),
    ok = barrel_mcp_client_http:send(Pid, <<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}">>),
    wait_until(fun() -> [] =/= ets:match_object(?TAB, {hit_a, <<"/messages">>, '_'}) end, 5000),
    barrel_mcp_client_http:close(Pid).

wait_until(Fun, Timeout) when Timeout =< 0 ->
    Fun() orelse error(timeout);
wait_until(Fun, Timeout) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Timeout - 50)
    end.
