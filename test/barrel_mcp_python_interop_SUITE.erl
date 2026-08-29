%%%-------------------------------------------------------------------
%%% @doc Python interop suite: the wire format between barrel_mcp and
%%% the official Python MCP SDK, in both directions and both protocol
%%% eras.
%%%
%%% The eras need different SDK generations, and they cannot share an
%%% interpreter: v1 speaks the handshake era, v2 speaks 2026-07-28 and
%%% replaced FastMCP with MCPServer. So there are two virtualenvs and
%%% two env vars, `INTEROP_PYTHON' and `INTEROP_PYTHON_MODERN'.
%%%
%%% Cases skip cleanly when their interpreter is unset or missing; the
%%% default `rebar3 ct' loop therefore works without Python installed.
%%%
%%% Run via:
%%%
%%%   make interop-setup        % once
%%%   make interop-test
%%%
%%% which points both vars at their venv and shells out to
%%% `rebar3 ct --suite=test/barrel_mcp_python_interop_SUITE'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_python_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(barrel_mcp_test_helpers, [wait_ready/2]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    python_client_against_erlang_server/1,
    post_only_python_client_against_erlang_server/1,
    erlang_client_against_python_server/1,
    modern_python_client_against_erlang_server/1,
    modern_erlang_client_against_python_server/1,
    modern_erlang_client_drives_input_required/1,
    sse_python_client_against_erlang_server/1,
    stdio_python_client_against_erlang_server/1
]).

%% Tool / resource / prompt handlers exported for the registry.
-export([
    echo_tool/1,
    slow_tool/2,
    trigger_update_tool/1,
    ask_llm_tool/2,
    ask_user_tool/2,
    list_roots_tool/2,
    progress_tool/2,
    structured_tool/1,
    error_tool/1,
    registry_churn_tool/1,
    cancellable_tool/2,
    file_resource/1,
    greeting_resource/1,
    hello_prompt/1,
    echo_completion/2,
    confirm_tool/2,
    touch_tool/1,
    region_tool/1,
    insatiable_tool/2,
    noisy_tool/2,
    gated_prompt/2,
    gated_resource/2
]).

-define(PORT, 22451).
-define(MODERN_PORT, 22452).
-define(SSE_PORT, 22453).
-define(MODERN, <<"2026-07-28">>).

all() ->
    [
        python_client_against_erlang_server,
        post_only_python_client_against_erlang_server,
        erlang_client_against_python_server,
        modern_python_client_against_erlang_server,
        modern_erlang_client_against_python_server,
        modern_erlang_client_drives_input_required,
        sse_python_client_against_erlang_server,
        stdio_python_client_against_erlang_server
    ].

%% The two SDK generations live in separate virtualenvs: v1 speaks the
%% handshake era and v2 replaced FastMCP, so one interpreter cannot run
%% both directions. Each case skips on its own interpreter, and the
%% suite only skips outright when neither is configured.
init_per_suite(Config) ->
    case {interpreter("INTEROP_PYTHON"), interpreter("INTEROP_PYTHON_MODERN")} of
        {undefined, undefined} ->
            {skip, "no INTEROP_PYTHON / INTEROP_PYTHON_MODERN; run `make interop-test`"};
        {Legacy, Modern} ->
            {ok, _} = application:ensure_all_started(barrel_mcp),
            {ok, _} = application:ensure_all_started(hackney),
            ok = barrel_mcp_registry:wait_for_ready(),
            [{python, Legacy}, {python_modern, Modern} | Config]
    end.

end_per_suite(_Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    application:stop(barrel_mcp),
    ok.

init_per_testcase(_TC, Config) -> Config.
end_per_testcase(_TC, _Config) -> ok.

%%====================================================================
%% Direction A — Python client → Erlang server
%%====================================================================

python_client_against_erlang_server(Config) ->
    with_python(python, Config, "INTEROP_PYTHON", fun(Python) ->
        legacy_direction_a(Python)
    end).

%% The same reference client, forbidden its standalone GET stream. A
%% server request then has only the running call's own response stream
%% to travel on, which is what the official runner's client relies on.
post_only_python_client_against_erlang_server(Config) ->
    with_python(python, Config, "INTEROP_PYTHON", fun(Python) ->
        legacy_direction_a(Python, ["--post-only"])
    end).

legacy_direction_a(Python) ->
    legacy_direction_a(Python, []).

legacy_direction_a(Python, Flags) ->
    ok = ensure_fixture(),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => ?PORT,
        session_enabled => true
    }),
    Url = io_lib:format("http://127.0.0.1:~B/mcp", [?PORT]),
    Script = filename:join(["test", "interop", "client.py"]),
    Cwd = root_dir(),
    Args = [Script, lists:flatten(Url) | Flags],
    {Status, Output} = run_python(Python, Args, Cwd),
    case Status of
        0 ->
            true = string:find(Output, "OK") =/= nomatch,
            ok;
        _ ->
            ct:fail({python_client_failed, Status, Output})
    end,
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    cleanup_fixture(),
    ok.

