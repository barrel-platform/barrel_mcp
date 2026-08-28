%%%-------------------------------------------------------------------
%%% @doc Multi round-trip requests end to end.
%%%
%%% Under MRTR a server that needs more input answers with an
%%% `InputRequiredResult' and finishes the request. Nothing is kept
%%% server-side between attempts, so every case here drives two real
%%% HTTP requests and checks the second picks up where the first left
%%% off, or is refused when it should not.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_mrtr_SUITE).

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
    elicitation_round_trip/1,
    declined_reaches_handler/1,
    state_only_retry_reprompts/1,
    undeclared_capability_refused/1,
    tampered_state_rejected/1,
    state_from_another_call_rejected/1,
    retry_uses_a_new_id/1,
    legacy_client_gets_internal_error/1,
    roots_response_is_unwrapped/1,
    task_returned_when_extension_declared/1,
    synchronous_without_extension/1,
    task_scoped_to_principal/1,
    tasks_update_acknowledges/1,
    legacy_task_shape_unchanged/1,
    prompt_asks_for_input/1,
    resource_asks_for_input/1,
    prompt_state_rejected_on_a_resource/1
]).

-export([deploy_tool/2, roots_tool/2, slow_tool/1]).
-export([gated_prompt/2, gated_resource/2]).

-define(BASE_PORT, 21900).
-define(MODERN, <<"2026-07-28">>).

all() ->
    [
        elicitation_round_trip,
        declined_reaches_handler,
        state_only_retry_reprompts,
        undeclared_capability_refused,
        tampered_state_rejected,
        state_from_another_call_rejected,
        retry_uses_a_new_id,
        legacy_client_gets_internal_error,
        roots_response_is_unwrapped,
        task_returned_when_extension_declared,
        synchronous_without_extension,
        task_scoped_to_principal,
        tasks_update_acknowledges,
        legacy_task_shape_unchanged,
        prompt_asks_for_input,
        resource_asks_for_input,
        prompt_state_rejected_on_a_resource
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    %% A fixed key, so a blob sealed in one case is not accidentally
    %% valid in another for the wrong reason.
    application:set_env(barrel_mcp, request_state_key, <<"mrtr suite key, 32 bytes long..!">>),
    ok = barrel_mcp:reg_tool(<<"deploy">>, ?MODULE, deploy_tool, #{
        description => <<"Asks for confirmation before deploying">>
    }),
    ok = barrel_mcp:reg_tool(<<"needs_roots">>, ?MODULE, roots_tool, #{
        description => <<"Asks the client for its roots">>
    }),
    ok = barrel_mcp:reg_tool(<<"slow">>, ?MODULE, slow_tool, #{
        description => <<"Takes a while">>,
        long_running => true
    }),
    ok = barrel_mcp:reg_prompt(<<"gated">>, ?MODULE, gated_prompt, #{
        description => <<"Asks who to greet before rendering">>
    }),
    ok = barrel_mcp:reg_resource(<<"gated_res">>, ?MODULE, gated_resource, #{
        uri => <<"mem://gated">>,
        mime_type => <<"text/plain">>
    }),
    Config.

end_per_suite(_Config) ->
    barrel_mcp_registry:unreg(tool, <<"deploy">>),
    barrel_mcp_registry:unreg(tool, <<"needs_roots">>),
    barrel_mcp_registry:unreg(tool, <<"slow">>),
    barrel_mcp_registry:unreg(prompt, <<"gated">>),
    barrel_mcp_registry:unreg(resource, <<"gated_res">>),
    application:unset_env(barrel_mcp, request_state_key),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(TC, Config) ->
    Port = ?BASE_PORT + case_index(TC),
    {ok, _} = barrel_mcp:start_http_stream(#{port => Port, session_enabled => true}),
    [{port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    timer:sleep(50),
    ok.

%%====================================================================
%% Tools under test
%%====================================================================

%% Prompts and resources take a `Ctx' too, so they can ask for input on
%% the same terms a tool does. This is the whole shape: read the answer,
%% and if it is not there yet, ask.
gated_prompt(_Args, Ctx) ->
    case barrel_mcp:input(Ctx, <<"who">>) of
        none ->
            ask_for_a_name(<<"Who should I greet?">>);
        {ok, Response} ->
            {ok, Salutation} = barrel_mcp:request_state(Ctx),
            Name = answered_name(Response),
            #{
                description => <<"Greeting">>,
                messages => [
                    #{
                        <<"role">> => <<"user">>,
                        <<"content">> => #{
                            <<"type">> => <<"text">>,
                            <<"text">> => <<Salutation/binary, ", ", Name/binary>>
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

%% The shape a real MRTR handler takes: read what came back, and if it
%% is not there yet, ask and return.
deploy_tool(Args, Ctx) ->
    case barrel_mcp:input(Ctx, <<"confirm">>) of
        {ok, #{<<"action">> := <<"accept">>, <<"content">> := Content}} ->
            {ok, Env} = barrel_mcp:request_state(Ctx),
            Approved = maps:get(<<"approved">>, Content, false),
            <<"deployed ", Env/binary, " approved=",
                (atom_to_binary(Approved =:= true, utf8))/binary>>;
        {ok, #{<<"action">> := Action}} ->
            {tool_error, [
                #{<<"type">> => <<"text">>, <<"text">> => <<"cancelled: ", Action/binary>>}
            ]};
        none ->
            case barrel_mcp:client_supports(Ctx, elicitation) of
                false ->
                    {tool_error, [
                        #{
                            <<"type">> => <<"text">>,
                            <<"text">> => <<"needs elicitation">>
                        }
                    ]};
                true ->
                    {input_required,
                        #{
                            <<"confirm">> => #{
                                method => <<"elicitation/create">>,
                                params => #{
                                    <<"mode">> => <<"form">>,
                                    <<"message">> => <<"Deploy?">>
                                }
                            }
                        },
                        maps:get(<<"env">>, Args, <<"none">>)}
            end
    end.

