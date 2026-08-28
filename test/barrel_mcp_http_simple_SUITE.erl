%%%-------------------------------------------------------------------
%%% @doc The simple HTTP transport: POST and OPTIONS, no sessions, no
%%% SSE.
%%%
%%% It shares the origin, auth and metadata handling with the Streamable
%%% transport and differs in what it will answer, so what is worth
%%% pinning here is the difference: one request, one response, and
%%% everything the other transport offers refused.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_simple_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-import(barrel_mcp_test_helpers, [header/2]).

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    answers_a_tool_call/1,
    answers_initialize/1,
    runs_an_async_tool_inline/1,
    notification_returns_204/1,
    parse_error_returns_400/1,
    options_is_preflight/1,
    get_and_delete_are_refused/1,
    mints_no_session/1,
    rejects_a_foreign_origin/1,
    non_loopback_needs_allowed_origins/1
]).
-export([echo_tool/1, slow_tool/1]).

-define(PORT, 22600).

all() ->
    [
        answers_a_tool_call,
        answers_initialize,
        runs_an_async_tool_inline,
        notification_returns_204,
        parse_error_returns_400,
        options_is_preflight,
        get_and_delete_are_refused,
        mints_no_session,
        rejects_a_foreign_origin,
        non_loopback_needs_allowed_origins
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echoes its input">>
    }),
    ok = barrel_mcp:reg_tool(<<"slow">>, ?MODULE, slow_tool, #{
        description => <<"Sleeps, then answers">>
    }),
    Config.

end_per_suite(_Config) ->
    barrel_mcp_registry:unreg(tool, <<"echo">>),
    barrel_mcp_registry:unreg(tool, <<"slow">>),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(non_loopback_needs_allowed_origins, Config) ->
    Config;
init_per_testcase(_TC, Config) ->
    {ok, _} = barrel_mcp:start_http(#{port => ?PORT}),
    Config.

end_per_testcase(non_loopback_needs_allowed_origins, _Config) ->
    ok;
end_per_testcase(_TC, _Config) ->
    _ = barrel_mcp:stop_http(),
    timer:sleep(50),
    ok.

echo_tool(Args) ->
    <<"Echo: ", (maps:get(<<"input">>, Args, <<"none">>))/binary>>.

slow_tool(_Args) ->
    timer:sleep(100),
    <<"slept">>.

%%====================================================================
%% Cases
%%====================================================================

answers_a_tool_call(_Config) ->
    Body = request(1, <<"tools/call">>, #{
        <<"name">> => <<"echo">>,
        <<"arguments">> => #{<<"input">> => <<"hi">>}
    }),
    {200, _, Response} = post(Body, []),
    ?assertEqual(1, maps:get(<<"id">>, Response)),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Response)),
    ?assertEqual(<<"Echo: hi">>, maps:get(<<"text">>, Block)).

%% No session to mint, but the handshake still has to work: this
%% transport serves the legacy era like any other.
answers_initialize(_Config) ->
    {200, _, Response} = post(init_body(), []),
    Result = maps:get(<<"result">>, Response),
    ?assertEqual(?MCP_LATEST_LEGACY_VERSION, maps:get(<<"protocolVersion">>, Result)),
    ?assert(maps:is_key(<<"serverInfo">>, Result)).

%% A tool runs asynchronously everywhere. With no stream to hold open,
%% this transport waits for it and answers once.
runs_an_async_tool_inline(_Config) ->
    Body = request(2, <<"tools/call">>, #{
        <<"name">> => <<"slow">>,
        <<"arguments">> => #{}
    }),
    {200, _, Response} = post(Body, []),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Response)),
    ?assertEqual(<<"slept">>, maps:get(<<"text">>, Block)).

notification_returns_204(_Config) ->
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => <<"notifications/initialized">>,
        <<"params">> => #{}
    }),
    {Status, _, _} = raw_post(Body, []),
    ?assertEqual(204, Status).

parse_error_returns_400(_Config) ->
    {400, _, Response} = post(<<"{not json">>, []),
    ?assertEqual(?JSONRPC_PARSE_ERROR, maps:get(<<"code">>, maps:get(<<"error">>, Response))).

options_is_preflight(_Config) ->
    {ok, Status, Headers, _} = hackney:request(options, url(), [], <<>>, [with_body]),
    ?assertEqual(204, Status),
    ?assertNotEqual(undefined, header(<<"access-control-allow-methods">>, Headers)).

%% GET and DELETE belong to the Streamable transport. Here there is
%% nothing behind them.
get_and_delete_are_refused(_Config) ->
    lists:foreach(
        fun(Method) ->
            {ok, Status, Headers, _} = hackney:request(Method, url(), [], <<>>, [with_body]),
            ?assertEqual(405, Status),
            ?assertEqual(<<"POST, OPTIONS">>, header(<<"allow">>, Headers))
        end,
        [get, delete]
    ).

mints_no_session(_Config) ->
    {200, Headers, _} = post(init_body(), []),
    ?assertEqual(undefined, header(<<"mcp-session-id">>, Headers)).

rejects_a_foreign_origin(_Config) ->
    {ok, Status, _, _} = hackney:request(
        post,
        url(),
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"origin">>, <<"https://evil.example">>}
        ],
        init_body(),
        [with_body]
    ),
    ?assertEqual(403, Status).

%% Binding off loopback without naming the origins that may reach it is
%% refused rather than defaulted open.
non_loopback_needs_allowed_origins(_Config) ->
    ?assertEqual(
        {error, allowed_origins_required},
        barrel_mcp:start_http(#{port => ?PORT + 1, ip => {0, 0, 0, 0}})
    ).

%%====================================================================
%% Helpers
%%====================================================================

url() ->
    lists:flatten(io_lib:format("http://127.0.0.1:~B/", [?PORT])).

post(Body, ExtraHeaders) ->
    {Status, Headers, Raw} = raw_post(Body, ExtraHeaders),
    {Status, Headers, json:decode(Raw)}.

raw_post(Body, ExtraHeaders) ->
    Headers = [{<<"content-type">>, <<"application/json">>} | ExtraHeaders],
    {ok, Status, RespHeaders, Raw} = hackney:request(
        post, url(), Headers, Body, [with_body]
    ),
    {Status, RespHeaders, Raw}.

request(Id, Method, Params) ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }).

init_body() ->
    request(1, <<"initialize">>, #{
        <<"protocolVersion">> => ?MCP_LATEST_LEGACY_VERSION,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{<<"name">> => <<"simple-suite">>, <<"version">> => <<"0">>}
    }).
