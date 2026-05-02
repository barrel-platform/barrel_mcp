%%%-------------------------------------------------------------------
%%% @doc Example host that implements `barrel_mcp_client_handler' and
%%% answers `sampling/createMessage' with a canned reply.
%%%
%%% Demonstrates the full server-to-client round-trip: the host calls
%%% a tool on a remote MCP server; the server-side tool handler asks
%%% the connected client to sample an LLM message; the client's
%%% handler returns a canned response; the server-side tool handler
%%% returns that response as its tool result.
%%%
%%% Run with `rebar3 shell -eval 'sampling_host:run().'' or via the
%%% common_test suite under `test/sampling_host_SUITE'.
%%% @end
%%%-------------------------------------------------------------------
-module(sampling_host).

-behaviour(barrel_mcp_client_handler).

-export([run/0, run/1]).

%% Tool handler exported for the registry.
-export([ask_sampler/1]).

%% Handler behaviour callbacks.
-export([init/1, handle_request/3, handle_notification/3, terminate/2]).

-define(DEFAULT_PORT, 18081).

%% @doc End-to-end run of the example. Returns the binary the
%% handler produced, which the server-side tool wrapped in
%% `"got: <reply>"'.
-spec run() -> binary().
run() ->
    run(?DEFAULT_PORT).

-spec run(pos_integer()) -> binary().
run(Port) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = ensure_tool(),
    {ok, _} = ensure_server(Port),
    Url = iolist_to_binary(io_lib:format("http://127.0.0.1:~B/mcp", [Port])),
    {ok, Client} = barrel_mcp_client:start(#{
        transport => {http, Url},
        capabilities => #{sampling => true},
        handler => {?MODULE, #{reply => <<"a canned reply">>}}
    }),
    ok = wait_ready(Client, 30),
    ok = wait_sampling_session(50),
    {ok, Result} = barrel_mcp_client:call_tool(
        Client, <<"ask_sampler">>, #{<<"prompt">> => <<"hi">>},
        #{timeout => 10000}),
    [#{<<"type">> := <<"text">>, <<"text">> := Text}] =
        maps:get(<<"content">>, Result),
    barrel_mcp_client:close(Client),
    Text.

%%====================================================================
%% Server-side tool: ask the connected sampling-capable client.
%%====================================================================

%% @doc Tool handler. Looks up the only sampling-capable session and
%% asks it to produce a message. In a real host you would route by
%% the calling session id; we keep the example single-client.
-spec ask_sampler(map()) -> binary().
ask_sampler(#{<<"prompt">> := Prompt}) ->
    [SessionId | _] = barrel_mcp:list_sessions_with_sampling(),
    Params = #{
        <<"messages">> => [
            #{<<"role">> => <<"user">>,
              <<"content">> => #{<<"type">> => <<"text">>,
                                 <<"text">> => Prompt}}
        ],
        <<"maxTokens">> => 64
    },
    {ok, Result, _Usage} =
        barrel_mcp:sampling_create_message(SessionId, Params,
                                           #{timeout_ms => 5000}),
    Reply = maps:get(<<"text">>, maps:get(<<"content">>, Result)),
    iolist_to_binary([<<"got: ">>, Reply]).

%%====================================================================
%% Client-side handler: answer the server's sampling request.
%%====================================================================

init(#{reply := _} = State) ->
    {ok, State}.

handle_request(<<"sampling/createMessage">>, _Params, #{reply := R} = S) ->
    Result = #{
        <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => R},
        <<"model">> => <<"example-canned-model">>,
        <<"role">> => <<"assistant">>,
        <<"usage">> => #{<<"input_tokens">> => 1, <<"output_tokens">> => 1}
    },
    {reply, Result, S};
handle_request(Method, _Params, S) ->
    {error, -32601, <<"Method not found: ", Method/binary>>, S}.

handle_notification(_Method, _Params, S) ->
    {ok, S}.

terminate(_Reason, _S) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

ensure_tool() ->
    barrel_mcp_registry:reg(tool, <<"ask_sampler">>, ?MODULE, ask_sampler, #{
        description => <<"Asks the connected client to sample a message.">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"prompt">>],
            <<"properties">> => #{
                <<"prompt">> => #{<<"type">> => <<"string">>}
            }
        }
    }).

ensure_server(Port) ->
    case barrel_mcp_http_stream:start(#{port => Port,
                                        session_enabled => true}) of
        {ok, _} = Ok -> Ok;
        {error, {already_started, Pid}} -> {ok, Pid}
    end.

wait_ready(_Pid, 0) -> {error, not_ready};
wait_ready(Pid, N) ->
    case catch barrel_mcp_client:server_capabilities(Pid) of
        {ok, _} -> ok;
        _ ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.

%% Wait until the SSE GET has been received by the server and the
%% session is registered as sampling-capable. The client sends GET
%% asynchronously after init, so a brief wait avoids a race.
wait_sampling_session(0) -> {error, no_sampling_session};
wait_sampling_session(N) ->
    case barrel_mcp:list_sessions_with_sampling() of
        [_|_] -> ok;
        [] ->
            timer:sleep(50),
            wait_sampling_session(N - 1)
    end.