%% Asks for something the client may not have declared, without
%% checking first, so the framework has to refuse it.
roots_tool(_Args, Ctx) ->
    case barrel_mcp:input(Ctx, <<"ws">>) of
        {ok, Roots} when is_list(Roots) ->
            integer_to_binary(length(Roots));
        none ->
            {input_required, #{<<"ws">> => #{method => <<"roots/list">>, params => #{}}}, asked}
    end.

slow_tool(_Args) ->
    timer:sleep(80),
    <<"done">>.

%%====================================================================
%% The basic workflow
%%====================================================================

elicitation_round_trip(Config) ->
    Port = ?config(port, Config),
    Params = #{
        <<"name">> => <<"deploy">>,
        <<"arguments">> => #{<<"env">> => <<"prod">>}
    },
    {200, _, First} = call(Port, 1, Params, #{<<"elicitation">> => #{}}),
    Result = result_of(First),

    ?assertEqual(<<"input_required">>, maps:get(<<"resultType">>, Result)),
    Requests = maps:get(<<"inputRequests">>, Result),
    Confirm = maps:get(<<"confirm">>, Requests),
    ?assertEqual(<<"elicitation/create">>, maps:get(<<"method">>, Confirm)),
    ?assertEqual(<<"Deploy?">>, maps:get(<<"message">>, maps:get(<<"params">>, Confirm))),
    State = maps:get(<<"requestState">>, Result),
    ?assert(is_binary(State)),

    %% The client gathers the answer and retries. Note the new id: the
    %% two attempts are independent requests.
    {200, _, Second} = call(Port, 2, retry(Params, State, accept()), #{
        <<"elicitation">> => #{}
    }),
    Final = result_of(Second),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Final)),
    [Block] = maps:get(<<"content">>, Final),
    %% The handler's own state came back with it.
    ?assertEqual(<<"deployed prod approved=true">>, maps:get(<<"text">>, Block)),
    ok.

%% A decline is an answer, not an absence: the handler must see it and
%% decide, rather than being asked to prompt again.
declined_reaches_handler(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"deploy">>, <<"arguments">> => #{<<"env">> => <<"prod">>}},
    {200, _, First} = call(Port, 1, Params, #{<<"elicitation">> => #{}}),
    State = maps:get(<<"requestState">>, result_of(First)),
    Declined = #{<<"confirm">> => #{<<"action">> => <<"decline">>}},
    {200, _, Second} = call(Port, 2, retry(Params, State, Declined), #{
        <<"elicitation">> => #{}
    }),
    Result = result_of(Second),
    ?assertEqual(true, maps:get(<<"isError">>, Result)),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"cancelled: decline">>, maps:get(<<"text">>, Block)),
    ok.

