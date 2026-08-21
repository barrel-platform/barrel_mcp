%%%-------------------------------------------------------------------
%%% @doc The client speaking 2026-07-28 against our own server.
%%%
%%% Both ends of the wire are under test here, which is the point: the
%%% server rejects a request whose headers disagree with its body, so
%%% anything the client builds wrongly fails loudly rather than being
%%% quietly tolerated.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_modern_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    connects_without_handshake/1,
    mints_no_session/1,
    tools_round_trip/1,
    resources_and_prompts/1,
    caller_progress_token_survives/1,
    unknown_version_is_refused/1,
    legacy_pin_still_handshakes/1,
    auto_probes_into_modern/1,
    auto_falls_back_to_handshake/1,
    auto_retries_on_version_error/1,
    auto_gives_up_after_one_retry/1,
    auto_falls_back_when_no_version_is_mutual/1,
    auto_is_the_default/1,
    mrtr_round_trip/1,
    mrtr_async_handler/1,
    mrtr_bounded_rounds/1,
    mrtr_shares_one_deadline/1,
    removed_methods_are_refused/1,
    tasks_extension_methods/1,
    ping_cadence_is_off/1,
    subscribe_receives_resource_updates/1,
    unsubscribe_stops_updates/1,
    mirrors_tool_parameters/1,
    excludes_tools_with_bad_annotations/1
]).

-export([echo_tool/1, a_resource/1, a_prompt/1, legacy_only_server/1]).
-export([version_error_server/1]).
-export([confirm_tool/2, insatiable_tool/2, region_tool/1]).

-define(BASE_PORT, 22000).
-define(MODERN, <<"2026-07-28">>).

all() ->
    [
        connects_without_handshake,
        mints_no_session,
        tools_round_trip,
        resources_and_prompts,
        caller_progress_token_survives,
        unknown_version_is_refused,
        legacy_pin_still_handshakes,
        auto_probes_into_modern,
        auto_falls_back_to_handshake,
        auto_retries_on_version_error,
        auto_gives_up_after_one_retry,
        auto_falls_back_when_no_version_is_mutual,
        auto_is_the_default,
        mrtr_round_trip,
        mrtr_async_handler,
        mrtr_bounded_rounds,
        mrtr_shares_one_deadline,
        removed_methods_are_refused,
        tasks_extension_methods,
        ping_cadence_is_off,
        subscribe_receives_resource_updates,
        unsubscribe_stops_updates,
        mirrors_tool_parameters,
        excludes_tools_with_bad_annotations
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echoes its input">>
    }),
    ok = barrel_mcp:reg_tool(<<"confirm">>, ?MODULE, confirm_tool, #{
        description => <<"Asks the client to confirm">>
    }),
    ok = barrel_mcp:reg_tool(<<"insatiable">>, ?MODULE, insatiable_tool, #{
        description => <<"Never satisfied">>
    }),
    ok = barrel_mcp:reg_tool(<<"regional">>, ?MODULE, region_tool, #{
        description => <<"Mirrors its region argument into a header">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"region">> => #{
                    <<"type">> => <<"string">>,
                    <<"x-mcp-header">> => <<"Region">>
                },
                <<"query">> => #{<<"type">> => <<"string">>}
            }
        }
    }),
    ok = barrel_mcp:reg_resource(<<"res">>, ?MODULE, a_resource, #{
        uri => <<"file:///present">>
    }),
    ok = barrel_mcp:reg_prompt(<<"greet">>, ?MODULE, a_prompt, #{
        description => <<"A greeting">>
    }),
    Config.

end_per_suite(_Config) ->
    barrel_mcp_registry:unreg(tool, <<"echo">>),
    barrel_mcp_registry:unreg(tool, <<"confirm">>),
    barrel_mcp_registry:unreg(tool, <<"insatiable">>),
    barrel_mcp_registry:unreg(tool, <<"regional">>),
    barrel_mcp_registry:unreg(resource, <<"res">>),
    barrel_mcp_registry:unreg(prompt, <<"greet">>),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(TC, Config) ->
    Port = ?BASE_PORT + case_index(TC),
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true,
        %% A dropped subscriber is noticed on the next write, so keep
        %% the stream chatty enough for the lifecycle cases to observe
        %% it without waiting out the default interval.
        subscription_keepalive_ms => 200
    }),
    [{port, Port} | Config].

