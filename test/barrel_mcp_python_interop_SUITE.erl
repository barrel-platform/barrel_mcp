%%%-------------------------------------------------------------------
%%% @doc Python interop suite — exercises the wire format between
%%% barrel_mcp and the official Python MCP SDK in both directions.
%%%
%%% Cases skip cleanly when the `INTEROP_PYTHON' env var is unset or
%%% the named interpreter does not exist; the default `rebar3 ct'
%%% loop therefore works without Python installed.
%%%
%%% Run via:
%%%
%%%   make interop-setup        % once
%%%   make interop-test
%%%
%%% which sets `INTEROP_PYTHON' to the venv interpreter and shells
%%% out to `rebar3 ct --suite=test/barrel_mcp_python_interop_SUITE'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_python_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([python_client_against_erlang_server/1,
         erlang_client_against_python_server/1]).

%% Tool / resource / prompt handlers exported for the registry.
-export([echo_tool/1, slow_tool/2, trigger_update_tool/1,
         greeting_resource/1, hello_prompt/1]).

-define(PORT, 22451).

all() ->
    [python_client_against_erlang_server,
     erlang_client_against_python_server].

init_per_suite(Config) ->
    case python_or_skip() of
        {skip, _} = Skip -> Skip;
        Python ->
            {ok, _} = application:ensure_all_started(barrel_mcp),
            {ok, _} = application:ensure_all_started(hackney),
            ok = barrel_mcp_registry:wait_for_ready(),
            [{python, Python} | Config]
    end.

end_per_suite(_Config) ->
    catch barrel_mcp:stop_http_stream(),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(_TC, Config) -> Config.
end_per_testcase(_TC, _Config) -> ok.

%%====================================================================
%% Direction A — Python client → Erlang server
%%====================================================================

python_client_against_erlang_server(Config) ->
    Python = ?config(python, Config),
    ok = ensure_fixture(),
    {ok, _} = barrel_mcp:start_http_stream(#{port => ?PORT,
                                              session_enabled => true}),
    Url = io_lib:format("http://127.0.0.1:~B/mcp", [?PORT]),
    Script = filename:join(["test", "interop", "client.py"]),
    Cwd = root_dir(),
    {Status, Output} = run_python(Python, [Script, lists:flatten(Url)], Cwd),
    case Status of
        0 ->
            true = string:find(Output, "OK") =/= nomatch,
            ok;
        _ ->
            ct:fail({python_client_failed, Status, Output})
    end,
    catch barrel_mcp:stop_http_stream(),
    cleanup_fixture(),
    ok.

%%====================================================================
%% Direction B — Erlang client → Python server
%%====================================================================

erlang_client_against_python_server(Config) ->
    Python = ?config(python, Config),
    Script = filename:join(["test", "interop", "server.py"]),
    Cwd = root_dir(),
    AbsScript = filename:join(Cwd, Script),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport => {stdio, #{command => Python,
                                args => [AbsScript]}}
    }),
    ok = wait_ready(Pid, 50),
    {ok, Tools} = barrel_mcp_client:list_tools(Pid),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"echo">>, Names)),
    {ok, Result} = barrel_mcp_client:call_tool(
                     Pid, <<"echo">>, #{<<"text">> => <<"hello">>},
                     #{timeout => 10000}),
    [#{<<"text">> := <<"hello">>} | _] = maps:get(<<"content">>, Result),
    barrel_mcp_client:close(Pid),
    ok.

%%====================================================================
%% Fixture
%%====================================================================

ensure_fixture() ->
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo a string">>,
        input_schema => #{<<"type">> => <<"object">>,
                           <<"required">> => [<<"text">>],
                           <<"properties">> =>
                               #{<<"text">> => #{<<"type">> => <<"string">>}}}
    }),
    ok = barrel_mcp_registry:reg(tool, <<"slow_echo">>, ?MODULE,
                                  slow_tool, #{
        description => <<"Long-running echo (returns a taskId)">>,
        long_running => true,
        input_schema => #{<<"type">> => <<"object">>,
                           <<"properties">> =>
                               #{<<"text">> => #{<<"type">> => <<"string">>}}}
    }),
    ok = barrel_mcp_registry:reg(tool, <<"trigger_update">>, ?MODULE,
                                  trigger_update_tool, #{
        description => <<"Push notifications/resources/updated for the greeting URI">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    ok = barrel_mcp_registry:reg(resource, <<"greeting">>, ?MODULE,
                                  greeting_resource, #{
        name => <<"Greeting">>,
        uri => <<"mem://greeting">>,
        description => <<"Sample greeting resource">>,
        mime_type => <<"text/plain">>
    }),
    ok = barrel_mcp_registry:reg(prompt, <<"hello_prompt">>, ?MODULE,
                                  hello_prompt, #{
        description => <<"Greet a user">>,
        arguments => [#{name => <<"who">>, required => false}]
    }),
    ok.

