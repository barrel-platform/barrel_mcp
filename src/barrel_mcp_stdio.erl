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

%% Largest single stdio frame accepted from a peer, and the chunk the
%% reader pulls at a time.
-define(DEFAULT_MAX_FRAME_BYTES, 16 * 1024 * 1024).
-define(READ_CHUNK_BYTES, 65536).

-record(state, {buf = <<>> :: binary(), version :: binary() | undefined}).

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
    case read_frame(State#state.buf) of
        eof ->
            {stop, normal, State};
        {error, _} ->
            {stop, normal, State};
        {too_large, _Rest} ->
            %% A frame past the cap cannot be answered in place: the
            %% newline that would end it may never arrive, and skipping
            %% to the next one is the same unbounded read again. Report
            %% and close.
            send_response(
                barrel_mcp_protocol:error_response(
                    null, -32600, <<"Request exceeds the maximum frame size">>
                )
            ),
            {stop, normal, State};
        {ok, Line, Rest} ->
            Version = handle_line(Line, State#state.version),
            self() ! read_line,
            {noreply, State#state{buf = Rest, version = Version}}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

loop() ->
    loop(<<>>, undefined).

loop(Buf, Version) ->
    case read_frame(Buf) of
        eof ->
            ok;
        {error, _} ->
            ok;
        {too_large, _Rest} ->
            send_response(
                barrel_mcp_protocol:error_response(
                    null, -32600, <<"Request exceeds the maximum frame size">>
                )
            ),
            ok;
        {ok, Line, Rest} ->
            loop(Rest, handle_line(Line, Version))
    end.

%% Read one newline-delimited frame without ever holding more than the
%% cap in memory. `io:get_line/2' cannot do this: it returns the whole
%% line, however long, so a cap applied to its result is applied after
%% the allocation it was meant to prevent. Reading in chunks means the
%% buffer can also span a message boundary, so the remainder is carried
%% to the next call.
read_frame(Buf) ->
    Max = application:get_env(barrel_mcp, stdio_max_frame_bytes, ?DEFAULT_MAX_FRAME_BYTES),
    read_frame(Buf, Max).

read_frame(Buf, Max) ->
    case binary:match(Buf, <<"\n">>) of
        %% The length of the frame itself, not merely of what has
        %% accumulated without a newline. Checking only the latter would
        %% let anything shorter than one read through unmeasured.
        {Pos, 1} when Pos > Max ->
            {too_large, Buf};
        {Pos, 1} ->
            <<Line:Pos/binary, _Nl:1/binary, Rest/binary>> = Buf,
            {ok, Line, Rest};
        nomatch when byte_size(Buf) > Max ->
            {too_large, Buf};
        nomatch ->
            %% Never pull more than the cap allows, so a small cap is
            %% honoured rather than rounded up to the chunk size.
            Chunk = min(?READ_CHUNK_BYTES, Max - byte_size(Buf) + 1),
            case io:get_chars(standard_io, '', Chunk) of
                eof when Buf =:= <<>> -> eof;
                %% Trailing frame with no newline before EOF.
                eof -> {ok, Buf, <<>>};
                {error, _} = Err -> Err;
                Data -> read_frame(<<Buf/binary, Data/binary>>, Max)
            end
    end.

handle_line(Line, Version) when is_binary(Line) ->
    %% Trim whitespace
    TrimmedLine = string:trim(Line),
    case TrimmedLine of
        <<>> ->
            Version;
        _ ->
            %% One malformed message must not take the transport down
            %% with it: stdio has a single process serving every
            %% request, so an uncaught throw here ends the server and
            %% every in-flight call with it.
            try
                process_request(TrimmedLine, Version)
            catch
                Class:Reason:Stack ->
                    logger:error(
                        "barrel_mcp stdio: request crashed: ~p:~p~n~p",
                        [Class, Reason, Stack]
                    ),
                    send_response(
                        barrel_mcp_protocol:error_response(
                            null, -32603, <<"Internal error">>
                        )
                    ),
                    Version
            end
    end;
handle_line(Line, Version) when is_list(Line) ->
    handle_line(list_to_binary(Line), Version).

%% `Version' is what a previous `initialize' on this connection settled
%% on. stdio has no session to record it against and no header to carry
%% it, so the transport remembers it, and returns whatever the exchange
%% negotiated so the caller can carry it forward. Batch acceptance is
%% the first rule that depends on it.
process_request(Line, Version) ->
    case barrel_mcp_protocol:decode(Line) of
        {ok, Request} ->
            case barrel_mcp_protocol:handle(Request, #{protocol_version => Version}) of
                no_response ->
                    %% Notification - no response needed
                    Version;
                {async, Plan} ->
                    %% tools/call returns an async plan; drive it
                    %% synchronously here. stdio is single-threaded;
                    %% the worker reports back via mailbox.
                    Response = barrel_mcp_protocol:drive_async_plan(
                        Plan, 60000
                    ),
                    send_response(Response),
                    Version;
                Response ->
                    send_response(Response),
                    negotiated(Response, Version)
            end;
        {error, too_deep} ->
            send_response(
                barrel_mcp_protocol:error_response(
                    null, -32600, <<"Request nesting is too deep">>
                )
            ),
            Version;
        {error, parse_error} ->
            ErrorResponse = barrel_mcp_protocol:error_response(
                null, -32700, <<"Parse error">>
            ),
            send_response(ErrorResponse),
            Version
    end.

%% The revision an `initialize' exchange settled on, read back off the
%% answer we just produced rather than re-derived from the request.
negotiated(#{<<"result">> := #{<<"protocolVersion">> := V}}, _Version) when is_binary(V) ->
    V;
negotiated(_Response, Version) ->
    Version.

send_response(Response) ->
    ResponseJson = barrel_mcp_protocol:encode(Response),
    io:format("~s~n", [ResponseJson]).