end_per_testcase(_TC, Config) ->
    case ?config(client, Config) of
        undefined -> ok;
        Pid -> catch_close(Pid)
    end,
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    timer:sleep(50),
    ok.

echo_tool(Args) ->
    <<"Echo: ", (maps:get(<<"input">>, Args, <<"none">>))/binary>>.

a_resource(_Args) -> <<"resource body">>.

region_tool(Args) ->
    maps:get(<<"region">>, Args, <<"none">>).

%% Asks once, then completes with whatever came back.
confirm_tool(_Args, Ctx) ->
    case barrel_mcp:input(Ctx, <<"who">>) of
        {ok, #{<<"content">> := #{<<"name">> := Name}}} ->
            <<"hello ", Name/binary>>;
        _ ->
            {input_required,
                #{
                    <<"who">> => #{
                        method => <<"elicitation/create">>,
                        params => #{<<"message">> => <<"Your name?">>}
                    }
                },
                asked}
    end.

%% Asks again every time, so the client's own bound is what stops it.
insatiable_tool(_Args, _Ctx) ->
    {input_required,
        #{
            <<"who">> => #{
                method => <<"elicitation/create">>,
                params => #{<<"message">> => <<"Again?">>}
            }
        },
        asked}.

a_prompt(_Args) ->
    #{
        description => <<"A greeting">>,
        messages => [
            #{
                role => <<"user">>,
                content => #{type => <<"text">>, text => <<"hello">>}
            }
        ]
    }.

%%====================================================================
%% Cases
%%====================================================================

connects_without_handshake(Config) ->
    Client = connect(Config, ?MODERN),
    ?assertEqual({ok, ?MODERN}, barrel_mcp_client:protocol_version(Client)),
    %% Identity came from server/discover, not from an initialize.
    {ok, Info} = barrel_mcp_client:server_info(Client),
    ?assertEqual(<<"barrel">>, maps:get(<<"name">>, Info)),
    {ok, Caps} = barrel_mcp_client:server_capabilities(Client),
    ?assert(maps:is_key(<<"tools">>, Caps)),
    %% The modern capability set, not the handshake one.
    ?assertNot(maps:is_key(<<"logging">>, Caps)),
    close(Client).

%% The whole point of the era: no session is created for any of this.
mints_no_session(Config) ->
    Before = length(barrel_mcp_session:list()),
    Client = connect(Config, ?MODERN),
    {ok, _} = barrel_mcp_client:list_tools(Client),
    {ok, _} = barrel_mcp_client:list_tools(Client),
    ?assertEqual(Before, length(barrel_mcp_session:list())),
    close(Client).

tools_round_trip(Config) ->
    Client = connect(Config, ?MODERN),
    {ok, Tools} = barrel_mcp_client:list_tools(Client),
    ?assert(lists:any(fun(T) -> maps:get(<<"name">>, T) =:= <<"echo">> end, Tools)),
    {ok, Result} = barrel_mcp_client:call_tool(Client, <<"echo">>, #{
        <<"input">> => <<"hi">>
    }),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"Echo: hi">>, maps:get(<<"text">>, Block)),
    %% The server decorated it, so the client is genuinely on the
    %% modern path rather than being served leniently.
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    close(Client).