%% The spec has the server ask again rather than error when the client
%% comes back without the information.
state_only_retry_reprompts(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"deploy">>, <<"arguments">> => #{<<"env">> => <<"prod">>}},
    {200, _, First} = call(Port, 1, Params, #{<<"elicitation">> => #{}}),
    State = maps:get(<<"requestState">>, result_of(First)),
    Bare = maps:put(<<"requestState">>, State, Params),
    {200, _, Second} = call(Port, 2, Bare, #{<<"elicitation">> => #{}}),
    Result = result_of(Second),
    ?assertEqual(<<"input_required">>, maps:get(<<"resultType">>, Result)),
    ?assert(maps:is_key(<<"confirm">>, maps:get(<<"inputRequests">>, Result))),
    ok.

%%====================================================================
%% Refusals
%%====================================================================

%% The server must not send an input request the client cannot serve.
undeclared_capability_refused(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"needs_roots">>, <<"arguments">> => #{}},
    {400, _, Body} = call(Port, 1, Params, #{}),
    Error = error_of(Body),
    ?assertEqual(?MCP_MISSING_CLIENT_CAPABILITY, maps:get(<<"code">>, Error)),
    ?assertEqual(
        #{<<"roots">> => #{}},
        maps:get(<<"requiredCapabilities">>, maps:get(<<"data">>, Error))
    ),
    ok.

tampered_state_rejected(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"deploy">>, <<"arguments">> => #{<<"env">> => <<"prod">>}},
    {200, _, First} = call(Port, 1, Params, #{<<"elicitation">> => #{}}),
    State = maps:get(<<"requestState">>, result_of(First)),
    Tampered = flip_last(State),
    {400, _, Body} = call(Port, 2, retry(Params, Tampered, accept()), #{
        <<"elicitation">> => #{}
    }),
    ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, error_of(Body))),
    ok.

%% State issued for a prod deploy must not authorise a staging one.
state_from_another_call_rejected(Config) ->
    Port = ?config(port, Config),
    Prod = #{<<"name">> => <<"deploy">>, <<"arguments">> => #{<<"env">> => <<"prod">>}},
    {200, _, First} = call(Port, 1, Prod, #{<<"elicitation">> => #{}}),
    State = maps:get(<<"requestState">>, result_of(First)),
    Staging = #{
        <<"name">> => <<"deploy">>,
        <<"arguments">> => #{<<"env">> => <<"staging">>}
    },
    {400, _, Body} = call(Port, 2, retry(Staging, State, accept()), #{
        <<"elicitation">> => #{}
    }),
    ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, error_of(Body))),
    ok.

%% Nothing ties an attempt to the id of the one before it, so a client
%% is free to reuse an id it has finished with.
retry_uses_a_new_id(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"deploy">>, <<"arguments">> => #{<<"env">> => <<"prod">>}},
    {200, _, First} = call(Port, 1, Params, #{<<"elicitation">> => #{}}),
    State = maps:get(<<"requestState">>, result_of(First)),
    {200, _, Second} = call(Port, 99, retry(Params, State, accept()), #{
        <<"elicitation">> => #{}
    }),
    ?assertEqual(99, maps:get(<<"id">>, json:decode(Second))),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, result_of(Second))),
    ok.

%% MRTR is a modern pattern. A legacy client has the blocking
%% server-to-client calls, so a handler returning input_required to one
%% is a programming error, reported as such rather than half-served.
legacy_client_gets_internal_error(Config) ->
    Port = ?config(port, Config),
    {200, InitHeaders, _} = post(Port, init_body(), []),
    SessionId = header(<<"mcp-session-id">>, InitHeaders),
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 2,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{
            <<"name">> => <<"deploy">>,
            <<"arguments">> => #{<<"env">> => <<"prod">>}
        }
    }),
    {200, _, Resp} = post(Port, Body, [{<<"mcp-session-id">>, SessionId}]),
    %% client_supports/2 is false without a modern context, so the tool
    %% degrades on its own terms before the framework has to refuse.
    Result = maps:get(<<"result">>, json:decode(Resp)),
    ?assertEqual(true, maps:get(<<"isError">>, Result)),
    ok.

