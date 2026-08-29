%%%-------------------------------------------------------------------
%%% @doc The stdio server as a child OS process, so a case can drive it
%%% over a real pipe.
%%%
%%% Run with `erl -noshell -eval barrel_mcp_stdio_child:start()'. Logging
%%% must go to stderr: stdout is the wire.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_stdio_child).

-export([start/0, echo_tool/1, touch_tool/1, a_resource/1]).

-define(URI, <<"file:///watched">>).

start() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echoes its input">>
    }),
    ok = barrel_mcp:reg_tool(<<"touch">>, ?MODULE, touch_tool, #{
        description => <<"Marks the watched resource as changed">>
    }),
    ok = barrel_mcp:reg_resource(<<"watched">>, ?MODULE, a_resource, #{uri => ?URI}),
    barrel_mcp_stdio:start(),
    halt(0).

echo_tool(Args) ->
    <<"Echo: ", (maps:get(<<"input">>, Args, <<"none">>))/binary>>.

touch_tool(_Args) ->
    ok = barrel_mcp:notify_resource_updated(?URI),
    <<"touched">>.

a_resource(_Args) ->
    <<"body">>.
