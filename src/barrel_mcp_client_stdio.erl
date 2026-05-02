%%%-------------------------------------------------------------------
%%% @doc stdio transport for `barrel_mcp_client'.
%%%
%%% Spawns the configured executable as an Erlang port, frames stdin
%%% as line-delimited JSON-RPC, and forwards each complete line to
%%% the owning client gen_statem as `{mcp_in, self(), Json}'.
%%%
%%% A line is "complete" when cowboy delivers `{eol, _}'; partial
%%% reads (`{noeol, _}') are buffered until the matching `{eol, _}'
%%% arrives. The default 1 MiB line limit matches the previous
%%% in-process implementation.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_stdio).

-behaviour(gen_server).
-behaviour(barrel_mcp_client_transport).

%% Transport API
-export([connect/2, send/2, close/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    owner :: pid(),
    port :: port() | undefined,
    buffer = <<>> :: binary()
}).

-define(LINE_LIMIT, 1048576).

%%====================================================================
%% Transport API
%%====================================================================

connect(Owner, #{command := Cmd} = Opts) ->
    gen_server:start_link(?MODULE, {Owner, Cmd, maps:get(args, Opts, []),
                                    maps:get(env, Opts, [])}, []).

send(Pid, Body) ->
    gen_server:call(Pid, {send, iolist_to_binary(Body)}, 5000).

close(Pid) ->
    gen_server:cast(Pid, close).

%%====================================================================
%% gen_server
%%====================================================================

init({Owner, Cmd, Args, Env}) ->
    process_flag(trap_exit, true),
    PortOpts = [
        {args, Args},
        {line, ?LINE_LIMIT},
        binary,
        use_stdio,
        exit_status,
        hide
    ] ++ env_opt(Env),
    try open_port({spawn_executable, Cmd}, PortOpts) of
        Port when is_port(Port) ->
            {ok, #state{owner = Owner, port = Port}}
    catch
        error:Reason ->
            {stop, {spawn_failed, Cmd, Reason}}
    end.

handle_call({send, Body}, _From, #state{port = Port} = State) ->
    try
        true = port_command(Port, [Body, $\n]),
        {reply, ok, State}
    catch
        error:Reason ->
            {reply, {error, Reason}, State}
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(close, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% A complete line — emit it.
handle_info({Port, {data, {eol, Line}}},
            #state{port = Port, owner = Owner, buffer = Buf} = State) ->
    Full = <<Buf/binary, Line/binary>>,
    Owner ! {mcp_in, self(), Full},
    {noreply, State#state{buffer = <<>>}};
%% A partial line — buffer it until the eol arrives.
handle_info({Port, {data, {noeol, Chunk}}},
            #state{port = Port, buffer = Buf} = State) ->
    {noreply, State#state{buffer = <<Buf/binary, Chunk/binary>>}};
handle_info({Port, {exit_status, Status}},
            #state{port = Port, owner = Owner} = State) ->
    Owner ! {mcp_closed, self(), {exit_status, Status}},
    {stop, {shutdown, {exit_status, Status}}, State#state{port = undefined}};
handle_info({'EXIT', Port, Reason}, #state{port = Port, owner = Owner} = State) ->
    Owner ! {mcp_closed, self(), Reason},
    {stop, {shutdown, Reason}, State#state{port = undefined}};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = Port, owner = Owner}) ->
    case Port of
        P when is_port(P) ->
            catch port_close(P);
        _ ->
            ok
    end,
    Owner ! {mcp_closed, self(), terminated},
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal
%%====================================================================

env_opt([]) -> [];
env_opt(Env) -> [{env, Env}].
