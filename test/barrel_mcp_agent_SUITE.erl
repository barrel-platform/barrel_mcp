%%%-------------------------------------------------------------------
%%% @doc Integration suite for `barrel_mcp_agent'.
%%%
%%% Stands up a real Streamable HTTP server, points two clients at it
%%% under different `ServerId's, and verifies that the aggregator
%%% prefixes tool names correctly and routes a namespaced
%%% `call_tool/2' back to the right client.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_agent_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([aggregates_and_routes/1]).

%% Tool handler exported for the registry.
-export([echo_tool/1]).

-define(PORT, 22341).

all() -> [aggregates_and_routes].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo">>,
        input_schema => #{<<"type">> => <<"object">>,
                           <<"required">> => [<<"text">>]}
    }),
    {ok, _} = barrel_mcp:start_http_stream(#{port => ?PORT,
                                             session_enabled => true}),
    Config.

end_per_suite(_Config) ->
    catch barrel_mcp:stop_http_stream(),
    catch barrel_mcp_registry:unreg(tool, <<"echo">>),
    application:stop(barrel_mcp),
    ok.

echo_tool(#{<<"text">> := T}) -> T.

aggregates_and_routes(_Config) ->
    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [?PORT])),
    Spec = #{transport => {http, Url}},
    {ok, Alpha} = barrel_mcp:start_client(<<"alpha">>, Spec),
    {ok, Beta}  = barrel_mcp:start_client(<<"beta">>, Spec),
    ok = wait_ready(Alpha, 30),
    ok = wait_ready(Beta, 30),

    %% Both clients see the same registry, so the aggregator should
    %% surface the `echo' tool twice — once per ServerId.
    Tools = barrel_mcp_agent:list_tools(),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"alpha:echo">>, Names)),
    ?assert(lists:member(<<"beta:echo">>, Names)),

    %% Routing dispatches to the correct client.
    {ok, R1} = barrel_mcp_agent:call_tool(<<"alpha:echo">>,
                                           #{<<"text">> => <<"hi-alpha">>}),
    [#{<<"text">> := <<"hi-alpha">>}] = maps:get(<<"content">>, R1),
    {ok, R2} = barrel_mcp_agent:call_tool(<<"beta:echo">>,
                                           #{<<"text">> => <<"hi-beta">>}),
    [#{<<"text">> := <<"hi-beta">>}] = maps:get(<<"content">>, R2),

    %% Anthropic conversion: name preserves the namespace.
    Anth = barrel_mcp_agent:to_anthropic(),
    ?assert(lists:any(fun(T) ->
                              maps:get(<<"name">>, T) =:= <<"alpha:echo">>
                      end, Anth)),
    %% OpenAI envelope wraps the function.
    OAI = barrel_mcp_agent:to_openai(),
    ?assert(lists:any(fun(T) ->
                              <<"function">> =:= maps:get(<<"type">>, T)
                                  andalso
                              <<"alpha:echo">> =:=
                                  maps:get(<<"name">>,
                                           maps:get(<<"function">>, T))
                      end, OAI)),

    ok = barrel_mcp:stop_client(<<"alpha">>),
    ok = barrel_mcp:stop_client(<<"beta">>),
    ok.

wait_ready(_Pid, 0) -> {error, not_ready};
wait_ready(Pid, N) ->
    case catch barrel_mcp_client:server_capabilities(Pid) of
        {ok, _} -> ok;
        _ ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.