%%====================================================================
%% Direction B — Erlang client → Python server
%%====================================================================

erlang_client_against_python_server(Config) ->
    with_python(python, Config, "INTEROP_PYTHON", fun(Python) ->
        legacy_direction_b(Python)
    end).

legacy_direction_b(Python) ->
    Script = filename:join(["test", "interop", "server.py"]),
    Cwd = root_dir(),
    AbsScript = filename:join(Cwd, Script),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport =>
            {stdio, #{
                command => Python,
                args => [AbsScript]
            }}
    }),
    ok = wait_ready(Pid, 50),

    %% No `protocol_version', so the client probes `server/discover'
    %% first. This SDK predates that method and rejects it, which is
    %% exactly the fallback the probe exists for: the connection lands
    %% on the handshake era. The rejection is logged to the server's
    %% stderr and shows up in this suite's output; that is the SDK
    %% reporting an unknown method, not a failure here.
    ?assertMatch({ok, <<"2025-11-25">>}, barrel_mcp_client:protocol_version(Pid)),

    %% tools/list + tools/call
    {ok, Tools} = barrel_mcp_client:list_tools(Pid),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"echo">>, Names)),
    {ok, Result} = barrel_mcp_client:call_tool(
        Pid,
        <<"echo">>,
        #{<<"text">> => <<"hello">>},
        #{timeout => 10000}
    ),
    [#{<<"text">> := <<"hello">>} | _] = maps:get(<<"content">>, Result),

    %% resources/list + resources/read
    {ok, Resources} = barrel_mcp_client:list_resources(Pid),
    ResUris = [maps:get(<<"uri">>, R) || R <- Resources],
    ?assert(lists:member(<<"mem://greeting">>, ResUris)),
    {ok, ReadRes} = barrel_mcp_client:read_resource(
        Pid, <<"mem://greeting">>
    ),
    [Block | _] = maps:get(<<"contents">>, ReadRes),
    ?assertEqual(<<"hello, world">>, maps:get(<<"text">>, Block)),

    %% prompts/list + prompts/get
    {ok, Prompts} = barrel_mcp_client:list_prompts(Pid),
    PromptNames = [maps:get(<<"name">>, P) || P <- Prompts],
    ?assert(lists:member(<<"hello_prompt">>, PromptNames)),
    {ok, PromptResult} = barrel_mcp_client:get_prompt(
        Pid,
        <<"hello_prompt">>,
        #{<<"who">> => <<"interop">>}
    ),
    [PromptMsg | _] = maps:get(<<"messages">>, PromptResult),
    ?assertEqual(<<"user">>, maps:get(<<"role">>, PromptMsg)),
    %% Python FastMCP wraps the message text under content.text.
    Content = maps:get(<<"content">>, PromptMsg),
    ?assertEqual(<<"hello, interop">>, maps:get(<<"text">>, Content)),

    %% ping
    {ok, _} = barrel_mcp_client:ping(Pid),

    barrel_mcp_client:close(Pid),
    ok.

%%====================================================================
%% Direction A (modern): Python SDK v2 client → Erlang server
%%====================================================================

%% The reference client drives our server with no handshake: it probes
%% `server/discover', then carries its version and capabilities on
%% every request. It also runs a multi round-trip request end to end,
%% which is the only way to see our sealed `requestState' survive a
%% client that treats it as opaque.
modern_python_client_against_erlang_server(Config) ->
    with_python(python_modern, Config, "INTEROP_PYTHON_MODERN", fun(Python) ->
        modern_direction_a(Python)
    end).

%% The transport Streamable HTTP replaced. The SDK opens a GET stream,
%% reads the endpoint out of the first event and posts there; nothing
%% about that endpoint is known in advance, so a client that gets an
%% answer proves the whole handshake.
sse_python_client_against_erlang_server(Config) ->
    with_python(python, Config, "INTEROP_PYTHON", fun(Python) ->
        sse_direction_a(Python)
    end).

sse_direction_a(Python) ->
    ok = ensure_fixture(),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => ?SSE_PORT,
        sse_path => <<"/sse">>,
        sse_message_path => <<"/messages">>
    }),
    Url = lists:flatten(io_lib:format("http://127.0.0.1:~B/sse", [?SSE_PORT])),
    Script = filename:join(["test", "interop", "client_sse.py"]),
    try
        case run_python(Python, [Script, Url], root_dir()) of
            {0, Output} ->
                ?assertNotEqual(nomatch, string:find(Output, "OK"));
            {Status, Output} ->
                ct:fail({sse_python_client_failed, Status, Output})
        end
    after
        try
            barrel_mcp:stop_http_stream()
        catch
            _:_ -> ok
        end,
        cleanup_fixture()
    end,
    ok.