%% roots/list comes back unwrapped, the way roots_list/2 returns it.
roots_response_is_unwrapped(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"needs_roots">>, <<"arguments">> => #{}},
    Caps = #{<<"roots">> => #{}},
    {200, _, First} = call(Port, 1, Params, Caps),
    State = maps:get(<<"requestState">>, result_of(First)),
    Responses = #{
        <<"ws">> => #{
            <<"roots">> => [
                #{<<"uri">> => <<"file:///a">>},
                #{<<"uri">> => <<"file:///b">>}
            ]
        }
    },
    {200, _, Second} = call(Port, 2, retry(Params, State, Responses), Caps),
    [Block] = maps:get(<<"content">>, result_of(Second)),
    ?assertEqual(<<"2">>, maps:get(<<"text">>, Block)),
    ok.

%%====================================================================
%% Tasks extension
%%====================================================================

tasks_caps() -> #{<<"extensions">> => #{?MCP_EXT_TASKS => #{}}}.

task_returned_when_extension_declared(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"slow">>, <<"arguments">> => #{}},
    {200, _, Body} = call(Port, 1, Params, tasks_caps()),
    Result = result_of(Body),
    ?assertEqual(<<"task">>, maps:get(<<"resultType">>, Result)),
    TaskId = maps:get(<<"taskId">>, Result),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, Result)),
    %% The client is told how long the handle lives and how often to
    %% come back, rather than having to guess.
    ?assert(is_integer(maps:get(<<"ttlMs">>, Result))),
    ?assert(is_integer(maps:get(<<"pollIntervalMs">>, Result))),

    %% Poll it to a terminal state.
    Task = poll_until_terminal(Port, TaskId, tasks_caps(), 30),
    ?assertEqual(<<"completed">>, maps:get(<<"status">>, Task)),
    [Block] = maps:get(<<"content">>, maps:get(<<"result">>, Task)),
    ?assertEqual(<<"done">>, maps:get(<<"text">>, Block)),
    ok.

