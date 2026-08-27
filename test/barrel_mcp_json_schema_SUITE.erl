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
-export([invalid_schemas_are_refused_at_registration/1, output_schema_by_revision/1]).
-export([vendored_metaschema_is_unchanged/1, dialects_other_than_2020_12_are_refused/1]).
-export([a_tool/1]).

all() ->
    [
        official_suite,
        no_network_dereference,
        bounds_are_enforced,
        invalid_schemas_are_refused_at_registration,
        output_schema_by_revision,
        vendored_metaschema_is_unchanged,
        dialects_other_than_2020_12_are_refused
    ].

a_tool(_Args) -> <<"ok">>.

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

%% "Clients and servers MUST validate schemas according to their
%% declared or default dialect. They MUST handle unsupported dialects
%% gracefully by returning an appropriate error indicating the dialect
%% is not supported" (2026-07-28/basic/index.mdx:292). Validating a
%% draft-07 schema under these rules would apply the wrong ones to
%% `items', `exclusiveMinimum' and `definitions'.
dialects_other_than_2020_12_are_refused(_Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    Object = fun(Dialect) ->
        maps:merge(#{<<"type">> => <<"object">>}, Dialect)
    end,
    Accepted = [
        {<<"absent">>, #{}},
        {<<"2020-12">>, #{<<"$schema">> => <<"https://json-schema.org/draft/2020-12/schema">>}},
        {<<"2020-12 with a fragment">>, #{
            <<"$schema">> => <<"https://json-schema.org/draft/2020-12/schema#">>
        }}
    ],
    lists:foreach(
        fun({Why, Dialect}) ->
            ?assertMatch({Why, {ok, _}}, {Why, barrel_mcp_jsonschema:compile(Object(Dialect))})
        end,
        Accepted
    ),
    Refused = [
        {<<"draft-07">>, <<"http://json-schema.org/draft-07/schema#">>},
        {<<"draft-06">>, <<"http://json-schema.org/draft-06/schema#">>},
        {<<"2019-09">>, <<"https://json-schema.org/draft/2019-09/schema">>}
    ],
    lists:foreach(
        fun({Why, Uri}) ->
            ?assertMatch(
                {Why, {error, {unsupported_dialect, _}}},
                {Why, barrel_mcp_jsonschema:compile(Object(#{<<"$schema">> => Uri}))}
            )
        end,
        Refused
    ),

    %% A metaschema the caller supplied is a dialect we can evaluate: it
    %% is built on these vocabularies, and refusing it would refuse
    %% something we can in fact run.
    Custom = <<"https://example.com/my-metaschema">>,
    ?assertMatch(
        {ok, _},
        barrel_mcp_jsonschema:compile(
            Object(#{<<"$schema">> => Custom}),
            #{Custom => #{<<"$id">> => Custom}}
        )
    ),

    %% And it is refused where a schema enters, not only in the library.
    ?assertMatch(
        {error, {invalid_input_schema, {unsupported_dialect, _}}},
        barrel_mcp:reg_tool(<<"old_dialect">>, ?MODULE, a_tool, #{
            input_schema => Object(#{
                <<"$schema">> => <<"http://json-schema.org/draft-07/schema#">>
            })
        })
    ).

%% The metaschema decides what counts as a schema, so a swapped file
%% would quietly change what every tool definition is measured against.
%% The hashes are recorded in priv/jsonschema/VENDORED.md.
vendored_metaschema_is_unchanged(_Config) ->
    Dir = filename:join(code:priv_dir(barrel_mcp), "jsonschema"),
    lists:foreach(
        fun({File, Expected}) ->
            ?assertEqual({File, Expected}, {File, sha256(filename:join(Dir, File))})
        end,
        vendored_hashes()
    ),
    %% And nothing else is in there posing as one of them.
    Present = [filename:basename(F) || F <- filelib:wildcard(filename:join(Dir, "*.json"))],
    ?assertEqual(lists:sort([F || {F, _} <- vendored_hashes()]), lists:sort(Present)).

vendored_hashes() ->
    [
        {"meta_applicator.json",
            <<"bf273b26f9f735b93ece78f2b61b36676e1d122ce78ab37ad5a2e45dfa1ca2b1">>},
        {"meta_content.json",
            <<"a10456605b2b5bb12a1b4dcfc0300f02f54d3e8bb3646bed7724583866627682">>},
        {"meta_core.json", <<"21f79d143fab1f180245c331e5657057045b36794d41fe151e6e4fed65035299">>},
        {"meta_format-annotation.json",
            <<"5c79404f831dd905c0f40fefac7c6f3e51bf3729b4a876a5c2020178d97f3bcc">>},
        {"meta_meta-data.json",
            <<"c664d438a84d58889c8edecd248ce2f945a4bc0e3b087323b11303dc136abfbe">>},
        {"meta_unevaluated.json",
            <<"fc99f32188da41689a9382af174dd42e8b255e4374965c157b8286556b4ab2bc">>},
        {"meta_validation.json",
            <<"e921c5b79264d3689af01c1af1ffdf692e09f1c45df90a0f08eb7288c9acdeab">>},
        {"schema.json", <<"41da76f5afb7ce062d248f762463a92f7ca47e4e0f905b224ba6afeef91ded0f">>}
    ].

sha256(Path) ->
    {ok, Bin} = file:read_file(Path),
    string:lowercase(binary:encode_hex(crypto:hash(sha256, Bin))).

%% Instance validation does not prove schemas are rejected, so the entry
%% points get their own matrix: anything that is not a schema has to be
%% refused where it is registered rather than where it is used.
invalid_schemas_are_refused_at_registration(_Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    try
        Bad = [
            {<<"type is not a type">>, #{<<"type">> => <<"nope">>}},
            {<<"required is not an array">>, #{
                <<"type">> => <<"object">>, <<"required">> => <<"x">>
            }},
            {<<"properties is not an object">>, #{
                <<"type">> => <<"object">>, <<"properties">> => [1, 2]
            }},
            {<<"unresolvable reference">>, #{
                <<"type">> => <<"object">>,
                <<"$ref">> => <<"https://example.invalid/nope.json">>
            }},
            {<<"minimum is not a number">>, #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{<<"a">> => #{<<"minimum">> => <<"1">>}}
            }}
        ],
        lists:foreach(
            fun({Why, Schema}) ->
                ?assertMatch(
                    {Why, {error, {invalid_input_schema, _}}},
                    {Why,
                        barrel_mcp:reg_tool(<<"bad">>, ?MODULE, a_tool, #{
                            input_schema => Schema
                        })}
                )
            end,
            Bad
        ),
        %% `inputSchema' is object rooted in every revision.
        ?assertMatch(
            {error, {invalid_input_schema, not_object_rooted}},
            barrel_mcp:reg_tool(<<"bad">>, ?MODULE, a_tool, #{
                input_schema => #{<<"type">> => <<"string">>}
            })
        ),
        %% `outputSchema' is not: registration precedes negotiation, and
        %% what a revision can render is decided when it is listed.
        ?assertEqual(
            ok,
            barrel_mcp:reg_tool(<<"scalar_out">>, ?MODULE, a_tool, #{
                input_schema => #{<<"type">> => <<"object">>},
                output_schema => #{<<"type">> => <<"string">>}
            })
        ),
        ?assertMatch(
            {error, {invalid_output_schema, _}},
            barrel_mcp:reg_tool(<<"bad_out">>, ?MODULE, a_tool, #{
                input_schema => #{<<"type">> => <<"object">>},
                output_schema => #{<<"type">> => <<"nope">>}
            })
        )
    after
        barrel_mcp_registry:unreg(tool, <<"scalar_out">>)
    end.