%% The stdio server behind a real OS pipe, driven by a foreign client.
%% The SDK owns the child process, so framing is the only contract
%% between the two ends.
stdio_python_client_against_erlang_server(Config) ->
    with_python(python, Config, "INTEROP_PYTHON", fun(Python) ->
        stdio_direction_a(Python)
    end).

stdio_direction_a(Python) ->
    Script = filename:join(["test", "interop", "client_stdio.py"]),
    Args = [Script, erl_executable() | child_args()],
    case run_python(Python, Args, root_dir()) of
        {0, Output} ->
            ?assertNotEqual(nomatch, string:find(Output, "OK"));
        {Status, Output} ->
            ct:fail({stdio_python_client_failed, Status, Output})
    end.

erl_executable() ->
    filename:join([code:root_dir(), "bin", "erl"]).

%% Logging has to go to stderr: the default handler writes stdout, which
%% is the wire. The paths are reversed because each `-pa' prepends.
child_args() ->
    Dirs = lists:reverse([D || D <- code:get_path(), filelib:is_dir(D)]),
    Paths = lists:append([["-pa", D] || D <- Dirs]),
    [
        "-noshell",
        "-boot",
        "no_dot_erlang",
        "-kernel",
        "logger",
        "[{handler,default,logger_std_h,#{config=>#{type=>standard_error}}}]"
    ] ++ Paths ++
        ["-eval", "barrel_mcp_stdio_child:start()"].

modern_direction_a(Python) ->
    ok = ensure_modern_fixture(),
    {ok, _} = barrel_mcp:start_http_stream(#{port => ?MODERN_PORT}),
    Url = lists:flatten(io_lib:format("http://127.0.0.1:~B/mcp", [?MODERN_PORT])),
    Script = filename:join(["test", "interop", "client_modern.py"]),
    try
        case run_python(Python, [Script, Url], root_dir()) of
            {0, Output} ->
                ?assertNotEqual(nomatch, string:find(Output, "OK"));
            {Status, Output} ->
                ct:fail({modern_python_client_failed, Status, Output})
        end
    after
        try
            barrel_mcp:stop_http_stream()
        catch
            _:_ -> ok
        end,
        cleanup_modern_fixture()
    end,
    ok.

%%====================================================================
%% Direction B (modern): Erlang client → Python SDK v2 server
%%====================================================================

%% `auto' has to find the modern era over stdio, where a handshake-era
%% server would simply not answer the probe.
modern_erlang_client_against_python_server(Config) ->
    with_python(python_modern, Config, "INTEROP_PYTHON_MODERN", fun(Python) ->
        modern_direction_b(Python)
    end).

