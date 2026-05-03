%%%-------------------------------------------------------------------
%%% @doc Minimal MCP host using `barrel_mcp_client'.
%%%
%%% Boots a `barrel_mcp' Streamable HTTP server in-process, registers
%%% an `echo' tool, connects a client, calls the tool, and prints the
%%% result. Run with `rebar3 shell -eval 'echo_client:run().'' or
%%% drive it from a common_test suite (see `test/echo_client_SUITE').
%%% @end
%%%-------------------------------------------------------------------
-module(echo_client).

-export([run/0, run/1, echo/1]).

-define(DEFAULT_PORT, 18080).

%% @doc Run the example end-to-end. Returns the echoed text.
-spec run() -> binary().
run() ->
    run(?DEFAULT_PORT).

-spec run(pos_integer()) -> binary().
run(Port) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = ensure_echo_tool(),
    {ok, _} = ensure_server(Port),
    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])),
    {ok, Client} = barrel_mcp_client:start(#{
        transport => {http, Url},
        handler => {barrel_mcp_client_handler_default, []}
    }),
    ok = wait_ready(Client, 30),
    {ok, Tools} = barrel_mcp_client:list_tools_all(Client),
    io:format("tools: ~p~n", [[maps:get(<<"name">>, T) || T <- Tools]]),
    {ok, Result} = barrel_mcp_client:call_tool(
        Client, <<"echo">>, #{<<"text">> => <<"hello, mcp">>}),
    [#{<<"type">> := <<"text">>, <<"text">> := Echoed}] =
        maps:get(<<"content">>, Result),
    io:format("echo: ~s~n", [Echoed]),
    barrel_mcp_client:close(Client),
    Echoed.

%% @doc Tool handler. Returns the supplied text unchanged.
-spec echo(map()) -> binary().
echo(#{<<"text">> := Text}) ->
    Text.

%%====================================================================
%% Internal
%%====================================================================

ensure_echo_tool() ->
    barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo, #{
        description => <<"Echoes the given text back as-is.">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"text">>],
            <<"properties">> => #{
                <<"text">> => #{<<"type">> => <<"string">>}
            }
        }
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
