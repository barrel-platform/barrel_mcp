%%%-------------------------------------------------------------------
%%% @doc The official MCP conformance runner, driven against our
%%% Streamable server, and the official reference server driven by our
%%% client.
%%%
%%% Nothing here asserts a wire shape of its own. The fixture, in
%%% `barrel_mcp_conformance_server', is what the runner's scenarios say
%%% a server must expose, and the runner's own per-check messages
%%% are the diagnostics. A failing check is a defect to fix, so the
%%% runner is invoked bare, with no expected-failures file.
%%%
%%% Skips unless `INTEROP_CONFORMANCE' names the runner's entry point
%%% and `INTEROP_SERVER_EVERYTHING' the reference server's;
%%% `make conformance' sets both.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_conformance_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-import(barrel_mcp_test_helpers, [wait_ready/2]).

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    conformance_2026_07_28/1,
    conformance_2025_11_25/1,
    conformance_2025_06_18/1,
    conformance_2025_03_26/1,
    requirements_2026_07_28/1,
    requirements_2025_11_25/1,
    client_requirements_2026_07_28/1,
    client_requirements_2025_11_25/1,
    client_conformance_2025_06_18/1,
    client_conformance_2025_03_26/1,
    erlang_client_against_server_everything/1
]).
-define(PORT, 24200).

all() ->
    [
        conformance_2026_07_28,
        conformance_2025_11_25,
        conformance_2025_06_18,
        conformance_2025_03_26,
        requirements_2026_07_28,
        requirements_2025_11_25,
        client_requirements_2026_07_28,
        client_requirements_2025_11_25,
        client_conformance_2025_06_18,
        client_conformance_2025_03_26,
        erlang_client_against_server_everything
    ].

init_per_suite(Config) ->
    case {exe_env("INTEROP_CONFORMANCE"), exe_env("INTEROP_SERVER_EVERYTHING")} of
        {undefined, _} ->
            {skip, "INTEROP_CONFORMANCE not set; run `make conformance`"};
        {_, undefined} ->
            {skip, "INTEROP_SERVER_EVERYTHING not set; run `make conformance`"};
        {Runner, Everything} ->
            {ok, _} = application:ensure_all_started(barrel_mcp),
            {ok, _} = application:ensure_all_started(hackney),
            ok = barrel_mcp_registry:wait_for_ready(),
            [{runner, Runner}, {everything, Everything} | Config]
    end.

end_per_suite(_Config) ->
    application:stop(barrel_mcp),
    ok.

init_per_testcase(erlang_client_against_server_everything, Config) ->
    Config;
init_per_testcase(TC, Config) when
    TC =:= client_requirements_2026_07_28;
    TC =:= client_requirements_2025_11_25;
    TC =:= client_conformance_2025_06_18;
    TC =:= client_conformance_2025_03_26
->
    %% The runner brings its own servers; no fixture, no listener.
    Config;
init_per_testcase(TC, Config) ->
    ok = barrel_mcp_conformance_server:fixture(),
    Port = barrel_mcp_test_helpers:case_port(?PORT + 1, TC, all()),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, session_enabled => true}),
    [{port, Port} | Config].

end_per_testcase(erlang_client_against_server_everything, _Config) ->
    ok;
end_per_testcase(TC, _Config) when
    TC =:= client_requirements_2026_07_28;
    TC =:= client_requirements_2025_11_25;
    TC =:= client_conformance_2025_06_18;
    TC =:= client_conformance_2025_03_26
->
    ok;
