%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc stdio transport for MCP protocol.
%%%
%%% This module implements the stdio transport for the Model Context Protocol,
%%% enabling communication with MCP clients like Claude Desktop that use
%%% stdin/stdout for message passing.
%%%
%%% == Usage Modes ==
%%%
%%% <ul>
%%%   <li><b>Blocking mode</b> - Call {@link start/0} to run the server
%%%       in the current process. The function blocks until stdin closes.</li>
%%%   <li><b>Supervised mode</b> - Call {@link start_link/0} to start as
%%%       a gen_server that can be supervised.</li>
%%% </ul>
%%%
%%% == Protocol ==
%%%
%%% The stdio transport uses newline-delimited JSON-RPC 2.0 messages:
%%%
%%% <ul>
%%%   <li>Each message is a single line of JSON</li>
%%%   <li>Messages are terminated by newline (`\n')</li>
%%%   <li>Responses are written to stdout in the same format</li>
%%% </ul>
%%%
%%% == Example: Blocking Mode ==
%%%
%%% ```
%%% %% In your escript or application main function:
%%% main(_Args) ->
%%%     application:ensure_all_started(barrel_mcp),
%%%     barrel_mcp_registry:wait_for_ready(),
%%%
%%%     %% Register your tools
%%%     barrel_mcp:reg_tool(<<"my_tool">>, my_module, my_function, #{
%%%         description => <<"My tool description">>
%%%     }),
%%%
%%%     %% Start stdio server (blocks until stdin closes)
%%%     barrel_mcp_stdio:start().
%%% '''
%%%
%%% == Example: Supervised Mode ==
%%%
%%% ```
%%% %% In your supervisor init/1:
%%% init(_Args) ->
%%%     Children = [
%%%         #{id => mcp_stdio,
%%%           start => {barrel_mcp_stdio, start_link, []},
%%%           restart => permanent,
%%%           type => worker}
%%%     ],
%%%     {ok, {#{strategy => one_for_one}, Children}}.
%%% '''
%%%
%%% == Claude Desktop Integration ==
%%%
%%% To use with Claude Desktop, configure `claude_desktop_config.json':
%%%
%%% ```
%%% {
%%%   "mcpServers": {
%%%     "my-erlang-server": {
%%%       "command": "/path/to/your/escript",
%%%       "args": []
%%%     }
%%%   }
%%% }
%%% '''
%%%
%%% The config file is located at:
%%%
%%% <ul>
%%%   <li><b>macOS</b>: `~/Library/Application Support/Claude/claude_desktop_config.json'</li>
%%%   <li><b>Windows</b>: `%APPDATA%\Claude\claude_desktop_config.json'</li>
%%%   <li><b>Linux</b>: `~/.config/claude/claude_desktop_config.json'</li>
%%% </ul>
%%%
%%% @see barrel_mcp
%%% @see barrel_mcp_protocol
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_stdio).

%% API
-export([
    start/0,
    start_link/0
]).

%% gen_server callbacks (for supervised mode)
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the stdio server in blocking mode.
%%
%% This function starts the MCP stdio server in the current process.
%% It reads JSON-RPC messages from stdin, processes them through the
%% MCP protocol handler, and writes responses to stdout.
%%
%% <b>Important:</b> This function blocks until stdin is closed (EOF).
%% It is typically called as the last line of an escript main function
%% or from a dedicated process.
%%
%% == Example ==
%%
%% ```
%% -module(my_mcp_server).
%% -export([main/1]).
%%
%% main(_Args) ->
%%     application:ensure_all_started(barrel_mcp),
%%     barrel_mcp_registry:wait_for_ready(),
%%
%%     %% Register tools before starting
%%     barrel_mcp:reg_tool(<<"echo">>, ?MODULE, echo, #{
%%         description => <<"Echo back the input">>
%%     }),
%%
%%     %% This blocks until stdin closes
%%     barrel_mcp_stdio:start().
%%
%% echo(Args) ->
%%     maps:get(<<"message">>, Args, <<>>).
%% '''
%%
%% @returns `ok' when stdin closes
-spec start() -> ok.
start() ->
    %% Set binary mode for stdin/stdout
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    loop().

%% @doc Start the stdio server as a supervised gen_server.
%%
%% This function starts the MCP stdio server as a gen_server process
%% that can be supervised. Unlike {@link start/0}, this returns
%% immediately after spawning the server process.
%%
%% The server registers locally as `barrel_mcp_stdio'.
%%
%% == Example ==
%%
%% ```
%% %% In your supervisor:
%% init([]) ->
%%     SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
%%     Children = [
%%         #{id => mcp_stdio,
%%           start => {barrel_mcp_stdio, start_link, []},
%%           restart => permanent,
%%           shutdown => 5000,
%%           type => worker,
%%           modules => [barrel_mcp_stdio]}
%%     ],
%%     {ok, {SupFlags, Children}}.
%% '''
%%
%% @returns `{ok, Pid}' on success, or `{error, Reason}' on failure
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    %% Schedule first read
    self() ! read_line,
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(read_line, State) ->
    case io:get_line(standard_io, '') of
        eof ->
            {stop, normal, State};
        {error, _} ->
            {stop, normal, State};
        Line ->
            handle_line(Line),
            self() ! read_line,
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

loop() ->
    case io:get_line(standard_io, '') of
        eof ->
            ok;
        {error, _} ->
            ok;
        Line ->
            handle_line(Line),
            loop()
    end.

handle_line(Line) when is_binary(Line) ->
    %% Trim whitespace
    TrimmedLine = string:trim(Line),
    case TrimmedLine of
        <<>> ->
            ok;
        _ ->
            process_request(TrimmedLine)
    end;
handle_line(Line) when is_list(Line) ->
    handle_line(list_to_binary(Line)).

process_request(Line) ->
    case barrel_mcp_protocol:decode(Line) of
        {ok, Request} ->
            case barrel_mcp_protocol:handle(Request) of
                no_response ->
                    %% Notification - no response needed
                    ok;
                Response ->
                    send_response(Response)
            end;
        {error, parse_error} ->
            ErrorResponse = barrel_mcp_protocol:error_response(
                null, -32700, <<"Parse error">>
            ),
            send_response(ErrorResponse)
    end.

send_response(Response) ->
    ResponseJson = barrel_mcp_protocol:encode(Response),
    io:format("~s~n", [ResponseJson]).