modern_direction_b(Python) ->
    Script = filename:join(root_dir(), "test/interop/server_modern.py"),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport => {stdio, #{command => Python, args => [Script]}},
        protocol_version => auto,
        probe_timeout => 15000,
        client_info => #{name => <<"barrel-interop">>, version => <<"1.0">>}
    }),
    try
        ok = wait_ready(Pid, 100),
        ?assertEqual({ok, ?MODERN}, barrel_mcp_client:protocol_version(Pid)),

        {ok, Tools} = barrel_mcp_client:list_tools(Pid),
        ?assert(lists:member(<<"echo">>, [maps:get(<<"name">>, T) || T <- Tools])),
        {ok, Result} = barrel_mcp_client:call_tool(
            Pid, <<"echo">>, #{<<"text">> => <<"from erlang">>}, #{timeout => 15000}
        ),
        [#{<<"text">> := <<"from erlang">>} | _] = maps:get(<<"content">>, Result),
        %% Every modern result is stamped, whoever produced it.
        ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),

        {ok, ReadRes} = barrel_mcp_client:read_resource(Pid, <<"mem://greeting">>),
        [Block | _] = maps:get(<<"contents">>, ReadRes),
        ?assertEqual(<<"hello, world">>, maps:get(<<"text">>, Block)),

        %% Removed by this revision, and answered locally rather than
        %% sent to a server that would reject it.
        ?assertMatch({error, {unsupported, <<"ping">>}}, barrel_mcp_client:ping(Pid)),

        %% Subscriptions are deliberately not driven here: this SDK does
        %% not implement `subscriptions/listen' and closes the pipe
        %% rather than answering method-not-found. Both ends of that
        %% exchange are covered in barrel_mcp_stdio_SUITE.
        ok
    after
        try
            barrel_mcp_client:close(Pid)
        catch
            _:_ -> ok
        end
    end,
    ok.

%% Our client's multi round-trip loop against an envelope the reference
%% implementation produced: it has to recognise the InputRequiredResult,
%% route the question to the handler, and re-issue the call with a new
%% id, the answer, and the state echoed back untouched.
modern_erlang_client_drives_input_required(Config) ->
    with_python(python_modern, Config, "INTEROP_PYTHON_MODERN", fun(Python) ->
        modern_direction_b_mrtr(Python)
    end).

modern_direction_b_mrtr(Python) ->
    Script = filename:join(root_dir(), "test/interop/server_modern.py"),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport => {stdio, #{command => Python, args => [Script]}},
        protocol_version => auto,
        probe_timeout => 15000,
        capabilities => #{elicitation => true},
        handler => {barrel_mcp_test_handler, #{mode => sync}},
        client_info => #{name => <<"barrel-interop">>, version => <<"1.0">>}
    }),
    try
        ok = wait_ready(Pid, 100),
        ?assertEqual({ok, ?MODERN}, barrel_mcp_client:protocol_version(Pid)),
        {ok, Result} = barrel_mcp_client:call_tool(
            Pid, <<"greet">>, #{}, #{timeout => 20000}
        ),
        [#{<<"text">> := Text} | _] = maps:get(<<"content">>, Result),
        %% "hello" is the state the server sealed on the first attempt
        %% and read back on the second; "ada" is what our handler
        %% answered in between.
        ?assertEqual(<<"hello, ada">>, Text),
        ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result))
    after
        try
            barrel_mcp_client:close(Pid)
        catch
            _:_ -> ok
        end
    end,
    ok.

%%====================================================================
%% Fixture
%%====================================================================

%% Deliberately small. The handshake-era fixture leans on
%% session-scoped server-to-client calls, which the modern era does not
%% have; `confirm' is their replacement.
ensure_modern_fixture() ->
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo a string">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"text">>],
            <<"properties">> => #{<<"text">> => #{<<"type">> => <<"string">>}}
        }
    }),
    ok = barrel_mcp_registry:reg(tool, <<"touch">>, ?MODULE, touch_tool, #{
        description => <<"Emit a resources/updated notification">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    %% The server rejects a request whose headers disagree with its
    %% body, so a call that succeeds proves the reference client
    %% encoded the mirrored argument exactly as we decode it.
    ok = barrel_mcp_registry:reg(tool, <<"regional">>, ?MODULE, region_tool, #{
        description => <<"Mirrors its region argument into a header">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"region">> => #{
                    <<"type">> => <<"string">>,
                    <<"x-mcp-header">> => <<"Region">>
                }
            }
        }
    }),
    ok = barrel_mcp_registry:reg(tool, <<"insatiable">>, ?MODULE, insatiable_tool, #{
        description => <<"Never satisfied">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    ok = barrel_mcp_registry:reg(tool, <<"progress">>, ?MODULE, progress_tool, #{
        description => <<"Emits three progress notifications">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    ok = barrel_mcp_registry:reg(tool, <<"noisy">>, ?MODULE, noisy_tool, #{
        description => <<"Logs at info and debug">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    _ = [
        barrel_mcp_registry:reg(
            tool,
            iolist_to_binary(io_lib:format("filler_~2..0B", [N])),
            ?MODULE,
            echo_tool,
            #{
                description => <<"Padding, so tools/list needs more than one page">>,
                input_schema => #{<<"type">> => <<"object">>}
            }
        )
     || N <- lists:seq(1, 60)
    ],
    ok = barrel_mcp_registry:reg(prompt, <<"gated">>, ?MODULE, gated_prompt, #{
        description => <<"Asks who to greet before rendering">>
    }),
    ok = barrel_mcp_registry:reg(resource, <<"gated_res">>, ?MODULE, gated_resource, #{
        name => <<"Gated">>,
        uri => <<"mem://gated">>,
        mime_type => <<"text/plain">>
    }),
    ok = barrel_mcp_registry:reg(tool, <<"confirm">>, ?MODULE, confirm_tool, #{
        description => <<"Asks the client who to greet">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    ok = barrel_mcp_registry:reg(resource, <<"greeting">>, ?MODULE, greeting_resource, #{
        name => <<"Greeting">>,
        uri => <<"mem://greeting">>,
        mime_type => <<"text/plain">>
    }),
    ok = barrel_mcp_registry:reg(prompt, <<"hello_prompt">>, ?MODULE, hello_prompt, #{
        description => <<"Greet a user">>,
        arguments => [#{name => <<"who">>, required => false}]
    }),
    ok.