end_per_testcase(_TC, _Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    barrel_mcp_conformance_server:cleanup_fixture(),
    timer:sleep(50),
    ok.

%%====================================================================
%% Cases
%%====================================================================

%% Every scenario the runner knows for a revision, drafts included.
conformance_2026_07_28(Config) ->
    run_conformance(Config, "2026-07-28", ["--spec-version", "2026-07-28", "--suite", "all"]).

conformance_2025_11_25(Config) ->
    run_conformance(Config, "2025-11-25", ["--spec-version", "2025-11-25", "--suite", "all"]).

conformance_2025_06_18(Config) ->
    run_conformance(Config, "2025-06-18", ["--spec-version", "2025-06-18", "--suite", "all"]).

conformance_2025_03_26(Config) ->
    run_conformance(Config, "2025-03-26", ["--spec-version", "2025-03-26", "--suite", "all"]).

%% Exactly what a revision required at its release, frozen. The runner
%% ships requirement sets for these two only.
requirements_2026_07_28(Config) ->
    run_conformance(Config, "requirements-2026-07-28", ["--requirements", "2026-07-28"]).

requirements_2025_11_25(Config) ->
    run_conformance(Config, "requirements-2025-11-25", ["--requirements", "2025-11-25"]).

%% Our client under the runner: it starts a server per scenario and
%% runs `barrel_mcp_conformance_client' against it.
client_requirements_2026_07_28(Config) ->
    run_client_conformance(Config, "requirements-2026-07-28", ["--requirements", "2026-07-28"]).

client_requirements_2025_11_25(Config) ->
    run_client_conformance(Config, "requirements-2025-11-25", ["--requirements", "2025-11-25"]).

client_conformance_2025_06_18(Config) ->
    run_client_conformance(Config, "2025-06-18", [
        "--spec-version", "2025-06-18", "--suite", "all"
    ]).

client_conformance_2025_03_26(Config) ->
    run_client_conformance(Config, "2025-03-26", [
        "--spec-version", "2025-03-26", "--suite", "all"
    ]).

run_client_conformance(Config, Label, Selection) ->
    Runner = ?config(runner, Config),
    OutDir = filename:join(priv_dir(Config), "client-conformance-" ++ Label),
    Command = lists:join(" ", [
        barrel_mcp_test_helpers:erl_executable()
        | [
            shell_quote(A)
         || A <- barrel_mcp_test_helpers:child_args(barrel_mcp_conformance_client, main)
        ]
    ]),
    Args =
        [Runner, "client", "--command", lists:flatten(Command), "--timeout", "60000" | Selection] ++
            ["-o", OutDir],
    {Status, Output} = run("node", Args, root_dir()),
    NotScored = not_scored(Runner, Selection, "client"),
    {Pass, Fails, Unscored} = summarise(OutDir, NotScored),
    publish("client", Label, Pass, Fails, Unscored),
    ct:pal(
        "client conformance ~s: ~B passed, ~B failed, ~B not scored~n~s~s",
        [Label, Pass, length(Fails), length(Unscored), Fails, unscored_report(Unscored)]
    ),
    case {Status, Fails} of
        {0, []} ->
            ok;
        _ ->
            ct:fail({client_conformance_failed, Label, Status, Fails, Output})
    end.

%% The runner passes `--command' to a shell.
shell_quote(Arg) ->
    ["'", string:replace(Arg, "'", "'\\''", all), "'"].

%% The reference server as a foreign peer for our client, over stdio.
erlang_client_against_server_everything(Config) ->
    Everything = ?config(everything, Config),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport =>
            {stdio, #{command => os:find_executable("node"), args => [Everything, "stdio"]}}
    }),
    try
        ok = wait_ready(Pid, 50),
        {ok, Version} = barrel_mcp_client:protocol_version(Pid),
        ?assert(lists:member(Version, ?MCP_ALL_VERSIONS)),
        {ok, Tools} = barrel_mcp_client:list_tools(Pid),
        Names = [maps:get(<<"name">>, T) || T <- Tools],
        ?assert(lists:member(<<"echo">>, Names)),
        {ok, Result} = barrel_mcp_client:call_tool(
            Pid, <<"echo">>, #{<<"message">> => <<"from erlang">>}, #{timeout => 10000}
        ),
        [Block | _] = maps:get(<<"content">>, Result),
        ?assertNotEqual(nomatch, binary:match(maps:get(<<"text">>, Block), <<"from erlang">>))
    after
        try
            barrel_mcp_client:close(Pid)
        catch
            _:_ -> ok
        end
    end.

%%====================================================================
%% Running the runner
%%====================================================================

run_conformance(Config, Label, Selection) ->
    Runner = ?config(runner, Config),
    Url = binary_to_list(barrel_mcp_test_helpers:url(?config(port, Config))),
    OutDir = filename:join(priv_dir(Config), "conformance-" ++ Label),
    Args = [Runner, "server", "--url", Url | Selection] ++ ["-o", OutDir],
    {Status, Output} = run("node", Args, root_dir()),
    NotScored = not_scored(Runner, Selection),
    {Pass, Fails, Unscored} = summarise(OutDir, NotScored),
    publish("server", Label, Pass, Fails, Unscored),
    ct:pal(
        "conformance ~s: ~B passed, ~B failed, ~B not scored~n~s~s",
        [Label, Pass, length(Fails), length(Unscored), Fails, unscored_report(Unscored)]
    ),
    case {Status, Fails} of
        {0, []} ->
            ok;
        _ ->
            ct:fail({conformance_failed, Label, Status, Fails, Output})
    end.

%% `make conformance' sets `CONFORMANCE_REPORT_DIR' so CI can publish
%% each run's counts; a plain `rebar3 ct' writes nothing.
publish(Mode, Label, Pass, Fails, Unscored) ->
    case os:getenv("CONFORMANCE_REPORT_DIR") of
        false ->
            ok;
        Dir ->
            ok = filelib:ensure_path(Dir),
            Lines = fun(L) -> [string:trim(unicode:characters_to_binary(X)) || X <- L] end,
            Report = #{
                mode => list_to_binary(Mode),
                run => list_to_binary(Label),
                passed => Pass,
                failed => Lines(Fails),
                not_scored => Lines(Unscored)
            },
            File = filename:join(Dir, Mode ++ "-" ++ Label ++ ".json"),
            ok = file:write_file(File, json:encode(Report))
    end.

unscored_report([]) ->
    "";
unscored_report(Unscored) ->
    ["  not scored by the runner's requirement set (run for visibility):\n" | Unscored].