%% resources/read and prompts/get carry Mcp-Name from different body
%% fields, so both are worth driving.
resources_and_prompts(Config) ->
    Client = connect(Config, ?MODERN),
    {ok, Read} = barrel_mcp_client:read_resource(Client, <<"file:///present">>),
    [Content] = maps:get(<<"contents">>, Read),
    ?assertEqual(<<"resource body">>, maps:get(<<"text">>, Content)),
    {ok, Prompt} = barrel_mcp_client:get_prompt(Client, <<"greet">>, #{}),
    ?assertEqual(<<"A greeting">>, maps:get(<<"description">>, Prompt)),
    close(Client).

%% The protocol fields are merged into `_meta', not substituted for it,
%% or a caller's progress token would be dropped.
caller_progress_token_survives(Config) ->
    Client = connect(Config, ?MODERN),
    {ok, Result} = barrel_mcp_client:call_tool(
        Client,
        <<"echo">>,
        #{<<"input">> => <<"tok">>},
        #{progress_token => <<"t-1">>}
    ),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"Echo: tok">>, maps:get(<<"text">>, Block)),
    close(Client).

%% Pinning a revision this release does not implement is refused at
%% start rather than quietly opening a handshake and settling for
%% whatever the server offers instead.
unknown_version_is_refused(Config) ->
    Port = ?config(port, Config),
    ?assertEqual(
        {error, {unsupported_protocol_version, <<"2027-01-01">>}},
        barrel_mcp_client:start(#{
            transport => {http, url(Port)},
            protocol_version => <<"2027-01-01">>
        })
    ),
    %% Every revision the library does implement is still accepted.
    lists:foreach(
        fun(V) ->
            Client = connect(Config, V),
            ?assertMatch({ok, _}, barrel_mcp_client:protocol_version(Client)),
            close(Client)
        end,
        barrel_mcp_version:all()
    ),
    ok.

%% Pinning a legacy revision must behave exactly as before: a
%% handshake, a session, and no metadata headers.
legacy_pin_still_handshakes(Config) ->
    Before = length(barrel_mcp_session:list()),
    Client = connect(Config, <<"2025-11-25">>),
    ?assertEqual({ok, <<"2025-11-25">>}, barrel_mcp_client:protocol_version(Client)),
    {ok, Caps} = barrel_mcp_client:server_capabilities(Client),
    ?assert(maps:is_key(<<"logging">>, Caps)),
    {ok, Result} = barrel_mcp_client:call_tool(Client, <<"echo">>, #{
        <<"input">> => <<"legacy">>
    }),
    ?assertNot(maps:is_key(<<"resultType">>, Result)),
    ?assertEqual(Before + 1, length(barrel_mcp_session:list())),
    close(Client).

%%====================================================================
%% Auto probing
%%====================================================================

auto_probes_into_modern(Config) ->
    Client = connect(Config, auto),
    ?assertEqual({ok, ?MODERN}, barrel_mcp_client:protocol_version(Client)),
    {ok, Result} = barrel_mcp_client:call_tool(Client, <<"echo">>, #{
        <<"input">> => <<"probed">>
    }),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    close(Client).

%% A server that does not answer server/discover is a handshake-era
%% one, whatever error it picks. Our own server answers it in both
%% eras, so proving the fallback needs a server that does not: this one
%% returns method-not-found, exactly as a pre-2026 implementation does.
auto_falls_back_to_handshake(Config) ->
    Port = ?config(port, Config) + 500,
    {ok, _} = barrel_mcp_test_http:start(
        legacy_mock, Port, fun ?MODULE:legacy_only_server/1
    ),
    try
        Client = connect_url(auto, url(Port)),
        %% Fell back and completed the handshake on the version that
        %% server offered.
        ?assertEqual({ok, <<"2025-11-25">>}, barrel_mcp_client:protocol_version(Client)),
        {ok, Info} = barrel_mcp_client:server_info(Client),
        ?assertEqual(<<"legacy-only">>, maps:get(<<"name">>, Info)),
        close(Client)
    after
        barrel_mcp_test_http:stop(legacy_mock)
    end.

%% A server from before 2026-07-28: it has never heard of
%% server/discover and says so.
legacy_only_server(#{body := Body}) ->
    Request = json:decode(Body),
    Id = maps:get(<<"id">>, Request, null),
    Response =
        case maps:get(<<"method">>, Request, undefined) of
            <<"server/discover">> ->
                #{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"id">> => Id,
                    <<"error">> => #{
                        <<"code">> => -32601,
                        <<"message">> => <<"Method not found">>
                    }
                };
            <<"initialize">> ->
                #{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"id">> => Id,
                    <<"result">> => #{
                        <<"protocolVersion">> => <<"2025-11-25">>,
                        <<"capabilities">> => #{<<"tools">> => #{}},
                        <<"serverInfo">> => #{
                            <<"name">> => <<"legacy-only">>,
                            <<"version">> => <<"1.0">>
                        }
                    }
                };
            _ ->
                #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => #{}}
        end,
    {200, #{<<"content-type">> => <<"application/json">>}, iolist_to_binary(json:encode(Response))}.

%% -32022 is the one error that proves the server is modern: it
%% understood the probe. Falling back to a handshake it does not have
%% would strand the connection, so the client retries with what the
%% error offered.
auto_retries_on_version_error(Config) ->
    Port = ?config(port, Config) + 500,
    Counter = counters:new(1, []),
    persistent_term:put({?MODULE, discovers}, Counter),
    {ok, _} = barrel_mcp_test_http:start(
        version_mock, Port, fun ?MODULE:version_error_server/1
    ),
    try
        Client = connect_url(auto, url(Port)),
        ?assertEqual({ok, ?MODERN}, barrel_mcp_client:protocol_version(Client)),
        {ok, Info} = barrel_mcp_client:server_info(Client),
        ?assertEqual(<<"version-fussy">>, maps:get(<<"name">>, Info)),
        %% Rejected once, answered on the retry.
        ?assertEqual(2, counters:get(Counter, 1)),
        close(Client)
    after
        barrel_mcp_test_http:stop(version_mock),
        persistent_term:erase({?MODULE, discovers})
    end.

%% A server that rejects the revision it just advertised has nothing
%% left to offer, so the retry has to be bounded or the two of them
%% trade the same version forever.
auto_gives_up_after_one_retry(Config) ->
    Port = ?config(port, Config) + 501,
    Counter = counters:new(1, []),
    %% 999 keeps every discover on the rejecting branch.
    persistent_term:put({?MODULE, discovers}, Counter),
    counters:add(Counter, 1, 999),
    {ok, _} = barrel_mcp_test_http:start(
        version_mock2, Port, fun ?MODULE:version_error_server/1
    ),
    try
        {ok, Pid} = barrel_mcp_client:start(#{
            transport => {http, url(Port)},
            probe_timeout => 1000
        }),
        %% It falls back to the handshake, which this server answers,
        %% so it lands legacy rather than spinning on the probe.
        wait_until(fun() -> is_ready(Pid) end, 8000),
        ?assertEqual({ok, <<"2025-11-25">>}, barrel_mcp_client:protocol_version(Pid)),
        %% 999 seeded, plus the probe and exactly one retry.
        ?assertEqual(1001, counters:get(Counter, 1)),
        close(Pid)
    after
        barrel_mcp_test_http:stop(version_mock2),
        persistent_term:erase({?MODULE, discovers})
    end.

%% Offered only revisions we do not implement, there is nothing to
%% retry with, so the handshake is the remaining option.
auto_falls_back_when_no_version_is_mutual(Config) ->
    Port = ?config(port, Config) + 502,
    Counter = counters:new(1, []),
    %% 500 selects the branch offering a revision we never heard of.
    persistent_term:put({?MODULE, discovers}, Counter),
    counters:add(Counter, 1, 500),
    {ok, _} = barrel_mcp_test_http:start(
        version_mock3, Port, fun ?MODULE:version_error_server/1
    ),
    try
        Client = connect_url(auto, url(Port)),
        ?assertEqual({ok, <<"2025-11-25">>}, barrel_mcp_client:protocol_version(Client)),
        %% Rejected once and never retried: nothing offered was usable.
        ?assertEqual(501, counters:get(Counter, 1)),
        close(Client)
    after
        barrel_mcp_test_http:stop(version_mock3),
        persistent_term:erase({?MODULE, discovers})
    end.

%% A modern server that is particular about revisions. The counter
%% picks the branch so one server covers retry, exhaustion, and an
%% offer we cannot use.
version_error_server(#{body := Body}) ->
    Request = json:decode(Body),
    Id = maps:get(<<"id">>, Request, null),
    Counter = persistent_term:get({?MODULE, discovers}),
    Response =
        case maps:get(<<"method">>, Request, undefined) of
            <<"server/discover">> ->
                N = counters:get(Counter, 1),
                counters:add(Counter, 1, 1),
                discover_reply(Id, N);
            <<"initialize">> ->
                #{
                    <<"jsonrpc">> => <<"2.0">>,
                    <<"id">> => Id,
                    <<"result">> => #{
                        <<"protocolVersion">> => <<"2025-11-25">>,
                        <<"capabilities">> => #{<<"tools">> => #{}},
                        <<"serverInfo">> => #{
                            <<"name">> => <<"version-fussy">>,
                            <<"version">> => <<"1.0">>
                        }
                    }
                };
            _ ->
                #{<<"jsonrpc">> => <<"2.0">>, <<"id">> => Id, <<"result">> => #{}}
        end,
    {200, #{<<"content-type">> => <<"application/json">>}, iolist_to_binary(json:encode(Response))}.

%% 0 rejects then accepts; >= 999 always rejects; >= 500 offers a
%% revision no client implements.
discover_reply(Id, 0) ->
    version_error(Id, [?MODERN]);
discover_reply(Id, N) when N >= 999 ->
    version_error(Id, [?MODERN]);
discover_reply(Id, N) when N >= 500 ->
    version_error(Id, [<<"2099-01-01">>]);
discover_reply(Id, _N) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => #{
            <<"supportedVersions">> => [?MODERN],
            <<"capabilities">> => #{<<"tools">> => #{}},
            <<"_meta">> => #{
                ?MCP_META_SERVER_INFO => #{
                    <<"name">> => <<"version-fussy">>,
                    <<"version">> => <<"1.0">>
                }
            }
        }
    }.

version_error(Id, Supported) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => #{
            <<"code">> => ?MCP_UNSUPPORTED_PROTOCOL_VERSION,
            <<"message">> => <<"Unsupported protocol version">>,
            <<"data">> => #{
                <<"supported">> => Supported,
                <<"requested">> => ?MODERN
            }
        }
    }.

%% The default changed in 3.0: a spec that names no version probes
%% rather than assuming the handshake.
auto_is_the_default(Config) ->
    Port = ?config(port, Config),
    {ok, Pid} = barrel_mcp_client:start(#{transport => {http, url(Port)}}),
    wait_until(fun() -> is_ready(Pid) end, 5000),
    ?assertEqual({ok, ?MODERN}, barrel_mcp_client:protocol_version(Pid)),
    close(Pid).

%%====================================================================
%% Multi round-trip requests
%%====================================================================

%% The caller sees one call. Underneath it is two requests with
%% different ids, with the handler answering in between.
mrtr_round_trip(Config) ->
    Client = connect_with(Config, #{mode => sync}),
    {ok, Result} = barrel_mcp_client:call_tool(Client, <<"confirm">>, #{}),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"hello ada">>, maps:get(<<"text">>, Block)),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    close(Client).

%% A handler that defers holds the round open until reply_async/3
%% arrives, rather than retrying with a missing answer.
mrtr_async_handler(Config) ->
    Caller = self(),
    Client = connect_with(Config, #{mode => async, owner => Caller}),
    spawn(fun() ->
        Caller ! {result, barrel_mcp_client:call_tool(Client, <<"confirm">>, #{})}
    end),
    Tag =
        receive
            {deferred, T} -> T
        after 5000 -> error(handler_never_called)
        end,
    ok = barrel_mcp_client:reply_async(Client, Tag, #{
        <<"action">> => <<"accept">>,
        <<"content">> => #{<<"name">> => <<"grace">>}
    }),
    receive
        {result, {ok, Result}} ->
            [Block] = maps:get(<<"content">>, Result),
            ?assertEqual(<<"hello grace">>, maps:get(<<"text">>, Block))
    after 5000 ->
        error(no_result)
    end,
    close(Client).

%% A server is allowed to keep asking, so the client has to stop.
mrtr_bounded_rounds(Config) ->
    Client = connect_with(Config, #{mode => sync}, #{max_input_rounds => 2}),
    ?assertMatch(
        {error, {too_many_input_rounds, 2}},
        barrel_mcp_client:call_tool(Client, <<"insatiable">>, #{})
    ),
    close(Client).

%% The caller asked for one call within one timeout, so the rounds
%% share that budget. Giving each a fresh one would let a call outlive
%% the timeout by a factor of max_input_rounds, and outlive the
%% caller's own gen_statem:call deadline with it.
mrtr_shares_one_deadline(Config) ->
    Client = connect_with(Config, #{mode => never}, #{max_input_rounds => 50}),
    Started = erlang:monotonic_time(millisecond),
    Result = barrel_mcp_client:call_tool(
        Client, <<"insatiable">>, #{}, #{timeout => 700}
    ),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    ?assertMatch({error, timeout}, Result),
    %% Bounded by the one timeout, not by 50 of them.
    ?assert(Elapsed < 3000),
    close(Client).

%%====================================================================
%% Era parity
%%====================================================================

%% Refused locally rather than sent and rejected: the caller gets a
%% clear answer instead of a method-not-found from the wire.
removed_methods_are_refused(Config) ->
    Client = connect(Config, ?MODERN),
    ?assertEqual({error, {unsupported, <<"ping">>}}, barrel_mcp_client:ping(Client)),
    ?assertEqual(
        {error, {unsupported, <<"logging/setLevel">>}},
        barrel_mcp_client:set_log_level(Client, <<"debug">>)
    ),
    ?assertEqual(
        {error, {unsupported, <<"tasks/list">>}},
        barrel_mcp_client:tasks_list(Client)
    ),
    ?assertEqual(
        {error, {unsupported, <<"tasks/result">>}},
        barrel_mcp_client:tasks_result(Client, <<"task_x">>)
    ),
    %% A notification with nothing listening for it is simply dropped.
    ?assertEqual(ok, barrel_mcp_client:notify_roots_list_changed(Client)),
    close(Client).

%% The extension is advertised under `extensions', not as a
%% capability, so the client has to look in the right place.
tasks_extension_methods(Config) ->
    Client = connect(Config, ?MODERN),
    ?assertMatch(
        {error, {_, <<"Task not found">>}},
        barrel_mcp_client:tasks_get(Client, <<"task_missing">>)
    ),
    ?assertMatch(
        {error, {_, <<"Task not found">>}},
        barrel_mcp_client:tasks_update(Client, <<"task_missing">>, #{})
    ),
    close(Client).

%% A configured cadence would just fire method-not-found on a timer.
ping_cadence_is_off(Config) ->
    Port = ?config(port, Config),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport => {http, url(Port)},
        protocol_version => ?MODERN,
        ping_interval => 100,
        ping_failure_threshold => 1
    }),
    wait_until(fun() -> is_ready(Pid) end, 5000),
    timer:sleep(500),
    %% Still alive: no ping was ever sent, so none could fail.
    ?assert(is_process_alive(Pid)),
    close(Pid).