cleanup_modern_fixture() ->
    _ = [
        try
            barrel_mcp_registry:unreg(Kind, Name)
        catch
            _:_ -> ok
        end
     || {Kind, Name} <-
            [
                {tool, <<"echo">>},
                {tool, <<"confirm">>},
                {tool, <<"touch">>},
                {tool, <<"regional">>},
                {tool, <<"insatiable">>},
                {tool, <<"progress">>},
                {tool, <<"noisy">>},
                {resource, <<"greeting">>},
                {resource, <<"gated_res">>},
                {prompt, <<"hello_prompt">>},
                {prompt, <<"gated">>}
            ] ++
                [
                    {tool, iolist_to_binary(io_lib:format("filler_~2..0B", [N]))}
                 || N <- lists:seq(1, 60)
                ]
    ],
    ok.

%% Drives the subscription stream: the reference client opens
%% `subscriptions/listen', calls this, and must see the event.
touch_tool(_Args) ->
    ok = barrel_mcp:notify_resource_updated(<<"mem://greeting">>),
    <<"touched">>.

%% Mirrored into `Mcp-Param-Region'. Echoing the value back lets the
%% client check the round trip as well as the header agreeing.
region_tool(Args) ->
    maps:get(<<"region">>, Args, <<"unset">>).

%% Asks again whatever it is told, so the client's own round cap is the
%% only thing that ends the exchange.
insatiable_tool(_Args, _Ctx) ->
    ask_for_a_name(<<"Again?">>).

%% Prompts and resources ask on the same terms a tool does.
gated_prompt(_Args, Ctx) ->
    case barrel_mcp:input(Ctx, <<"who">>) of
        none ->
            ask_for_a_name(<<"Who should I greet?">>);
        {ok, Response} ->
            {ok, Salutation} = barrel_mcp:request_state(Ctx),
            #{
                description => <<"Greeting">>,
                messages => [
                    #{
                        <<"role">> => <<"user">>,
                        <<"content">> => #{
                            <<"type">> => <<"text">>,
                            <<"text">> =>
                                <<Salutation/binary, ", ", (answered_name(Response))/binary>>
                        }
                    }
                ]
            }
    end.

gated_resource(_Args, Ctx) ->
    case barrel_mcp:input(Ctx, <<"who">>) of
        none ->
            ask_for_a_name(<<"Whose file?">>);
        {ok, Response} ->
            {ok, Prefix} = barrel_mcp:request_state(Ctx),
            <<Prefix/binary, "/", (answered_name(Response))/binary>>
    end.

answered_name(Response) ->
    Content = maps:get(<<"content">>, Response, #{}),
    maps:get(<<"name">>, Content, <<"nobody">>).

ask_for_a_name(Message) ->
    {input_required,
        #{
            <<"who">> => #{
                method => <<"elicitation/create">>,
                params => #{
                    <<"mode">> => <<"form">>,
                    <<"message">> => Message,
                    <<"requestedSchema">> => #{
                        <<"type">> => <<"object">>,
                        <<"properties">> => #{
                            <<"name">> => #{<<"type">> => <<"string">>}
                        }
                    }
                }
            }
        },
        <<"hello">>}.

