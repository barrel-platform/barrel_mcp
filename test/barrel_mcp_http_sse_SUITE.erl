%%%-------------------------------------------------------------------
%%% @doc The deprecated 2024-11-05 HTTP+SSE transport, served alongside
%%% Streamable HTTP on the same listener.
%%%
%%% Two routes: a GET that opens the stream and names where to post, and
%%% the POST endpoint it names. Answers come back on the stream.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_sse_SUITE).

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
    endpoint_event_is_first/1,
    initialize_answers_on_the_stream/1,
    tool_call_answers_on_the_stream/1,
    unknown_session_is_refused/1,
    session_required_on_post/1,
    routes_are_off_unless_configured/1,
    origin_is_validated/1,
    stream_close_ends_the_session/1,
    client_falls_back_to_the_sse_pair/1
]).

-export([echo_tool/1]).

-define(PORT, 23100).
-define(SSE, "/sse").
-define(MSG, "/messages").

all() ->
    [
        endpoint_event_is_first,
        initialize_answers_on_the_stream,
        tool_call_answers_on_the_stream,
        unknown_session_is_refused,
        session_required_on_post,
        routes_are_off_unless_configured,
        origin_is_validated,
        stream_close_ends_the_session,
        client_falls_back_to_the_sse_pair
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echoes its input">>
    }),
    Config.

end_per_suite(_Config) ->
    barrel_mcp_registry:unreg(tool, <<"echo">>),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(routes_are_off_unless_configured, Config) ->
    Port = ?PORT + 50,
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, session_enabled => true}),
    [{port, Port} | Config];
init_per_testcase(TC, Config) ->
    Port = ?PORT + case_index(TC),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true,
        sse_path => <<?SSE>>,
        sse_message_path => <<?MSG>>
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

%%====================================================================
%% Cases
%%====================================================================

%% "When a client connects, the server MUST send an `endpoint' event
%% containing a URI for the client to use for sending messages"
%% (2024-11-05/basic/transports.mdx:67).
endpoint_event_is_first(Config) ->
    {Stream, Endpoint} = open_stream(Config),
    ?assertMatch(<<?MSG "?sessionId=mcp_", _/binary>>, Endpoint),
    close(Stream).

initialize_answers_on_the_stream(Config) ->
    {Stream, Endpoint} = open_stream(Config),
    ?assertEqual(202, post(Config, Endpoint, init_body())),
    {Response, Stream1} = next_message(Stream),
    ?assertEqual(1, maps:get(<<"id">>, Response)),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(<<"2024-11-05">>, maps:get(<<"protocolVersion">>, Result)),
    %% Tasks arrived at 2025-11-25, so this revision is not told it has
    %% them.
    ?assertNot(maps:is_key(<<"tasks">>, maps:get(<<"capabilities">>, Result))),
    close(Stream1).

tool_call_answers_on_the_stream(Config) ->
    {Stream, Endpoint} = open_stream(Config),
    ?assertEqual(202, post(Config, Endpoint, init_body())),
    {_Init, Stream1} = next_message(Stream),
    Call = request(2, <<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{<<"input">> => <<"hi">>}
    }),
    ?assertEqual(202, post(Config, Endpoint, Call)),
    {Response, Stream2} = next_message(Stream1),
    ?assertEqual(2, maps:get(<<"id">>, Response)),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Response)),
    ?assertEqual(<<"Echo: hi">>, maps:get(<<"text">>, Block)),
    close(Stream2).

%% The session id in the endpoint URL is the capability for that
%% connection, so a made-up one is refused.
unknown_session_is_refused(Config) ->
    ?assertEqual(404, post(Config, <<?MSG "?sessionId=mcp_deadbeef">>, init_body())).

session_required_on_post(Config) ->
    ?assertEqual(400, post(Config, <<?MSG>>, init_body())).

%% Unconfigured, the path is not a route: the GET falls through to the
%% Streamable transport, which wants a session header.
routes_are_off_unless_configured(Config) ->
    Port = ?config(port, Config),
    {ok, Status, _, _} = hackney:request(get, url(Port, <<?SSE>>), [], <<>>, [with_body]),
    ?assertNotEqual(200, Status).

origin_is_validated(Config) ->
    Port = ?config(port, Config),
    {ok, Status, _, _} = hackney:request(
        get,
        url(Port, <<?SSE>>),
        [{<<"origin">>, <<"http://evil.example">>}],
        <<>>,
        [with_body]
    ),
    ?assertEqual(403, Status).