%%====================================================================
%% Subscriptions
%%====================================================================

%% subscribe/2 keeps its signature and its delivery contract; only the
%% mechanism underneath changed from resources/subscribe to a
%% subscriptions/listen stream.
subscribe_receives_resource_updates(Config) ->
    Client = connect(Config, ?MODERN),
    {ok, _} = barrel_mcp_client:subscribe(Client, <<"file:///present">>),
    ok = wait_for_subscription(1, 5000),
    ok = barrel_mcp:notify_resource_updated(<<"file:///present">>),
    receive
        {mcp_resource_updated, <<"file:///present">>, _Params} -> ok
    after 5000 ->
        error(no_update_received)
    end,
    close(Client).

unsubscribe_stops_updates(Config) ->
    Client = connect(Config, ?MODERN),
    {ok, _} = barrel_mcp_client:subscribe(Client, <<"file:///present">>),
    ok = wait_for_subscription(1, 5000),
    {ok, _} = barrel_mcp_client:unsubscribe(Client, <<"file:///present">>),
    %% The stream is closed outright, so the server has nothing to
    %% deliver to.
    ok = wait_for_subscription(0, 5000),
    ok = barrel_mcp:notify_resource_updated(<<"file:///present">>),
    receive
        {mcp_resource_updated, _, _} -> error(unexpected_update)
    after 400 ->
        ok
    end,
    close(Client).