%% Multi round-trip: ask on the first attempt, answer on the second.
%% The handler runs from the top each time, so what it knew has to come
%% back through the sealed state rather than from memory.
confirm_tool(_Args, Ctx) ->
    case barrel_mcp:input(Ctx, <<"who">>) of
        none ->
            {input_required,
                #{
                    <<"who">> => #{
                        method => <<"elicitation/create">>,
                        params => #{
                            <<"message">> => <<"Who should I greet?">>,
                            <<"requestedSchema">> => #{
                                <<"type">> => <<"object">>,
                                <<"properties">> => #{
                                    <<"name">> => #{<<"type">> => <<"string">>}
                                }
                            }
                        }
                    }
                },
                <<"seed">>};
        {ok, Response} ->
            {ok, Seed} = barrel_mcp:request_state(Ctx),
            Content = maps:get(<<"content">>, Response, #{}),
            Name = maps:get(<<"name">>, Content, <<"nobody">>),
            <<"hello ", Name/binary, " (", Seed/binary, ")">>
    end.

ensure_fixture() ->
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo a string">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"text">>],
            <<"properties">> =>
                #{<<"text">> => #{<<"type">> => <<"string">>}}
        }
    }),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"slow_echo">>,
        ?MODULE,
        slow_tool,
        #{
            description => <<"Long-running echo (returns a taskId)">>,
            long_running => true,
            input_schema => #{
                <<"type">> => <<"object">>,
                <<"properties">> =>
                    #{<<"text">> => #{<<"type">> => <<"string">>}}
            }
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"trigger_update">>,
        ?MODULE,
        trigger_update_tool,
        #{
            description => <<"Push notifications/resources/updated for the greeting URI">>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"ask_llm">>,
        ?MODULE,
        ask_llm_tool,
        #{
            description => <<"Ask the connected client to sample a message">>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"ask_user">>,
        ?MODULE,
        ask_user_tool,
        #{
            description => <<"Ask the connected client to elicit user input">>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"list_roots">>,
        ?MODULE,
        list_roots_tool,
        #{
            description => <<"Ask the connected client for its roots">>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"progress_echo">>,
        ?MODULE,
        progress_tool,
        #{
            description => <<"Emit a few progress events then return">>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"structured">>,
        ?MODULE,
        structured_tool,
        #{
            description => <<"Return structuredContent">>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"erroring">>,
        ?MODULE,
        error_tool,
        #{
            description => <<"Return isError: true">>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"churn_registry">>,
        ?MODULE,
        registry_churn_tool,
        #{
            description => <<
                "Register and unregister a tool, "
                "emitting list_changed"
            >>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        tool,
        <<"cancellable">>,
        ?MODULE,
        cancellable_tool,
        #{
            description => <<"Long-running tool that observes cancel">>,
            long_running => true,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    ok = barrel_mcp_registry:reg(
        resource_template,
        <<"file_template">>,
        ?MODULE,
        file_resource,
        #{
            name => <<"File">>,
            uri_template => <<"file:///{path}">>,
            description => <<"File resource template">>,
            mime_type => <<"text/plain">>
        }
    ),
    ok = barrel_mcp:reg_completion(
        {prompt, <<"hello_prompt">>, <<"who">>},
        ?MODULE,
        echo_completion,
        #{}
    ),
    %% Register enough dummy tools to force multi-page behaviour
    %% on tools/list (the server paginates at 50 entries per page).
    [
        ok = barrel_mcp_registry:reg(
            tool,
            iolist_to_binary(
                io_lib:format(
                    "dummy_~3..0B", [N]
                )
            ),
            ?MODULE,
            echo_tool,
            #{
                description => <<"dummy">>,
                input_schema => #{<<"type">> => <<"object">>}
            }
        )
     || N <- lists:seq(1, 60)
    ],
    ok = barrel_mcp_registry:reg(
        resource,
        <<"greeting">>,
        ?MODULE,
        greeting_resource,
        #{
            name => <<"Greeting">>,
            uri => <<"mem://greeting">>,
            description => <<"Sample greeting resource">>,
            mime_type => <<"text/plain">>
        }
    ),
    ok = barrel_mcp_registry:reg(
        prompt,
        <<"hello_prompt">>,
        ?MODULE,
        hello_prompt,
        #{
            description => <<"Greet a user">>,
            arguments => [#{name => <<"who">>, required => false}]
        }
    ),
    ok.

