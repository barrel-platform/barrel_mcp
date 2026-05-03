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
         ask_llm_tool/1, ask_user_tool/1, list_roots_tool/1,
         progress_tool/2,
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
    ok = barrel_mcp_registry:reg(tool, <<"ask_llm">>, ?MODULE,
                                  ask_llm_tool, #{
        description => <<"Ask the connected client to sample a message">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    ok = barrel_mcp_registry:reg(tool, <<"ask_user">>, ?MODULE,
                                  ask_user_tool, #{
        description => <<"Ask the connected client to elicit user input">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    ok = barrel_mcp_registry:reg(tool, <<"list_roots">>, ?MODULE,
                                  list_roots_tool, #{
        description => <<"Ask the connected client for its roots">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    ok = barrel_mcp_registry:reg(tool, <<"progress_echo">>, ?MODULE,
                                  progress_tool, #{
        description => <<"Emit a few progress events then return">>,
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
    catch barrel_mcp_registry:unreg(tool, <<"ask_llm">>),
    catch barrel_mcp_registry:unreg(tool, <<"ask_user">>),
    catch barrel_mcp_registry:unreg(tool, <<"list_roots">>),
    catch barrel_mcp_registry:unreg(tool, <<"progress_echo">>),
    catch barrel_mcp_registry:unreg(resource, <<"greeting">>),
    catch barrel_mcp_registry:unreg(prompt, <<"hello_prompt">>),
    ok.

echo_tool(#{<<"text">> := T}) -> T.

trigger_update_tool(_) ->
    ok = barrel_mcp:notify_resource_updated(<<"mem://greeting">>),
    <<"triggered">>.

%% Ask the only sampling-capable session for a message and return
%% the text. Mirrors examples/sampling_host's ask_sampler/1.
ask_llm_tool(_) ->
    [SessionId | _] = barrel_mcp:list_sessions_with_sampling(),
    Params = #{
        <<"messages">> =>
            [#{<<"role">> => <<"user">>,
               <<"content">> => #{<<"type">> => <<"text">>,
                                   <<"text">> => <<"hi">>}}],
        <<"maxTokens">> => 32
    },
    {ok, Result, _Usage} =
        barrel_mcp:sampling_create_message(SessionId, Params,
                                           #{timeout_ms => 5000}),
    maps:get(<<"text">>, maps:get(<<"content">>, Result)).

%% Ask the only elicitation-capable session for a structured
%% answer and return what the user picked. Form-mode payload
%% per the spec.
ask_user_tool(_) ->
    [SessionId | _] = barrel_mcp:list_sessions_with_elicitation(),
    Params = #{
        <<"mode">> => <<"form">>,
        <<"message">> => <<"Pick a colour">>,
        <<"requestedSchema">> =>
            #{<<"type">> => <<"object">>,
              <<"properties">> =>
                  #{<<"colour">> =>
                        #{<<"type">> => <<"string">>}}}
    },
    {ok, Result} = barrel_mcp:elicit_create(SessionId, Params,
                                             #{timeout_ms => 5000}),
    %% The Python callback returns action=accept,
    %% content={"colour": "blue"}. Surface the colour as text.
    Content = maps:get(<<"content">>, Result, #{}),
    maps:get(<<"colour">>, Content, <<"unset">>).

%% Ask the only roots-capable session for its roots and return the
%% first root's name (so we have a deterministic string to assert on).
list_roots_tool(_) ->
    [SessionId | _] = barrel_mcp:list_sessions_with_roots(),
    {ok, Roots} = barrel_mcp:roots_list(SessionId,
                                         #{timeout_ms => 5000}),
    [#{<<"name">> := N} | _] = Roots,
    N.

%% Arity-2 handler that emits three progress events through Ctx
%% before returning. Used to verify notifications/progress
%% interop with the reference SDK's progress_callback.
progress_tool(_Args, Ctx) ->
    Emit = maps:get(emit_progress, Ctx),
    %% Brief sleeps between emits so the SSE writer flushes each
    %% notification ahead of the synchronous tool response, which
    %% otherwise wins the race in the reference Python client.
    Emit(1, 3, undefined), timer:sleep(20),
    Emit(2, 3, undefined), timer:sleep(20),
    Emit(3, 3, undefined), timer:sleep(20),
    <<"progressed">>.

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