%% A field a revision never had is left out, and the tool stays listed
%% and callable without it.
output_schema_by_revision(_Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"described">>, ?MODULE, a_tool, #{
        input_schema => #{<<"type">> => <<"object">>},
        output_schema => #{<<"type">> => <<"object">>},
        title => <<"Described">>,
        icons => [#{<<"src">> => <<"https://example.com/i.png">>}]
    }),
    try
        Fields = fun(Revision) ->
            Resp = barrel_mcp_protocol:handle(
                #{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"id">> => 1,
                    <<"method">> => <<"tools/list">>,
                    <<"params">> => #{}
                },
                #{protocol_version => Revision}
            ),
            Tools = maps:get(<<"tools">>, maps:get(<<"result">>, Resp)),
            [T] = [T0 || T0 <- Tools, maps:get(<<"name">>, T0) =:= <<"described">>],
            {
                maps:is_key(<<"outputSchema">>, T),
                maps:is_key(<<"title">>, T),
                maps:is_key(<<"icons">>, T)
            }
        end,
        ?assertEqual({false, false, false}, Fields(<<"2024-11-05">>)),
        ?assertEqual({false, false, false}, Fields(<<"2025-03-26">>)),
        ?assertEqual({true, true, false}, Fields(<<"2025-06-18">>)),
        ?assertEqual({true, true, true}, Fields(<<"2025-11-25">>)),
        ?assertEqual({true, true, true}, Fields(<<"2026-07-28">>))
    after
        barrel_mcp_registry:unreg(tool, <<"described">>)
    end.

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
