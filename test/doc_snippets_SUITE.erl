%%%-------------------------------------------------------------------
%%% @doc Common-test suite that runs `test/snippet_check.escript' so
%%% CI catches drift in `guides/building-a-client.md',
%%% `guides/internals.md', and `examples/*/README.md'.
%%%
%%% Snippets in markdown tagged ` ```erlang ` are extracted and
%%% compiled. Tag illustrative blocks with ` ```erl ` (or any other
%%% info string) to skip them.
%%% @end
%%%-------------------------------------------------------------------
-module(doc_snippets_SUITE).

-include_lib("common_test/include/ct.hrl").

-export([all/0]).
-export([snippets_compile/1]).

all() -> [snippets_compile].

snippets_compile(_Config) ->
    Script = filename:join([code:lib_dir(barrel_mcp), "..", "..", "..", "..",
                            "test", "snippet_check.escript"]),
    %% When the suite runs from a release-style location, fall back to
    %% the canonical project path.
    Resolved = case filelib:is_regular(Script) of
                   true -> Script;
                   false ->
                       filename:join([project_root(),
                                      "test", "snippet_check.escript"])
               end,
    Cmd = "escript " ++ Resolved,
    {Status, Output} = run(Cmd),
    ct:log("snippet_check output:~n~s", [Output]),
    case Status of
        0 -> ok;
        N -> ct:fail({snippet_check_failed, N, Output})
    end.

run(Cmd) ->
    Port = open_port({spawn, Cmd}, [exit_status, stderr_to_stdout, binary]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, S}} -> {S, binary_to_list(Acc)}
    after 60000 ->
        catch port_close(Port),
        {1, "snippet_check: timed out"}
    end.

%% Walk up from this file's location to the project root (the
%% directory containing `rebar.config').
project_root() ->
    walk_up(filename:dirname(code:which(?MODULE))).

walk_up(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true -> Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                Dir -> error(project_root_not_found);
                _ -> walk_up(Parent)
            end
    end.
