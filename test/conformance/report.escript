#!/usr/bin/env escript
%%! -noshell
%%
%% report: print the last `make conformance' run as a Markdown table,
%% one row per runner invocation. CI appends it to the job summary.
%%
%% Usage:
%%   escript test/conformance/report.escript ReportDir PackageJson
%%
%% Exits 1 when there are no reports, so an empty run cannot read as a
%% clean one.

main([Dir, Package]) ->
    case lists:sort(filelib:wildcard(filename:join(Dir, "*.json"))) of
        [] ->
            io:format(standard_error, "no conformance reports in ~s~n", [Dir]),
            halt(1);
        Files ->
            Reports = [json:decode(element(2, {ok, _} = file:read_file(F))) || F <- Files],
            io:format("~ts", [table(Reports, runner_version(Package))])
    end;
main(_) ->
    io:format(standard_error, "usage: report.escript ReportDir PackageJson~n", []),
    halt(2).

runner_version(Package) ->
    {ok, Bin} = file:read_file(Package),
    #{<<"dependencies">> := Deps} = json:decode(Bin),
    maps:get(<<"@modelcontextprotocol/conformance">>, Deps, <<"unknown">>).

table(Reports, Version) ->
    Failed = lists:sum([length(maps:get(<<"failed">>, R)) || R <- Reports]),
    Unscored = lists:sum([length(maps:get(<<"not_scored">>, R)) || R <- Reports]),
    Header = [
        "## MCP conformance\n\n",
        "Official runner `@modelcontextprotocol/conformance` ", Version, ". ",
        integer_to_list(length(Reports)), " runs, ", integer_to_list(Failed),
        " scored failures, ", integer_to_list(Unscored),
        " failures in scenarios the runner does not score.\n\n",
        "| Mode | Run | Checks passed | Failed | Failed, not scored |\n",
        "|---|---|---:|---:|---:|\n"
    ],
    Rows = [row(R) || R <- Reports],
    Details = [details(R) || R <- Reports, failures(R) =/= []],
    unicode:characters_to_binary([Header, Rows, "\n", Details]).

row(#{<<"mode">> := Mode, <<"run">> := Run, <<"passed">> := Pass} = R) ->
    [
        "| ", Mode, " | ", Run, " | ", integer_to_list(Pass), " | ",
        integer_to_list(length(maps:get(<<"failed">>, R))), " | ",
        integer_to_list(length(maps:get(<<"not_scored">>, R))), " |\n"
    ].

failures(R) ->
    maps:get(<<"failed">>, R) ++ maps:get(<<"not_scored">>, R).

details(#{<<"mode">> := Mode, <<"run">> := Run} = R) ->
    ["### ", Mode, " ", Run, "\n\n", [["- `", F, "`\n"] || F <- failures(R)], "\n"].
