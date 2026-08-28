%%%-------------------------------------------------------------------
%%% @doc The official MCP conformance runner, driven against our
%%% Streamable server, and the official reference server driven by our
%%% client.
%%%
%%% Nothing here asserts a wire shape of its own. The fixtures below
%%% are what the runner's scenarios say a server must expose, verbatim
%%% from their descriptions, and the runner's own per-check messages
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
    erlang_client_against_server_everything/1
]).
%% Tools
-export([
    simple_text/1,
    image_content/1,
    audio_content/1,
    embedded_resource/1,
    multiple_content_types/1,
    error_handling/1,
    with_progress/2,
    with_logging/2,
    sampling/2,
    elicitation/2,
    input_required_elicitation/2,
    input_required_sampling/2,
    input_required_list_roots/2,
    input_required_capabilities/2,
    input_required_request_state/2,
    input_required_multiple_inputs/2,
    input_required_multi_round/2,
    input_required_tampered_state/2,
    schema_2020_12/1,
    missing_capability/2,
    streaming_elicitation/2,
    logging_tool/2
]).
%% Resources and prompts
-export([
    static_text/1,
    static_binary/1,
    template_data/1,
    simple_prompt/1,
    prompt_with_arguments/1,
    prompt_with_embedded_resource/1,
    prompt_with_image/1,
    input_required_prompt/2,
    arg1_completion/2
]).

-define(PORT, 24200).
-define(PNG,
    <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC">>
).
-define(WAV, <<"UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA==">>).

all() ->
    [
        conformance_2026_07_28,
        conformance_2025_11_25,
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
init_per_testcase(TC, Config) ->
    ok = fixture(),
    Port = ?PORT + case_index(TC),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, session_enabled => true}),
    [{port, Port} | Config].

end_per_testcase(erlang_client_against_server_everything, _Config) ->
    ok;
