%%%-------------------------------------------------------------------
%%% @doc The official JSON-Schema-Test-Suite, run against our validator.
%%%
%%% Every file under `test/json_schema_suite/tests' is a group of
%%% schemas, each with a list of instances and whether they are valid.
%%% The suite is vendored at a pinned commit; see its VENDORED.md.
%%%
%%% `remotes/' is served from memory rather than over HTTP: the spec
%%% forbids dereferencing a `$ref' over the network, so a harness that
%%% fetched them would be testing something we must not do.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_json_schema_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([official_suite/1, no_network_dereference/1, bounds_are_enforced/1]).

all() ->
    [official_suite, no_network_dereference, bounds_are_enforced].

init_per_suite(Config) ->
    [{remotes, load_remotes()} | Config].

end_per_suite(_Config) ->
    ok.

%%====================================================================
%% Cases
%%====================================================================

official_suite(Config) ->
    Remotes = ?config(remotes, Config),
    Files = filelib:wildcard(filename:join(tests_dir(), "*.json")),
    ?assert(length(Files) > 40),
    All = lists:append([run_file(F, Remotes) || F <- Files]),
    {Skipped, Failures} = lists:partition(fun is_skipped/1, All),
    ct:pal("~B skipped, ~B failures", [length(Skipped), length(Failures)]),
    %% A skip that stops being needed is itself a failure: the list is
    %% what we claim not to implement, not a place for stale entries.
    Stale = [S || S <- skips(), not lists:any(fun(F) -> matches_skip(F, S) end, All)],
    case {Failures, Stale} of
        {[], []} ->
            ok;
        {[], _} ->
            ct:fail({stale_skips, Stale});
        _ ->
            ct:pal("~B failures:~n~s", [length(Failures), format(Failures)]),
            ct:fail({json_schema_suite, length(Failures)})
    end.

%% What we do not implement, and why. Anything not listed here has to
%% pass.
skips() ->
    [
        {<<"pattern.json">>, <<"pattern with Unicode property escape requires unicode mode">>,
            <<"ECMAScript regex, not PCRE: \\p{Letter} is not a PCRE property name">>},
        {<<"vocabulary.json">>,
            <<"schema that uses custom metaschema with with no validation vocabulary">>,
            <<"$vocabulary does not switch keyword sets off">>}
    ].

is_skipped({File, Group, _Test, _Result}) ->
    lists:any(fun({F, G, _Why}) -> F =:= File andalso G =:= Group end, skips()).

matches_skip({File, Group, _Test, _Result}, {F, G, _Why}) ->
    File =:= F andalso Group =:= G.

%% "MUST NOT" fetch an absolute-URI reference. An unknown one is an
%% error at compile time, and the error is what proves nothing was
%% attempted: a fetch would have failed differently and much later.
no_network_dereference(_Config) ->
    Schema = #{<<"$ref">> => <<"https://example.com/not-supplied.json">>},
    ?assertMatch({error, {unresolved_ref, _}}, barrel_mcp_jsonschema:compile(Schema)),
    ?assertNot(barrel_mcp_jsonschema:is_valid_schema(Schema)),
    %% Supplied through the registry, the same reference resolves.
    Registry = #{
        <<"https://example.com/not-supplied.json">> => #{<<"type">> => <<"string">>}
    },
    {ok, Compiled} = barrel_mcp_jsonschema:compile(Schema, Registry),
    ?assertEqual(ok, barrel_mcp_jsonschema:validate(<<"x">>, Compiled, #{})),
    ?assertMatch({error, _}, barrel_mcp_jsonschema:validate(1, Compiled, #{})).

%% A schema deep enough or wide enough to be a denial of service is
%% refused rather than run.
bounds_are_enforced(_Config) ->
    Deep = lists:foldl(
        fun(_, Acc) -> #{<<"items">> => Acc} end,
        #{<<"type">> => <<"string">>},
        lists:seq(1, 200)
    ),
    ?assertMatch({error, too_deep}, barrel_mcp_jsonschema:compile(Deep)).

%%====================================================================
%% Running one file
%%====================================================================

run_file(File, Remotes) ->
    Groups = json:decode(read(File)),
    Name = list_to_binary(filename:basename(File)),
    lists:append([run_group(Name, G, Remotes) || G <- Groups]).

run_group(File, Group, Remotes) ->
    Description = maps:get(<<"description">>, Group, <<>>),
    Schema = maps:get(<<"schema">>, Group),
    case barrel_mcp_jsonschema:compile(Schema, Remotes) of
        {error, Reason} ->
            [{File, Description, <<"(compile)">>, {compile_failed, Reason}}];
        {ok, Compiled} ->
            Outcomes = [
                {File, Description, maps:get(<<"description">>, T, <<>>), run_test(Compiled, T)}
             || T <- maps:get(<<"tests">>, Group, [])
            ],
            [O || {_, _, _, Result} = O <- Outcomes, Result =/= ok]
    end.

run_test(Compiled, Test) ->
    Data = maps:get(<<"data">>, Test),
    Expected = maps:get(<<"valid">>, Test),
    Actual =
        case barrel_mcp_jsonschema:validate(Data, Compiled, #{}) of
            ok -> true;
            {error, _} -> false
        end,
    case Actual =:= Expected of
        true -> ok;
        false -> {expected, Expected, got, Actual}
    end.

%%====================================================================
%% Helpers
%%====================================================================

suite_dir() ->
    filename:join([code:lib_dir(barrel_mcp), "..", "..", "..", "..", "test", "json_schema_suite"]).

tests_dir() ->
    case filelib:is_dir(filename:join(suite_dir(), "tests")) of
        true -> filename:join(suite_dir(), "tests");
        false -> filename:join(["test", "json_schema_suite", "tests"])
    end.

remotes_dir() ->
    case filelib:is_dir(filename:join(suite_dir(), "remotes")) of
        true -> filename:join(suite_dir(), "remotes");
        false -> filename:join(["test", "json_schema_suite", "remotes"])
    end.

%% The suite's remotes are addressed as `http://localhost:1234/<path>'.
load_remotes() ->
    Dir = remotes_dir(),
    Files = filelib:wildcard(filename:join(Dir, "**/*.json")),
    maps:from_list([
        {uri_for(Dir, F), json:decode(read(F))}
     || F <- Files
    ]).

uri_for(Dir, File) ->
    Relative = string:prefix(File, Dir ++ "/"),
    iolist_to_binary(["http://localhost:1234/", Relative]).

read(File) ->
    {ok, Bin} = file:read_file(File),
    Bin.

format(Failures) ->
    [
        io_lib:format("  ~ts / ~ts / ~ts: ~p~n", [F, G, T, R])
     || {F, G, T, R} <- Failures
    ].