cleanup_fixture() ->
    try
        barrel_mcp_registry:unreg(tool, <<"echo">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"slow_echo">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"trigger_update">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"ask_llm">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"ask_user">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"list_roots">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"progress_echo">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"structured">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"erroring">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"churn_registry">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"cancellable">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"churned">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(resource, <<"greeting">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(resource_template, <<"file_template">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(prompt, <<"hello_prompt">>)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp:unreg_completion({prompt, <<"hello_prompt">>, <<"who">>})
    catch
        _:_ -> ok
    end,
    [
        try
            barrel_mcp_registry:unreg(
                tool,
                iolist_to_binary(io_lib:format("dummy_~3..0B", [N]))
            )
        catch
            _:_ -> ok
        end
     || N <- lists:seq(1, 60)
    ],
    ok.

echo_tool(#{<<"text">> := T}) -> T.

trigger_update_tool(_) ->
    ok = barrel_mcp:notify_resource_updated(<<"mem://greeting">>),
    <<"triggered">>.

%% Ask the only sampling-capable session for a message and return
%% the text. Mirrors examples/sampling_host's ask_sampler/1.
ask_llm_tool(_, Ctx) ->
    [SessionId | _] = barrel_mcp:list_sessions_with_sampling(),
    Params = #{
        <<"messages">> =>
            [
                #{
                    <<"role">> => <<"user">>,
                    <<"content">> => #{
                        <<"type">> => <<"text">>,
                        <<"text">> => <<"hi">>
                    }
                }
            ],
        <<"maxTokens">> => 32
    },
    {ok, Result, _Usage} =
        barrel_mcp:sampling_create_message(
            SessionId,
            Params,
            ask_opts(Ctx)
        ),
    maps:get(<<"text">>, maps:get(<<"content">>, Result)).

%% The running call's own stream when it has one, else the session's
%% GET stream. A client that never opens the GET stream needs the first.
ask_opts(Ctx) ->
    #{timeout_ms => 5000, channel => maps:get(channel, Ctx, undefined)}.

%% Ask the only elicitation-capable session for a structured
%% answer and return what the user picked. Form-mode payload
%% per the spec.
ask_user_tool(_, Ctx) ->
    [SessionId | _] = barrel_mcp:list_sessions_with_elicitation(),
    Params = #{
        <<"mode">> => <<"form">>,
        <<"message">> => <<"Pick a colour">>,
        <<"requestedSchema">> =>
            #{
                <<"type">> => <<"object">>,
                <<"properties">> =>
                    #{
                        <<"colour">> =>
                            #{<<"type">> => <<"string">>}
                    }
            }
    },
    {ok, Result} = barrel_mcp:elicit_create(SessionId, Params, ask_opts(Ctx)),
    %% The Python callback returns action=accept,
    %% content={"colour": "blue"}. Surface the colour as text.
    Content = maps:get(<<"content">>, Result, #{}),
    maps:get(<<"colour">>, Content, <<"unset">>).

%% Ask the only roots-capable session for its roots and return the
%% first root's name (so we have a deterministic string to assert on).
list_roots_tool(_, Ctx) ->
    [SessionId | _] = barrel_mcp:list_sessions_with_roots(),
    {ok, Roots} = barrel_mcp:roots_list(SessionId, ask_opts(Ctx)),
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
    Emit(1, 3, undefined),
    timer:sleep(50),
    Emit(2, 3, undefined),
    timer:sleep(50),
    Emit(3, 3, undefined),
    timer:sleep(50),
    <<"progressed">>.

%% Modern logging is per-request opt-in, so a client that never named a
%% level gets nothing from this.
noisy_tool(_Args, Ctx) ->
    ok = barrel_mcp:log(Ctx, info, <<"interop">>, <<"loud">>),
    ok = barrel_mcp:log(Ctx, debug, <<"interop">>, <<"quiet">>),
    <<"logged">>.

%% Returns structuredContent on the wire.
structured_tool(_) ->
    Data = #{<<"answer">> => 42, <<"label">> => <<"meaning">>},
    Content = [
        #{
            <<"type">> => <<"text">>,
            <<"text">> => <<"answer is 42">>
        }
    ],
    {structured, Data, Content}.