cleanup_fixture() ->
    catch barrel_mcp_registry:unreg(tool, <<"echo">>),
    catch barrel_mcp_registry:unreg(tool, <<"slow_echo">>),
    catch barrel_mcp_registry:unreg(tool, <<"trigger_update">>),
    catch barrel_mcp_registry:unreg(resource, <<"greeting">>),
    catch barrel_mcp_registry:unreg(prompt, <<"hello_prompt">>),
    ok.

echo_tool(#{<<"text">> := T}) -> T.

trigger_update_tool(_) ->
    ok = barrel_mcp:notify_resource_updated(<<"mem://greeting">>),
    <<"triggered">>.

%% Long-running arity-2 handler. Sleeps briefly then echoes back so
%% the Python client can see the task transition through `working' →
%% `completed'.
slow_tool(Args, _Ctx) ->
    timer:sleep(100),
    maps:get(<<"text">>, Args, <<"slow">>).

greeting_resource(_) -> <<"hello, world">>.

hello_prompt(Args) ->
    Who = maps:get(<<"who">>, Args, <<"world">>),
    #{<<"description">> => <<"Greet">>,
      <<"messages">> => [#{<<"role">> => <<"user">>,
                            <<"content">> => #{<<"type">> => <<"text">>,
                                                <<"text">> =>
                                                    iolist_to_binary(
                                                      [<<"hello, ">>, Who])}}]}.

%%====================================================================
%% Helpers
%%====================================================================

python_or_skip() ->
    case os:getenv("INTEROP_PYTHON") of
        false ->
            {skip, "INTEROP_PYTHON not set; run `make interop-test`"};
        Python ->
            case filelib:is_regular(Python) of
                true -> Python;
                false ->
                    {skip, lists:flatten(
                             io_lib:format("INTEROP_PYTHON=~s does not exist",
                                           [Python]))}
            end
    end.

root_dir() ->
    %% CT runs from a deep _build directory; resolve to the project
    %% root so `test/interop/...' paths work.
    {ok, Cwd} = file:get_cwd(),
    find_root(Cwd).

find_root(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true -> Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                Dir -> Dir;  %% reached fs root, give up
                _ -> find_root(Parent)
            end
    end.

run_python(Python, Args, Cwd) ->
    Port = open_port({spawn_executable, Python},
                     [{args, Args},
                      {cd, Cwd},
                      exit_status,
                      stderr_to_stdout,
                      use_stdio,
                      binary,
                      {line, 4096}]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, {_, Line}}} ->
            collect(Port, [Line, $\n | Acc]);
        {Port, {data, Line}} ->
            collect(Port, [Line, $\n | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, lists:flatten(lists:reverse(Acc))}
    after 60000 ->
        catch port_close(Port),
        {timeout, lists:flatten(lists:reverse(Acc))}
    end.

wait_ready(_Pid, 0) -> {error, not_ready};
wait_ready(Pid, N) ->
    case catch barrel_mcp_client:server_capabilities(Pid) of
        {ok, _} -> ok;
        _ ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.
