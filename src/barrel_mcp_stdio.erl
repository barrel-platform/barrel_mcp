%%%-------------------------------------------------------------------
%%% @doc stdio transport for MCP.
%%%
%%% Handles MCP protocol over stdin/stdout for Claude Desktop integration.
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

%% @doc Start stdio server (blocking).
%% Reads JSON-RPC from stdin, writes responses to stdout.
-spec start() -> ok.
start() ->
    %% Set binary mode for stdin/stdout
    ok = io:setopts(standard_io, [binary, {encoding, latin1}]),
    loop().

%% @doc Start as a supervised gen_server.
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