%% A `--requirements' run also executes the scenarios its YAML lists as
%% `not_scored' (extensions and scenarios pending against the runner's
%% own reference fixture). The runner reports them and exits 0
%% regardless; so does this case, listing them apart. There is no
%% expected-failures file of ours anywhere in this.
not_scored(Runner, Selection) ->
    not_scored(Runner, Selection, "server").

not_scored(Runner, ["--requirements", Revision], Leg) ->
    Yaml = filename:join([
        filename:dirname(filename:dirname(Runner)), "requirements", Revision ++ ".yaml"
    ]),
    {ok, Bin} = file:read_file(Yaml),
    Tail =
        case binary:split(Bin, <<"\nnot_scored:">>) of
            [_, Rest] -> Rest;
            _ -> <<>>
        end,
    Entries = binary:split(Tail, <<"- scenario: ">>, [global]),
    LegLine = list_to_binary("leg: " ++ Leg),
    [
        hd(binary:split(Entry, <<"\n">>))
     || Entry <- tl(Entries), binary:match(Entry, LegLine) =/= nomatch
    ];
not_scored(_Runner, _Selection, _Leg) ->
    [].

%% The runner writes one JSON per scenario; its per-check messages are
%% the diagnostics, so they are what a failure reports.
summarise(OutDir, NotScored) ->
    Files =
        filelib:wildcard(filename:join([OutDir, "*", "*.json"])) ++
            filelib:wildcard(filename:join([OutDir, "*", "*", "*.json"])),
    lists:foldl(
        fun(File, {Pass, Fails, Unscored}) ->
            Scored = not lists:member(scenario_of(File), NotScored),
            {ok, Bin} = file:read_file(File),
            Checks =
                case json:decode(Bin) of
                    L when is_list(L) -> L;
                    #{<<"checks">> := L} -> L;
                    #{<<"results">> := L} -> L;
                    _ -> []
                end,
            lists:foldl(
                fun
                    (#{<<"status">> := <<"SUCCESS">>}, {P, F, U}) ->
                        {P + 1, F, U};
                    (#{<<"status">> := <<"FAILURE">>} = C, {P, F, U}) ->
                        Id = maps:get(<<"id">>, C, maps:get(<<"name">>, C, <<"?">>)),
                        Msg = maps:get(<<"errorMessage">>, C, <<>>),
                        Line = io_lib:format("  ~s :: ~s~n", [Id, Msg]),
                        case Scored of
                            true -> {P, [Line | F], U};
                            false -> {P, F, [Line | U]}
                        end;
                    (_, Acc) ->
                        Acc
                end,
                {Pass, Fails, Unscored},
                Checks
            )
        end,
        {0, [], []},
        Files
    ).

%% `<outdir>/server-tasks-lifecycle-2026-08-29T11-29-55-283Z/x.json':
%% the scenario name is the directory minus the role prefix and the
%% timestamp the runner appends.
scenario_of(File) ->
    Parent = filename:dirname(File),
    Dir0 = list_to_binary(filename:basename(Parent)),
    %% Auth scenarios are written under an `auth/' directory.
    Dir =
        case filename:basename(filename:dirname(Parent)) of
            "auth" -> <<"auth/", Dir0/binary>>;
            _ -> Dir0
        end,
    Name =
        case Dir of
            <<"server-", Rest/binary>> -> Rest;
            <<"client-", Rest/binary>> -> Rest;
            _ -> Dir
        end,
    case re:run(Name, <<"^(.*)-\\d{4}-\\d{2}-\\d{2}T">>, [{capture, all_but_first, binary}]) of
        {match, [Bare]} -> Bare;
        nomatch -> Name
    end.

%%====================================================================
%% Helpers
%%====================================================================

run(Exe, Args, Cwd) ->
    Path = os:find_executable(Exe),
    Port = open_port(
        {spawn_executable, Path},
        [{args, Args}, {cd, Cwd}, exit_status, stderr_to_stdout, use_stdio, binary, {line, 4096}]
    ),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, {_, Line}}} -> collect(Port, [Line, $\n | Acc]);
        {Port, {data, Line}} -> collect(Port, [Line, $\n | Acc]);
        {Port, {exit_status, Status}} -> {Status, lists:flatten(lists:reverse(Acc))}
    after 300000 ->
        _ =
            try
                port_close(Port)
            catch
                _:_ -> ok
            end,
        {timeout, lists:flatten(lists:reverse(Acc))}
    end.

exe_env(Var) ->
    case os:getenv(Var) of
        false ->
            undefined;
        V ->
            case filelib:is_regular(V) of
                true -> V;
                false -> undefined
            end
    end.

priv_dir(Config) ->
    ?config(priv_dir, Config).

root_dir() ->
    {ok, Cwd} = file:get_cwd(),
    find_root(Cwd).

find_root(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true ->
            Dir;
        false ->
            case filename:dirname(Dir) of
                Dir -> Dir;
                Parent -> find_root(Parent)
            end
    end.