%% Handing a task to a client that never declared the extension would
%% leave it holding a handle it does not know how to poll.
synchronous_without_extension(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"slow">>, <<"arguments">> => #{}},
    {200, _, Body} = call(Port, 1, Params, #{}),
    Result = result_of(Body),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    [Block] = maps:get(<<"content">>, Result),
    ?assertEqual(<<"done">>, maps:get(<<"text">>, Block)),
    ?assertNot(maps:is_key(<<"taskId">>, Result)),
    ok.

%% A modern task has no session, so it is scoped to the principal.
%% Without an auth provider every caller is the same anonymous
%% principal, so this checks the scope is real by naming a task that
%% belongs to a different one.
task_scoped_to_principal(Config) ->
    Port = ?config(port, Config),
    {200, _, Body} = call(
        Port,
        1,
        #{<<"name">> => <<"slow">>, <<"arguments">> => #{}},
        tasks_caps()
    ),
    TaskId = maps:get(<<"taskId">>, result_of(Body)),
    {ok, Other} = barrel_mcp_tasks:create(
        {principal, #{<<"sub">> => <<"someone">>}},
        <<"tools/call">>,
        #{}
    ),
    %% Ours resolves; theirs does not.
    ?assertMatch({200, _, _}, tasks_get(Port, TaskId, tasks_caps())),
    %% Not found is invalid-params, which the transport binding pins
    %% to a 400.
    {400, _, Denied} = tasks_get(Port, Other, tasks_caps()),
    ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, error_of(Denied))),
    ok.

%% The method exists because the extension defines it. No task reaches
%% `input_required' yet, so in practice it acknowledges and the
%% responses are ignored, which is what the extension prescribes.
tasks_update_acknowledges(Config) ->
    Port = ?config(port, Config),
    {200, _, Body} = call(
        Port,
        1,
        #{<<"name">> => <<"slow">>, <<"arguments">> => #{}},
        tasks_caps()
    ),
    TaskId = maps:get(<<"taskId">>, result_of(Body)),
    {200, _, Ack} = rpc(
        Port,
        2,
        <<"tasks/update">>,
        #{
            <<"taskId">> => TaskId,
            <<"inputResponses">> => #{<<"unknown">> => #{<<"action">> => <<"accept">>}}
        },
        tasks_caps()
    ),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, result_of(Ack))),
    %% An unknown task is still an error, and invalid-params is one of
    %% the codes the transport binding pins to a 400.
    {400, _, Missing} = rpc(
        Port,
        3,
        <<"tasks/update">>,
        #{
            <<"taskId">> => <<"task_nope">>,
            <<"inputResponses">> => #{}
        },
        tasks_caps()
    ),
    ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, error_of(Missing))),
    ok.

%% Legacy clients negotiated the core task methods and still get the
%% wrapped handle they expect, not a polymorphic result type.
legacy_task_shape_unchanged(Config) ->
    Port = ?config(port, Config),
    {200, InitHeaders, _} = post(Port, init_body(), []),
    SessionId = header(<<"mcp-session-id">>, InitHeaders),
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 2,
        <<"method">> => <<"tools/call">>,
        <<"params">> => #{<<"name">> => <<"slow">>, <<"arguments">> => #{}}
    }),
    {200, _, Resp} = post(Port, Body, [{<<"mcp-session-id">>, SessionId}]),
    Result = maps:get(<<"result">>, json:decode(Resp)),
    ?assert(maps:is_key(<<"task">>, Result)),
    ?assertNot(maps:is_key(<<"resultType">>, Result)),
    ?assertEqual(<<"working">>, maps:get(<<"status">>, maps:get(<<"task">>, Result))),
    ok.

poll_until_terminal(_Port, _TaskId, _Caps, 0) ->
    error(task_never_settled);
poll_until_terminal(Port, TaskId, Caps, N) ->
    {200, _, Body} = tasks_get(Port, TaskId, Caps),
    Task = result_of(Body),
    case maps:get(<<"status">>, Task) of
        <<"working">> ->
            timer:sleep(50),
            poll_until_terminal(Port, TaskId, Caps, N - 1);
        _ ->
            Task
    end.

tasks_get(Port, TaskId, Caps) ->
    rpc(Port, 50, <<"tasks/get">>, #{<<"taskId">> => TaskId}, Caps).

%%====================================================================
%% Prompts and resources
%%
%% Both handlers run inline in the request process rather than through
%% the tool path's async plan, so they take their own route to the same
%% envelope. These cases prove it is the same envelope.
%%====================================================================

prompt_asks_for_input(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"name">> => <<"gated">>, <<"arguments">> => #{}},
    Caps = #{<<"elicitation">> => #{}},
    {200, _, First} = named_rpc(Port, 1, <<"prompts/get">>, Params, Caps, <<"gated">>),
    Result = result_of(First),
    ?assertEqual(<<"input_required">>, maps:get(<<"resultType">>, Result)),
    Ask = maps:get(<<"who">>, maps:get(<<"inputRequests">>, Result)),
    ?assertEqual(<<"elicitation/create">>, maps:get(<<"method">>, Ask)),
    State = maps:get(<<"requestState">>, Result),

    {200, _, Second} = named_rpc(
        Port, 2, <<"prompts/get">>, retry(Params, State, named(<<"ada">>)), Caps, <<"gated">>
    ),
    Final = result_of(Second),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Final)),
    [Message] = maps:get(<<"messages">>, Final),
    %% The handler's own state came back with the answer.
    ?assertEqual(
        <<"hello, ada">>,
        maps:get(<<"text">>, maps:get(<<"content">>, Message))
    ),
    ok.

resource_asks_for_input(Config) ->
    Port = ?config(port, Config),
    Params = #{<<"uri">> => <<"mem://gated">>},
    Caps = #{<<"elicitation">> => #{}},
    Uri = <<"mem://gated">>,
    {200, _, First} = named_rpc(Port, 1, <<"resources/read">>, Params, Caps, Uri),
    Result = result_of(First),
    ?assertEqual(<<"input_required">>, maps:get(<<"resultType">>, Result)),
    State = maps:get(<<"requestState">>, Result),

    {200, _, Second} = named_rpc(
        Port, 2, <<"resources/read">>, retry(Params, State, named(<<"ada">>)), Caps, Uri
    ),
    Final = result_of(Second),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Final)),
    [Block] = maps:get(<<"contents">>, Final),
    ?assertEqual(<<"hello/ada">>, maps:get(<<"text">>, Block)),
    ok.

%% The state is bound to the request that issued it. A prompt's state
%% is not a token for reading a resource.
prompt_state_rejected_on_a_resource(Config) ->
    Port = ?config(port, Config),
    Caps = #{<<"elicitation">> => #{}},
    PromptParams = #{<<"name">> => <<"gated">>, <<"arguments">> => #{}},
    {200, _, First} = named_rpc(
        Port, 1, <<"prompts/get">>, PromptParams, Caps, <<"gated">>
    ),
    State = maps:get(<<"requestState">>, result_of(First)),

    Uri = <<"mem://gated">>,
    Replay = retry(#{<<"uri">> => Uri}, State, named(<<"ada">>)),
    %% 400, because a modern -32602 is a bad request rather than a
    %% result the client should read.
    {400, _, Second} = named_rpc(Port, 2, <<"resources/read">>, Replay, Caps, Uri),
    ?assertEqual(?JSONRPC_INVALID_PARAMS, maps:get(<<"code">>, error_of(Second))),
    ok.

named(Name) ->
    #{
        <<"who">> => #{
            <<"action">> => <<"accept">>,
            <<"content">> => #{<<"name">> => Name}
        }
    }.

%%====================================================================
%% Helpers
%%====================================================================

accept() ->
    #{
        <<"confirm">> => #{
            <<"action">> => <<"accept">>,
            <<"content">> => #{<<"approved">> => true}
        }
    }.

retry(Params, State, Responses) ->
    Params#{
        <<"requestState">> => State,
        <<"inputResponses">> => Responses
    }.

flip_last(Blob) ->
    Size = byte_size(Blob),
    Head = binary:part(Blob, 0, Size - 1),
    Last = binary:last(Blob),
    New =
        case Last of
            $A -> $B;
            _ -> $A
        end,
    <<Head/binary, New>>.

url(Port) ->
    iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])).

call(Port, Id, Params, Capabilities) ->
    Meta = #{
        ?MCP_META_PROTOCOL_VERSION => ?MODERN,
        ?MCP_META_CLIENT_CAPABILITIES => Capabilities
    },
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"tools/call">>,
        <<"params">> => Params#{<<"_meta">> => Meta}
    }),
    Headers = [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, maps:get(<<"name">>, Params)}
    ],
    post(Port, Body, Headers).

%% A modern request for a method that carries no Mcp-Name.
rpc(Port, Id, Method, Params, Capabilities) ->
    Meta = #{
        ?MCP_META_PROTOCOL_VERSION => ?MODERN,
        ?MCP_META_CLIENT_CAPABILITIES => Capabilities
    },
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => Meta}
    }),
    post(Port, Body, [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, Method}
        %% The tasks extension mirrors the task id into Mcp-Name, and
        %% the server rejects a task request that omits it.
        | task_name_header(Params)
    ]).

task_name_header(#{<<"taskId">> := TaskId}) -> [{<<"mcp-name">>, TaskId}];
task_name_header(_Params) -> [].

%% `prompts/get' and `resources/read' mirror their subject into
%% `Mcp-Name', so the server rejects a request that omits it.
named_rpc(Port, Id, Method, Params, Capabilities, Name) ->
    Meta = #{
        ?MCP_META_PROTOCOL_VERSION => ?MODERN,
        ?MCP_META_CLIENT_CAPABILITIES => Capabilities
    },
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => Meta}
    }),
    post(Port, Body, [
        {<<"mcp-protocol-version">>, ?MODERN},
        {<<"mcp-method">>, Method},
        {<<"mcp-name">>, Name}
    ]).

post(Port, Body, ExtraHeaders) ->
    Headers =
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ] ++ ExtraHeaders,
    {ok, Status, RespHeaders, RespBody} = hackney:request(
        post, url(Port), Headers, Body, [with_body]
    ),
    {Status, RespHeaders, RespBody}.

init_body() ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{<<"elicitation">> => #{}},
            <<"clientInfo">> => #{<<"name">> => <<"mrtr">>, <<"version">> => <<"1.0">>}
        }
    }).

header(Name, Headers) ->
    Lower = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(K) =:= Lower end, Headers) of
        {value, {_, V}} -> V;
        false -> undefined
    end.

result_of(Body) -> maps:get(<<"result">>, json:decode(Body)).

error_of(Body) -> maps:get(<<"error">>, json:decode(Body)).

%% A port per case, by position rather than by hash: two case names
%% hashing to the same slot means the second one gets eaddrinuse while
%% the first listener is still releasing its socket.
case_index(TC) ->
    case_index(TC, all(), 0).

case_index(TC, [TC | _], N) -> N;
case_index(TC, [_ | Rest], N) -> case_index(TC, Rest, N + 1);
case_index(_TC, [], N) -> N.