end_per_testcase(_TC, _Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    cleanup_fixture(),
    timer:sleep(50),
    ok.

%%====================================================================
%% Cases
%%====================================================================

conformance_2026_07_28(Config) ->
    run_conformance(Config, "2026-07-28").

conformance_2025_11_25(Config) ->
    run_conformance(Config, "2025-11-25").

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

run_conformance(Config, Version) ->
    Runner = ?config(runner, Config),
    Url = binary_to_list(barrel_mcp_test_helpers:url(?config(port, Config))),
    OutDir = filename:join(priv_dir(Config), "conformance-" ++ Version),
    Args = [
        Runner,
        "server",
        "--url",
        Url,
        "--spec-version",
        Version,
        "--suite",
        "all",
        "-o",
        OutDir
    ],
    {Status, Output} = run("node", Args, root_dir()),
    {Pass, Fails} = summarise(OutDir),
    ct:pal("conformance ~s: ~B passed, ~B failed~n~s", [Version, Pass, length(Fails), Fails]),
    case {Status, Fails} of
        {0, []} ->
            ok;
        _ ->
            ct:fail({conformance_failed, Version, Status, Fails, Output})
    end.

%% The runner writes one JSON per scenario; its per-check messages are
%% the diagnostics, so they are what a failure reports.
summarise(OutDir) ->
    Files = filelib:wildcard(filename:join([OutDir, "*", "*.json"])),
    lists:foldl(
        fun(File, {Pass, Fails}) ->
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
                    (#{<<"status">> := <<"SUCCESS">>}, {P, F}) ->
                        {P + 1, F};
                    (#{<<"status">> := <<"FAILURE">>} = C, {P, F}) ->
                        Id = maps:get(<<"id">>, C, maps:get(<<"name">>, C, <<"?">>)),
                        Msg = maps:get(<<"errorMessage">>, C, <<>>),
                        {P, [io_lib:format("  ~s :: ~s~n", [Id, Msg]) | F]};
                    (_, Acc) ->
                        Acc
                end,
                {Pass, Fails},
                Checks
            )
        end,
        {0, []},
        Files
    ).

%%====================================================================
%% Fixture: what the scenarios say a server must expose
%%====================================================================

fixture() ->
    Tools = [
        {<<"test_simple_text">>, simple_text, #{}},
        {<<"test_image_content">>, image_content, #{}},
        {<<"test_audio_content">>, audio_content, #{}},
        {<<"test_embedded_resource">>, embedded_resource, #{}},
        {<<"test_multiple_content_types">>, multiple_content_types, #{}},
        {<<"test_error_handling">>, error_handling, #{}},
        {<<"test_tool_with_progress">>, with_progress, #{}},
        {<<"test_tool_with_logging">>, with_logging, #{}},
        {<<"test_sampling">>, sampling, #{
            input_schema => #{
                <<"type">> => <<"object">>,
                <<"required">> => [<<"prompt">>],
                <<"properties">> => #{<<"prompt">> => #{<<"type">> => <<"string">>}}
            }
        }},
        {<<"test_elicitation">>, elicitation, #{
            input_schema => #{
                <<"type">> => <<"object">>,
                <<"required">> => [<<"message">>],
                <<"properties">> => #{<<"message">> => #{<<"type">> => <<"string">>}}
            }
        }},
        {<<"test_input_required_result_elicitation">>, input_required_elicitation, #{}},
        {<<"test_input_required_result_sampling">>, input_required_sampling, #{}},
        {<<"test_input_required_result_list_roots">>, input_required_list_roots, #{}},
        {<<"test_input_required_result_capabilities">>, input_required_capabilities, #{}},
        {<<"test_input_required_result_request_state">>, input_required_request_state, #{}},
        {<<"test_input_required_result_multiple_inputs">>, input_required_multiple_inputs, #{}},
        {<<"test_input_required_result_multi_round">>, input_required_multi_round, #{}},
        {<<"test_input_required_result_tampered_state">>, input_required_tampered_state, #{}},
        {<<"json_schema_2020_12_tool">>, schema_2020_12, #{input_schema => schema_2020_12_input()}},
        {<<"test_missing_capability">>, missing_capability, #{}},
        {<<"test_streaming_elicitation">>, streaming_elicitation, #{}},
        {<<"test_logging_tool">>, logging_tool, #{}},
        %% The SEP-2243 scenarios need at least one x-mcp-header binding.
        {<<"test_header_param">>, simple_text, #{
            input_schema => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"region">> => #{
                        <<"type">> => <<"string">>, <<"x-mcp-header">> => <<"Region">>
                    }
                }
            }
        }}
    ],
    lists:foreach(
        fun({Name, Fun, Opts}) ->
            ok = barrel_mcp_registry:reg(
                tool, Name, ?MODULE, Fun, Opts#{description => <<"conformance fixture">>}
            )
        end,
        Tools
    ),
    ok = barrel_mcp_registry:reg(resource, <<"static_text">>, ?MODULE, static_text, #{
        name => <<"Static Text">>, uri => <<"test://static-text">>, mime_type => <<"text/plain">>
    }),
    ok = barrel_mcp_registry:reg(resource, <<"static_binary">>, ?MODULE, static_binary, #{
        name => <<"Static Binary">>,
        uri => <<"test://static-binary">>,
        mime_type => <<"application/octet-stream">>
    }),
    ok = barrel_mcp:reg_resource_template(<<"template_data">>, ?MODULE, template_data, #{
        name => <<"Template">>,
        uri_template => <<"test://template/{id}/data">>,
        mime_type => <<"application/json">>
    }),
    ok = barrel_mcp_registry:reg(prompt, <<"test_simple_prompt">>, ?MODULE, simple_prompt, #{
        description => <<"conformance fixture">>
    }),
    ok = barrel_mcp_registry:reg(
        prompt, <<"test_prompt_with_arguments">>, ?MODULE, prompt_with_arguments, #{
            description => <<"conformance fixture">>,
            arguments => [
                #{name => <<"arg1">>, required => false},
                #{name => <<"arg2">>, required => false}
            ]
        }
    ),
    ok = barrel_mcp_registry:reg(
        prompt, <<"test_prompt_with_embedded_resource">>, ?MODULE, prompt_with_embedded_resource, #{
            description => <<"conformance fixture">>,
            arguments => [#{name => <<"resourceUri">>, required => false}]
        }
    ),
    ok = barrel_mcp_registry:reg(
        prompt, <<"test_prompt_with_image">>, ?MODULE, prompt_with_image, #{
            description => <<"conformance fixture">>
        }
    ),
    ok = barrel_mcp_registry:reg(
        prompt, <<"test_input_required_result_prompt">>, ?MODULE, input_required_prompt, #{
            description => <<"conformance fixture">>
        }
    ),
    ok = barrel_mcp:reg_completion(
        {prompt, <<"test_prompt_with_arguments">>, <<"arg1">>}, ?MODULE, arg1_completion, #{}
    ),
    ok.

cleanup_fixture() ->
    Tools = [
        <<"test_simple_text">>,
        <<"test_image_content">>,
        <<"test_audio_content">>,
        <<"test_embedded_resource">>,
        <<"test_multiple_content_types">>,
        <<"test_error_handling">>,
        <<"test_tool_with_progress">>,
        <<"test_tool_with_logging">>,
        <<"test_sampling">>,
        <<"test_elicitation">>,
        <<"test_input_required_result_elicitation">>,
        <<"test_input_required_result_sampling">>,
        <<"test_input_required_result_list_roots">>,
        <<"test_input_required_result_capabilities">>,
        <<"test_input_required_result_request_state">>,
        <<"test_input_required_result_multiple_inputs">>,
        <<"test_input_required_result_multi_round">>,
        <<"test_input_required_result_tampered_state">>,
        <<"json_schema_2020_12_tool">>,
        <<"test_missing_capability">>,
        <<"test_streaming_elicitation">>,
        <<"test_logging_tool">>,
        <<"test_header_param">>
    ],
    _ = [safe_unreg(tool, T) || T <- Tools],
    _ = [safe_unreg(resource, R) || R <- [<<"static_text">>, <<"static_binary">>]],
    _ = safe_unreg(resource_template, <<"template_data">>),
    _ = [
        safe_unreg(prompt, P)
     || P <- [
            <<"test_simple_prompt">>,
            <<"test_prompt_with_arguments">>,
            <<"test_prompt_with_embedded_resource">>,
            <<"test_prompt_with_image">>,
            <<"test_input_required_result_prompt">>
        ]
    ],
    _ = barrel_mcp:unreg_completion({prompt, <<"test_prompt_with_arguments">>, <<"arg1">>}),
    ok.

safe_unreg(Kind, Name) ->
    try
        barrel_mcp_registry:unreg(Kind, Name)
    catch
        _:_ -> ok
    end.

%%--- tools ------------------------------------------------------------

simple_text(_) ->
    <<"This is a simple text response for testing.">>.

image_content(_) ->
    [#{<<"type">> => <<"image">>, <<"data">> => ?PNG, <<"mimeType">> => <<"image/png">>}].

audio_content(_) ->
    [#{<<"type">> => <<"audio">>, <<"data">> => ?WAV, <<"mimeType">> => <<"audio/wav">>}].

embedded_resource(_) ->
    [
        #{
            <<"type">> => <<"resource">>,
            <<"resource">> => #{
                <<"uri">> => <<"test://embedded-resource">>,
                <<"mimeType">> => <<"text/plain">>,
                <<"text">> => <<"This is an embedded resource content.">>
            }
        }
    ].

multiple_content_types(_) ->
    [
        #{<<"type">> => <<"text">>, <<"text">> => <<"Multiple content types test:">>},
        #{<<"type">> => <<"image">>, <<"data">> => ?PNG, <<"mimeType">> => <<"image/png">>},
        #{
            <<"type">> => <<"resource">>,
            <<"resource">> => #{
                <<"uri">> => <<"test://mixed-content-resource">>,
                <<"mimeType">> => <<"application/json">>,
                <<"text">> => <<"{\"test\":\"data\",\"value\":123}">>
            }
        }
    ].

error_handling(_) ->
    {tool_error, [
        #{
            <<"type">> => <<"text">>,
            <<"text">> => <<"This tool intentionally returns an error for testing">>
        }
    ]}.

with_progress(_, Ctx) ->
    Emit = maps:get(emit_progress, Ctx),
    Emit(0, 100, undefined),
    timer:sleep(50),
    Emit(50, 100, undefined),
    timer:sleep(50),
    Emit(100, 100, undefined),
    <<"Tool with progress executed">>.

with_logging(_, Ctx) ->
    ok = barrel_mcp:log(Ctx, info, <<"Tool execution started">>),
    timer:sleep(50),
    ok = barrel_mcp:log(Ctx, info, <<"Tool processing data">>),
    timer:sleep(50),
    ok = barrel_mcp:log(Ctx, info, <<"Tool execution completed">>),
    <<"Tool with logging executed">>.

%% Legacy sampling: the session's channel. Modern callers use the
%% input_required tools instead.
sampling(#{<<"prompt">> := Prompt}, Ctx) ->
    Params = #{
        <<"messages">> => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => Prompt}
            }
        ],
        <<"maxTokens">> => 100
    },
    case barrel_mcp:sampling_create_message(session(Ctx), Params, #{timeout_ms => 5000}) of
        {ok, Result, _} ->
            Text = maps:get(<<"text">>, maps:get(<<"content">>, Result, #{}), <<>>),
            <<"LLM response: ", Text/binary>>;
        {error, Reason} ->
            {tool_error, [text(io_lib:format("sampling failed: ~p", [Reason]))]}
    end.

elicitation(#{<<"message">> := Message}, Ctx) ->
    Params = #{
        <<"message">> => Message,
        <<"requestedSchema">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"username">> => #{
                    <<"type">> => <<"string">>, <<"description">> => <<"User's response">>
                },
                <<"email">> => #{
                    <<"type">> => <<"string">>, <<"description">> => <<"User's email address">>
                }
            },
            <<"required">> => [<<"username">>, <<"email">>]
        }
    },
    case barrel_mcp:elicit_create(session(Ctx), Params, #{timeout_ms => 5000}) of
        {ok, Result} ->
            Action = maps:get(<<"action">>, Result, <<"unknown">>),
            Content = maps:get(<<"content">>, Result, #{}),
            text(
                io_lib:format("User response: action: ~s, content: ~s", [
                    Action, json:encode(Content)
                ])
            );
        {error, Reason} ->
            {tool_error, [text(io_lib:format("elicitation failed: ~p", [Reason]))]}
    end.

%% MRTR: round one asks, round two answers with what came back.
input_required_elicitation(_, Ctx) ->
    case barrel_mcp:input(Ctx, <<"user_name">>) of
        none ->
            {input_required,
                #{
                    <<"user_name">> => #{
                        method => <<"elicitation/create">>,
                        params => #{
                            <<"message">> => <<"What is your name?">>,
                            <<"requestedSchema">> => #{
                                <<"type">> => <<"object">>,
                                <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}},
                                <<"required">> => [<<"name">>]
                            }
                        }
                    }
                },
                round_one};
        {ok, #{<<"content">> := Content}} ->
            <<"Hello, ", (maps:get(<<"name">>, Content, <<"stranger">>))/binary, "!">>;
        {ok, _} ->
            <<"Hello, stranger!">>
    end.

input_required_sampling(_, Ctx) ->
    case barrel_mcp:input(Ctx, <<"llm">>) of
        none ->
            {input_required,
                #{
                    <<"llm">> => #{
                        method => <<"sampling/createMessage">>,
                        params => #{
                            <<"messages">> => [
                                #{
                                    <<"role">> => <<"user">>,
                                    <<"content">> => #{
                                        <<"type">> => <<"text">>, <<"text">> => <<"Say hello">>
                                    }
                                }
                            ],
                            <<"maxTokens">> => 50
                        }
                    }
                },
                round_one};
        {ok, Result} ->
            Text = maps:get(<<"text">>, maps:get(<<"content">>, Result, #{}), <<"nothing">>),
            <<"LLM said: ", Text/binary>>
    end.

input_required_list_roots(_, Ctx) ->
    case barrel_mcp:input(Ctx, <<"roots">>) of
        none ->
            {input_required, #{<<"roots">> => #{method => <<"roots/list">>, params => #{}}},
                round_one};
        {ok, Result} ->
            Roots = maps:get(<<"roots">>, Result, []),
            text(io_lib:format("~B roots", [length(Roots)]))
    end.

schema_2020_12(_) ->
    <<"schema tool executed">>.

%% Asks for sampling, which the scenario's client never declares, so
%% the server's own capability check is what answers.
missing_capability(_, Ctx) ->
    case barrel_mcp:input(Ctx, <<"probe">>) of
        none ->
            {input_required, #{<<"probe">> => sampling_request(<<"Capability probe">>)}, probe};
        {ok, _} ->
            <<"capability present">>
    end.

streaming_elicitation(Args, Ctx) ->
    input_required_elicitation(Args, Ctx).

%% Only requests the client can answer: read what it declared.
input_required_capabilities(_, Ctx) ->
    case barrel_mcp:input(Ctx, <<"greeting">>) of
        none ->
            Requests = maps:filter(
                fun(_K, #{method := M}) -> declared_for(M, Ctx) end,
                #{
                    <<"user_name">> => elicitation_request(<<"What is your name?">>),
                    <<"greeting">> => sampling_request(<<"Generate a greeting">>),
                    <<"client_roots">> => #{method => <<"roots/list">>, params => #{}}
                }
            ),
            {input_required, Requests, probe};
        {ok, _} ->
            <<"answered">>
    end.

declared_for(<<"elicitation/create">>, Ctx) -> barrel_mcp:client_supports(Ctx, elicitation);
declared_for(<<"sampling/createMessage">>, Ctx) -> barrel_mcp:client_supports(Ctx, sampling);
declared_for(<<"roots/list">>, Ctx) -> barrel_mcp:client_supports(Ctx, roots).

%% Round two must confirm the state came back intact: the runner looks
%% for the word state-ok.
input_required_request_state(_, Ctx) ->
    case barrel_mcp:input(Ctx, <<"confirm">>) of
        none ->
            {input_required,
                #{
                    <<"confirm">> => #{
                        method => <<"elicitation/create">>,
                        params => #{
                            <<"message">> => <<"Please confirm">>,
                            <<"requestedSchema">> => #{
                                <<"type">> => <<"object">>,
                                <<"properties">> => #{<<"ok">> => #{<<"type">> => <<"boolean">>}},
                                <<"required">> => [<<"ok">>]
                            }
                        }
                    }
                },
                <<"confirm-state">>};
        {ok, _} ->
            case barrel_mcp:request_state(Ctx) of
                {ok, <<"confirm-state">>} -> <<"state-ok: confirmed">>;
                _ -> {tool_error, [text(<<"state missing or wrong">>)]}
            end
    end.