wait_for_subscription(_Count, Remaining) when Remaining =< 0 ->
    error(subscription_not_settled);
wait_for_subscription(Count, Remaining) ->
    case barrel_mcp_subscriptions:count() of
        Count ->
            ok;
        _ ->
            timer:sleep(50),
            wait_for_subscription(Count, Remaining - 50)
    end.

%%====================================================================
%% x-mcp-header mirroring
%%====================================================================

%% The server validates these against the body and rejects a mismatch,
%% so a call that succeeds is proof the client mirrored correctly. It
%% has to learn the binding from tools/list first.
mirrors_tool_parameters(Config) ->
    Client = connect(Config, ?MODERN),
    {ok, _} = barrel_mcp_client:list_tools_all(Client),
    {ok, Result} = barrel_mcp_client:call_tool(Client, <<"regional">>, #{
        <<"region">> => <<"us-west1">>,
        <<"query">> => <<"SELECT 1">>
    }),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"us-west1">>, maps:get(<<"text">>, Block)),
    close(Client).

%% A tool whose annotation the client cannot honour is dropped from the
%% list rather than offered and then failing on use, and dropping it
%% must not take the others with it.
%%
%% Our own server rejects such an annotation at registration, so the
%% only way to see one is from a server that does not. The catalogue is
%% edited where it is served from to stand in for that.
excludes_tools_with_bad_annotations(Config) ->
    ok = barrel_mcp_registry:reg(tool, <<"unusable">>, ?MODULE, region_tool, #{}),
    Handlers = persistent_term:get(barrel_mcp_handlers),
    Handler = maps:get({tool, <<"unusable">>}, Handlers),
    Bad = #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"n">> => #{
                <<"type">> => <<"number">>,
                <<"x-mcp-header">> => <<"N">>
            }
        }
    },
    persistent_term:put(
        barrel_mcp_handlers,
        Handlers#{{tool, <<"unusable">>} => Handler#{input_schema => Bad}}
    ),
    try
        Client = connect(Config, ?MODERN),
        {ok, Tools} = barrel_mcp_client:list_tools_all(Client),
        Names = [maps:get(<<"name">>, T) || T <- Tools],
        ?assertNot(lists:member(<<"unusable">>, Names)),
        %% The rest of the catalogue is untouched.
        ?assert(lists:member(<<"echo">>, Names)),
        ?assert(lists:member(<<"regional">>, Names)),
        close(Client)
    after
        barrel_mcp_registry:unreg(tool, <<"unusable">>)
    end.

