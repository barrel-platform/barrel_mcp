%%%-------------------------------------------------------------------
%%% @doc Interop with the official Go MCP SDK, in both directions.
%%%
%%% The Python suite is a second implementation reading our wire; this
%%% is a third, with its own JSON encoder and its own idea of `_meta'.
%%% The Go client is auto-mode and cannot be pinned to a revision, so
%%% which era a case lands in is decided by the server it is pointed
%%% at, and each case asserts the era it expects.
%%%
%%% Skips unless `INTEROP_GO_CLIENT' and `INTEROP_GO_SERVER' name the
%%% built binaries; `make interop-go' sets both.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_go_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-import(barrel_mcp_test_helpers, [wait_ready/2, erl_executable/0, child_args/1]).

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    modern_go_client_streamable/1,
    legacy_go_client_streamable/1,
    sse_go_client/1,
    stdio_go_client/1,
    erlang_client_against_go_server/1
]).
-export([echo_tool/1, confirm_tool/2, greeting_resource/1, hello_prompt/1]).

-define(PORT, 22700).

all() ->
    [
        modern_go_client_streamable,
        legacy_go_client_streamable,
        sse_go_client,
        stdio_go_client,
        erlang_client_against_go_server
    ].

init_per_suite(Config) ->
    case {binary_env("INTEROP_GO_CLIENT"), binary_env("INTEROP_GO_SERVER")} of
        {undefined, _} ->
            {skip, "INTEROP_GO_CLIENT not set; run `make interop-go`"};
        {_, undefined} ->
            {skip, "INTEROP_GO_SERVER not set; run `make interop-go`"};
        {Client, Server} ->
            {ok, _} = application:ensure_all_started(barrel_mcp),
            {ok, _} = application:ensure_all_started(hackney),
            ok = barrel_mcp_registry:wait_for_ready(),
            [{go_client, Client}, {go_server, Server} | Config]
    end.

end_per_suite(_Config) ->
    application:stop(barrel_mcp),
    ok.

init_per_testcase(erlang_client_against_go_server, Config) ->
    Config;
init_per_testcase(TC, Config) ->
    ok = fixture(),
    Port = ?PORT + case_index(TC),
    Opts = listener_opts(TC, Port),
    {ok, _} = barrel_mcp:start_http_stream(Opts),
    [{port, Port} | Config].

end_per_testcase(erlang_client_against_go_server, _Config) ->
    ok;
end_per_testcase(_TC, _Config) ->
    application:unset_env(barrel_mcp, advertise_versions),
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    cleanup_fixture(),
    timer:sleep(50),
    ok.

%% The Go client falls back to `initialize' on any discover error, so
%% a server advertising only legacy revisions is enough to land it in
%% the handshake era.
listener_opts(legacy_go_client_streamable, Port) ->
    application:set_env(barrel_mcp, advertise_versions, legacy),
    #{port => Port, session_enabled => true};
listener_opts(sse_go_client, Port) ->
    #{port => Port, sse_path => <<"/sse">>, sse_message_path => <<"/messages">>};
listener_opts(_TC, Port) ->
    #{port => Port, session_enabled => true}.

%%====================================================================
%% Cases
%%====================================================================

modern_go_client_streamable(Config) ->
    run_go(Config, ["streamable-modern", url(Config, <<"/mcp">>)]).

legacy_go_client_streamable(Config) ->
    run_go(Config, ["streamable-legacy", url(Config, <<"/mcp">>)]).

sse_go_client(Config) ->
    run_go(Config, ["sse", url(Config, <<"/sse">>)]).

stdio_go_client(Config) ->
    run_go(Config, ["stdio", erl_executable() | child_args(barrel_mcp_stdio_child)]).