%% Three kinds at once, all answered before completing.
input_required_multiple_inputs(_, Ctx) ->
    case barrel_mcp:input(Ctx, <<"user_name">>) of
        none ->
            {input_required,
                #{
                    <<"user_name">> => elicitation_request(<<"What is your name?">>),
                    <<"greeting">> => sampling_request(<<"Generate a greeting">>),
                    <<"client_roots">> => #{method => <<"roots/list">>, params => #{}}
                },
                multi};
        {ok, _} ->
            <<"all inputs received">>
    end.

%% Two rounds of asking. Each round carries only its own answers, so the
%% handler remembers where it is in the state it seals.
input_required_multi_round(_, Ctx) ->
    Round =
        case barrel_mcp:request_state(Ctx) of
            {ok, R} -> R;
            none -> <<"start">>
        end,
    case {Round, barrel_mcp:input(Ctx, <<"step1">>), barrel_mcp:input(Ctx, <<"step2">>)} of
        {<<"start">>, none, _} ->
            {input_required,
                #{<<"step1">> => elicitation_request(<<"Step 1: What is your name?">>)},
                <<"round-1">>};
        {<<"round-1">>, {ok, _}, none} ->
            {input_required,
                #{
                    <<"step2">> => #{
                        method => <<"elicitation/create">>,
                        params => #{
                            <<"message">> => <<"Step 2: What is your favorite color?">>,
                            <<"requestedSchema">> => #{
                                <<"type">> => <<"object">>,
                                <<"properties">> => #{<<"color">> => #{<<"type">> => <<"string">>}},
                                <<"required">> => [<<"color">>]
                            }
                        }
                    }
                },
                <<"round-2">>};
        {<<"round-2">>, _, {ok, _}} ->
            <<"multi-round complete">>
    end.