%% Returns isError: true on the wire.
error_tool(_) ->
    {tool_error, [
        #{
            <<"type">> => <<"text">>,
            <<"text">> => <<"intentional failure">>
        }
    ]}.

%% Triggers a tools/list_changed notification by registering and
%% then unregistering a tool.
registry_churn_tool(_) ->
    ok = barrel_mcp_registry:reg(
        tool,
        <<"churned">>,
        ?MODULE,
        echo_tool,
        #{
            description => <<"Transient tool registered to test list_changed">>,
            input_schema => #{<<"type">> => <<"object">>}
        }
    ),
    timer:sleep(20),
    try
        barrel_mcp_registry:unreg(tool, <<"churned">>)
    catch
        _:_ -> ok
    end,
    <<"churned">>.

%% Cooperative cancel: arity-2 worker watches its mailbox for
%% {cancel, RequestId} from notifications/cancelled.
cancellable_tool(_Args, Ctx) ->
    ReqId = maps:get(request_id, Ctx),
    cancellable_loop(ReqId).

cancellable_loop(ReqId) ->
    receive
        {cancel, ReqId} ->
            {tool_error, [
                #{
                    <<"type">> => <<"text">>,
                    <<"text">> => <<"cancelled">>
                }
            ]}
    after 50 ->
        cancellable_loop(ReqId)
    end.

%% Resource template handler: now that resources/read does
%% RFC 6570 expansion, we receive the substituted `path' under
%% Args and echo it so the interop test can assert on it.
file_resource(Args) ->
    Path = maps:get(<<"path">>, Args, <<"unset">>),
    iolist_to_binary([<<"path=">>, Path]).

%% Completion handler: returns a single canned suggestion derived
%% from the partial value the user typed.
echo_completion(_PartialValue, _Ctx) ->
    {ok, [<<"world">>, <<"world!">>]}.

%% Long-running arity-2 handler. Sleeps briefly then echoes back so
%% the Python client can see the task transition through `working' →
%% `completed'.
slow_tool(Args, _Ctx) ->
    timer:sleep(100),
    maps:get(<<"text">>, Args, <<"slow">>).

greeting_resource(_) -> <<"hello, world">>.

hello_prompt(Args) ->
    Who = maps:get(<<"who">>, Args, <<"world">>),
    #{
        description => <<"Greet">>,
        messages => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => #{
                    <<"type">> => <<"text">>,
                    <<"text">> =>
                        iolist_to_binary(
                            [<<"hello, ">>, Who]
                        )
                }
            }
        ]
    }.

%%====================================================================
%% Helpers
%%====================================================================

%% An interpreter that exists, or `undefined'. A configured path that
%% is not there is the same as none: the case skips rather than failing
%% on a half-finished `make interop-setup'.
interpreter(Var) ->
    case os:getenv(Var) of
        false ->
            undefined;
        Python ->
            case filelib:is_regular(Python) of
                true -> Python;
                false -> undefined
            end
    end.

%% Run `Fun' with the interpreter, or skip the case. Returning
%% `{skip, _}' is how a case skips itself at run time; it cannot be
%% done from inside `Fun'.
with_python(Key, Config, Var, Fun) ->
    case ?config(Key, Config) of
        undefined -> {skip, Var ++ " not set; run `make interop-test`"};
        Python -> Fun(Python)
    end.

root_dir() ->
    %% CT runs from a deep _build directory; resolve to the project
    %% root so `test/interop/...' paths work.
    {ok, Cwd} = file:get_cwd(),
    find_root(Cwd).

find_root(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true ->
            Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                %% reached fs root, give up
                Dir -> Dir;
                _ -> find_root(Parent)
            end
    end.

run_python(Python, Args, Cwd) ->
    Port = open_port(
        {spawn_executable, Python},
        [
            {args, Args},
            {cd, Cwd},
            exit_status,
            stderr_to_stdout,
            use_stdio,
            binary,
            {line, 4096}
        ]
    ),
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
        try
            port_close(Port)
        catch
            _:_ -> ok
        end,
        {timeout, lists:flatten(lists:reverse(Acc))}
    end.
