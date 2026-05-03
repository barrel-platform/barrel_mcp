%%%-------------------------------------------------------------------
%%% @doc Multi-server agent host example.
%%%
%%% Demonstrates how `barrel_mcp_agent' aggregates tools across two
%%% federated MCP clients into one namespaced catalog and routes a
%%% call back to the right server. See the README for the full
%%% pattern.
%%%
%%% In production, the two `start_client/2' calls would point at
%%% distinct external MCP servers (each typed by `ServerId'). For a
%%% self-contained example we boot one in-process Streamable HTTP
%%% server and connect two clients to it under different `ServerId's;
%%% the aggregator surfaces every tool twice (under each prefix) and
%%% routing dispatches deterministically by prefix.
%%%
%%% Run with `rebar3 shell -eval 'agent_host:run().'' or via the
%%% common_test suite under `test/agent_host_SUITE'.
%%% @end
%%%-------------------------------------------------------------------
-module(agent_host).

-export([run/0, run/1]).
-export([echo_tool/1]).

-define(DEFAULT_PORT, 18091).

%% @doc End-to-end run. Returns `{Catalog, Routed}' where `Catalog'
%% is the aggregated tools/list (namespaced names) and `Routed' is
%% the result of routing a `call_tool' through the aggregator to a
%% specific server.
-spec run() -> {[map()], map()}.
run() -> run(?DEFAULT_PORT).

-spec run(pos_integer()) -> {[map()], map()}.
run(Port) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = ensure_tool(),
    {ok, _} = ensure_server(Port),
    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp",
                                         [Port])),
    Spec = #{transport => {http, Url}},
    {ok, Alpha} = barrel_mcp:start_client(<<"alpha">>, Spec),
    {ok, Beta}  = barrel_mcp:start_client(<<"beta">>, Spec),
    ok = wait_ready(Alpha, 30),
    ok = wait_ready(Beta, 30),

    Catalog = barrel_mcp_agent:list_tools(),

    {ok, Routed} = barrel_mcp_agent:call_tool(
                      <<"beta:echo">>,
                      #{<<"text">> => <<"hello from beta">>}),

    ok = barrel_mcp:stop_client(<<"alpha">>),
    ok = barrel_mcp:stop_client(<<"beta">>),
    {Catalog, Routed}.

%%====================================================================
%% Tool fixture
%%====================================================================

echo_tool(#{<<"text">> := T}) -> T.

ensure_tool() ->
    barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo the input text back unchanged">>,
        input_schema => #{<<"type">> => <<"object">>,
                           <<"required">> => [<<"text">>],
                           <<"properties">> =>
                               #{<<"text">> =>
                                     #{<<"type">> => <<"string">>}}}
    }).

ensure_server(Port) ->
    case barrel_mcp_http_stream:start(#{port => Port,
                                        session_enabled => true}) of
        {ok, _} = Ok -> Ok;
        {error, {already_started, Pid}} -> {ok, Pid}
    end.

wait_ready(_Pid, 0) -> {error, not_ready};
wait_ready(Pid, N) ->
    case catch barrel_mcp_client:server_capabilities(Pid) of
        {ok, _} -> ok;
        _ ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.