%% The state is HMAC-sealed by the server; a tampered one never reaches
%% this handler, so round one is all it has to do.
input_required_tampered_state(Args, Ctx) ->
    input_required_request_state(Args, Ctx).

elicitation_request(Message) ->
    #{
        method => <<"elicitation/create">>,
        params => #{
            <<"message">> => Message,
            <<"requestedSchema">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}},
                <<"required">> => [<<"name">>]
            }
        }
    }.

sampling_request(Text) ->
    #{
        method => <<"sampling/createMessage">>,
        params => #{
            <<"messages">> => [
                #{
                    <<"role">> => <<"user">>,
                    <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => Text}
                }
            ],
            <<"maxTokens">> => 50
        }
    }.

%% Logs, so the scenario can check nothing arrives without a logLevel
%% opt-in.
logging_tool(_, Ctx) ->
    ok = barrel_mcp:log(Ctx, info, <<"diagnostic log line">>),
    <<"logged">>.

%%--- resources --------------------------------------------------------

static_text(_) ->
    #{text => <<"This is static text resource content.">>, mimeType => <<"text/plain">>}.

static_binary(_) ->
    #{blob => base64:decode(?PNG), mimeType => <<"application/octet-stream">>}.

template_data(Args) ->
    Id = maps:get(<<"id">>, Args, <<"unknown">>),
    #{
        text => iolist_to_binary(
            json:encode(#{
                <<"id">> => Id,
                <<"templateTest">> => true,
                <<"data">> => <<"Data for ID: ", Id/binary>>
            })
        ),
        mimeType => <<"application/json">>
    }.