%% Our client against a foreign server: the probe, the fallback and the
%% catalogue, over stdio.
erlang_client_against_go_server(Config) ->
    Server = ?config(go_server, Config),
    {ok, Pid} = barrel_mcp_client:start(#{
        transport => {stdio, #{command => Server, args => []}}
    }),
    try
        ok = wait_ready(Pid, 50),
        {ok, Version} = barrel_mcp_client:protocol_version(Pid),
        ?assert(lists:member(Version, ?MCP_ALL_VERSIONS)),
        {ok, Tools} = barrel_mcp_client:list_tools(Pid),
        ?assert(lists:member(<<"echo">>, [maps:get(<<"name">>, T) || T <- Tools])),
        {ok, Result} = barrel_mcp_client:call_tool(
            Pid, <<"echo">>, #{<<"text">> => <<"from erlang">>}, #{timeout => 10000}
        ),
        [Block | _] = maps:get(<<"content">>, Result),
        ?assertEqual(<<"from erlang">>, maps:get(<<"text">>, Block)),
        {ok, Read} = barrel_mcp_client:read_resource(Pid, <<"mem://greeting">>),
        [C | _] = maps:get(<<"contents">>, Read),
        ?assertEqual(<<"hello, world">>, maps:get(<<"text">>, C))
    after
        try
            barrel_mcp_client:close(Pid)
        catch
            _:_ -> ok
        end
    end.

%%====================================================================
%% Fixture: the same catalogue the Python suite serves
%%====================================================================

fixture() ->
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo a string">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"text">>],
            <<"properties">> => #{<<"text">> => #{<<"type">> => <<"string">>}}
        }
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

cleanup_fixture() ->
    _ = [
        try
            barrel_mcp_registry:unreg(K, N)
        catch
            _:_ -> ok
        end
     || {K, N} <- [
            {tool, <<"echo">>},
            {tool, <<"confirm">>},
            {resource, <<"greeting">>},
            {prompt, <<"hello_prompt">>}
        ]
    ],
    ok.

echo_tool(#{<<"text">> := T}) -> T.

greeting_resource(_) -> <<"hello, world">>.

hello_prompt(Args) ->
    Who = maps:get(<<"who">>, Args, <<"world">>),
    #{
        messages => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => #{
                    <<"type">> => <<"text">>, <<"text">> => <<"hello, ", Who/binary>>
                }
            }
        ]
    }.

%% One MRTR round: ask, then greet with what came back.
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
                                <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}}
                            }
                        }
                    }
                },
                <<"seed">>};
        {ok, #{<<"content">> := Content}} ->
            Seed =
                case barrel_mcp:request_state(Ctx) of
                    {ok, S} -> S;
                    none -> <<"none">>
                end,
            Name = maps:get(<<"name">>, Content, <<"nobody">>),
            <<"hello ", Name/binary, " (", Seed/binary, ")">>
    end.

%%====================================================================
%% Helpers
%%====================================================================

run_go(Config, Args) ->
    Client = ?config(go_client, Config),
    case run(Client, Args, root_dir()) of
        {0, Output} ->
            ?assertNotEqual(nomatch, string:find(Output, "OK"));
        {Status, Output} ->
            ct:fail({go_client_failed, Status, Output})
    end.

run(Exe, Args, Cwd) ->
    Port = open_port(
        {spawn_executable, Exe},
        [{args, Args}, {cd, Cwd}, exit_status, stderr_to_stdout, use_stdio, binary, {line, 4096}]
    ),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, {_, Line}}} -> collect(Port, [Line, $\n | Acc]);
        {Port, {data, Line}} -> collect(Port, [Line, $\n | Acc]);
        {Port, {exit_status, Status}} -> {Status, lists:flatten(lists:reverse(Acc))}
    after 60000 ->
        _ =
            try
                port_close(Port)
            catch
                _:_ -> ok
            end,
        {timeout, lists:flatten(lists:reverse(Acc))}
    end.

url(Config, Path) ->
    binary_to_list(barrel_mcp_test_helpers:url(?config(port, Config), Path)).

binary_env(Var) ->
    case os:getenv(Var) of
        false ->
            undefined;
        V ->
            case filelib:is_regular(V) of
                true -> V;
                false -> undefined
            end
    end.

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