%%====================================================================
%% Helpers
%%====================================================================

url(Port) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])).

connect(Config, Version) ->
    connect_url(Version, url(?config(port, Config))).

connect_with(Config, Handler) -> connect_with(Config, Handler, #{}).

connect_with(Config, Handler, Extra) ->
    Spec = maps:merge(
        #{
            transport => {http, url(?config(port, Config))},
            protocol_version => ?MODERN,
            capabilities => #{elicitation => true},
            handler => {barrel_mcp_test_handler, Handler}
        },
        Extra
    ),
    {ok, Pid} = barrel_mcp_client:start(Spec),
    wait_until(fun() -> is_ready(Pid) end, 8000),
    Pid.

connect_url(Version, Url) ->
    {ok, Pid} = barrel_mcp_client:start(#{
        transport => {http, Url},
        protocol_version => Version,
        probe_timeout => 1000,
        client_info => #{name => <<"modern-suite">>, version => <<"1.0">>}
    }),
    wait_until(fun() -> is_ready(Pid) end, 8000),
    Pid.

is_ready(Pid) ->
    try barrel_mcp_client:protocol_version(Pid) of
        {ok, V} when is_binary(V) -> true;
        _ -> false
    catch
        _:_ -> false
    end.

close(Pid) ->
    catch_close(Pid),
    ok.

catch_close(Pid) ->
    try
        barrel_mcp_client:close(Pid)
    catch
        _:_ -> ok
    end,
    ok.

wait_until(_Fun, Remaining) when Remaining =< 0 ->
    ok;
wait_until(Fun, Remaining) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Remaining - 50)
    end.

%% A port per case, by position rather than by hash: two case names
%% hashing to the same slot means the second one gets eaddrinuse while
%% the first listener is still releasing its socket.
case_index(TC) ->
    case_index(TC, all(), 0).

case_index(TC, [TC | _], N) -> N;
case_index(TC, [_ | Rest], N) -> case_index(TC, Rest, N + 1);
case_index(_TC, [], N) -> N.