%%--- prompts ----------------------------------------------------------

simple_prompt(_) ->
    #{messages => [user(<<"This is a simple prompt for testing.">>)]}.

prompt_with_arguments(Args) ->
    Arg1 = maps:get(<<"arg1">>, Args, <<"none">>),
    Arg2 = maps:get(<<"arg2">>, Args, <<"none">>),
    #{messages => [user(<<"Prompt with arguments: ", Arg1/binary, ", ", Arg2/binary>>)]}.

prompt_with_embedded_resource(Args) ->
    Uri = maps:get(<<"resourceUri">>, Args, <<"test://example-resource">>),
    #{
        messages => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => #{
                    <<"type">> => <<"resource">>,
                    <<"resource">> => #{
                        <<"uri">> => Uri,
                        <<"mimeType">> => <<"text/plain">>,
                        <<"text">> => <<"Embedded resource content">>
                    }
                }
            }
        ]
    }.

prompt_with_image(_) ->
    #{
        messages => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => #{
                    <<"type">> => <<"image">>, <<"data">> => ?PNG, <<"mimeType">> => <<"image/png">>
                }
            }
        ]
    }.

input_required_prompt(_, Ctx) ->
    case barrel_mcp:input(Ctx, <<"context">>) of
        none ->
            {input_required,
                #{
                    <<"context">> => #{
                        method => <<"elicitation/create">>,
                        params => #{
                            <<"message">> => <<"Provide context">>,
                            <<"requestedSchema">> => #{
                                <<"type">> => <<"object">>,
                                <<"properties">> => #{
                                    <<"context">> => #{<<"type">> => <<"string">>}
                                }
                            }
                        }
                    }
                },
                round_one};
        {ok, Result} ->
            Content = maps:get(<<"content">>, Result, #{}),
            #{
                messages => [
                    user(<<"Context: ", (maps:get(<<"context">>, Content, <<"none">>))/binary>>)
                ]
            }
    end.