%% The stream is the session: dropping it takes the session with it, so
%% the endpoint it handed out stops working.
stream_close_ends_the_session(Config) ->
    {Stream, Endpoint} = open_stream(Config),
    close(Stream),
    wait_until(fun() -> post(Config, Endpoint, init_body()) =:= 404 end, 5000),
    ?assertEqual(404, post(Config, Endpoint, init_body())).

%% A server that hosts only the 2024-11-05 pair answers a Streamable
%% POST with a 404, which is what tells the client to go looking for the
%% stream instead (streamable-http.mdx:274).
client_falls_back_to_the_sse_pair(Config) ->
    Port = ?config(port, Config),
    %% Our own listener serves Streamable on every path, so the refusal
    %% has to come from somewhere that does not: this stands in for a
    %% server that hosts only the old pair.
    NotThere = Port + 900,
    {ok, _} = barrel_mcp_test_http:start(no_streamable, NotThere, fun(_Req) ->
        {404, #{<<"content-type">> => <<"text/plain">>}, <<"Not Found">>}
    end),
    {ok, Client} = barrel_mcp_client:start(#{
        transport => {http, url(NotThere, <<"/mcp">>)},
        protocol_version => <<"2024-11-05">>,
        legacy_sse_url => url(Port, <<?SSE>>),
        init_timeout => 15000
    }),
    try
        wait_until(fun() -> is_ready(Client) end, 15000),
        ?assertEqual({ok, <<"2024-11-05">>}, barrel_mcp_client:protocol_version(Client)),
        {ok, Result} = barrel_mcp_client:call_tool(Client, <<"echo">>, #{
            <<"input">> => <<"legacy">>
        }),
        [Block] = maps:get(<<"content">>, Result),
        ?assertEqual(<<"Echo: legacy">>, maps:get(<<"text">>, Block))
    after
        try
            barrel_mcp_client:close(Client)
        catch
            _:_ -> ok
        end,
        barrel_mcp_test_http:stop(no_streamable)
    end.

is_ready(Pid) ->
    try barrel_mcp_client:protocol_version(Pid) of
        {ok, V} when is_binary(V) -> true;
        _ -> false
    catch
        _:_ -> false
    end.

%%====================================================================
%% Helpers
%%====================================================================

url(Port, Path) ->
    iolist_to_binary([io_lib:format("http://127.0.0.1:~B", [Port]), Path]).

%% A socket the case owns rather than an HTTP client: this stream never
%% completes, which is the shape a pooling client handles worst.
%%
%% The body is chunked, so rather than model that framing the reader
%% just collects `data:' lines in order and counts how many it has
%% handed back. A chunk-size line never looks like one.
open_stream(Config) ->
    Port = ?config(port, Config),
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}, {packet, raw}], 5000
    ),
    ok = gen_tcp:send(Sock, [
        <<"GET " ?SSE " HTTP/1.1\r\n">>,
        <<"Host: 127.0.0.1\r\n">>,
        <<"Accept: text/event-stream\r\n\r\n">>
    ]),
    {Endpoint, Stream} = next_data({Sock, <<>>, 0}),
    {Stream, Endpoint}.

next_message(Stream) ->
    {Data, Stream1} = next_data(Stream),
    {json:decode(Data), Stream1}.

next_data({Sock, Buf, Consumed}) ->
    case lists:nthtail(min(Consumed, length(data_lines(Buf))), data_lines(Buf)) of
        [Data | _] ->
            {Data, {Sock, Buf, Consumed + 1}};
        [] ->
            {ok, More} = gen_tcp:recv(Sock, 0, 10000),
            next_data({Sock, <<Buf/binary, More/binary>>, Consumed})
    end.

data_lines(Buf) ->
    [
        string:trim(V)
     || Line <- binary:split(Buf, <<"\n">>, [global]),
        <<"data: ", V/binary>> <- [Line]
    ].

close({Sock, _Buf, _Consumed}) ->
    gen_tcp:close(Sock),
    ok.

post(Config, Endpoint, Body) ->
    Port = ?config(port, Config),
    {ok, Status, _, _} = hackney:request(
        post,
        url(Port, Endpoint),
        [{<<"content-type">>, <<"application/json">>}],
        Body,
        [with_body]
    ),
    Status.

init_body() ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2024-11-05">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{
                <<"name">> => <<"sse-suite">>,
                <<"version">> => <<"1.0">>
            }
        }
    }).

request(Id, Method, Params) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }).

case_index(TC) ->
    case_index(TC, all(), 0).

case_index(TC, [TC | _], N) -> N;
case_index(TC, [_ | Rest], N) -> case_index(TC, Rest, N + 1);
case_index(_TC, [], N) -> N.

wait_until(_Fun, Remaining) when Remaining =< 0 ->
    ok;
wait_until(Fun, Remaining) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_until(Fun, Remaining - 100)
    end.