arg1_completion(_Partial, _Ctx) ->
    {ok, [<<"test">>, <<"testing">>]}.

%%--- shared -----------------------------------------------------------

user(Text) ->
    #{<<"role">> => <<"user">>, <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => Text}}.

text(IoData) ->
    #{<<"type">> => <<"text">>, <<"text">> => iolist_to_binary(IoData)}.

session(Ctx) ->
    maps:get(session_id, Ctx).

schema_2020_12_input() ->
    #{
        <<"$schema">> => <<"https://json-schema.org/draft/2020-12/schema">>,
        <<"type">> => <<"object">>,
        <<"$defs">> => #{
            <<"address">> => #{
                <<"$anchor">> => <<"addressDef">>,
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"street">> => #{<<"type">> => <<"string">>},
                    <<"city">> => #{<<"type">> => <<"string">>}
                }
            }
        },
        <<"properties">> => #{
            <<"name">> => #{<<"type">> => <<"string">>},
            <<"address">> => #{<<"$ref">> => <<"#/$defs/address">>},
            <<"contactMethod">> => #{
                <<"type">> => <<"string">>, <<"enum">> => [<<"phone">>, <<"email">>]
            },
            <<"phone">> => #{<<"type">> => <<"string">>},
            <<"email">> => #{<<"type">> => <<"string">>}
        },
        <<"allOf">> => [
            #{
                <<"anyOf">> => [
                    #{<<"required">> => [<<"phone">>]}, #{<<"required">> => [<<"email">>]}
                ]
            }
        ],
        <<"if">> => #{
            <<"properties">> => #{<<"contactMethod">> => #{<<"const">> => <<"phone">>}},
            <<"required">> => [<<"contactMethod">>]
        },
        <<"then">> => #{<<"required">> => [<<"phone">>]},
        <<"else">> => #{<<"required">> => [<<"email">>]},
        <<"additionalProperties">> => false
    }.

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

case_index(TC) -> case_index(TC, all(), 1).
case_index(TC, [TC | _], N) -> N;
case_index(TC, [_ | Rest], N) -> case_index(TC, Rest, N + 1);
case_index(_TC, [], N) -> N.
