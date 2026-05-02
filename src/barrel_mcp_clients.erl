%%%-------------------------------------------------------------------
%%% @doc Federation registry for connected MCP clients.
%%%
%%% Lets a host application keep one supervised `barrel_mcp_client'
%%% per remote MCP server, looked up by an opaque `ServerId' the host
%%% chooses (typically a binary name like `<<"github">>'). Tool-name
%%% namespacing across servers is the host's policy and is not
%%% enforced here.
%%%
%%% This module is a tiny `gen_server' whose only job is to own the
%%% lookup ETS table (so the table outlives any single caller) and to
%%% serialize registration so two callers cannot race on the same
%%% `ServerId'. Lookups go directly to ETS without crossing the
%%% process boundary.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_clients).

-behaviour(gen_server).

-export([start_link/0,
         start_client/2,
         stop_client/1,
         whereis_client/1,
         list_clients/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TABLE, ?MODULE).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Start the registry. Called by `barrel_mcp_sup'; you don't
%% normally call this directly.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Start a supervised `barrel_mcp_client' worker registered as
%% `ServerId'. Fails with `{already_registered, Pid}' if a worker
%% already holds that id.
%%
%% Example:
%% ```
%% {ok, _} = barrel_mcp_clients:start_client(<<"github">>, #{
%%     transport => {http, <<"https://mcp.github.example/">>},
%%     auth => {bearer, GhToken}
%% }).
%% '''
-spec start_client(term(), barrel_mcp_client:connect_spec()) ->
    {ok, pid()} | {error, term()}.
start_client(ServerId, Spec) ->
    gen_server:call(?MODULE, {start_client, ServerId, Spec}).

%% @doc Stop the client worker registered as `ServerId'. Returns
%% `{error, not_found}' if no worker holds that id.
-spec stop_client(term()) -> ok | {error, not_found}.
stop_client(ServerId) ->
    gen_server:call(?MODULE, {stop_client, ServerId}).

%% @doc Look up a worker pid by its `ServerId'. Returns `undefined' if
%% none is registered. ETS-backed; safe to call from any process.
-spec whereis_client(term()) -> pid() | undefined.
whereis_client(ServerId) ->
    case ets:lookup(?TABLE, ServerId) of
        [{_, Pid, _Ref}] -> Pid;
        [] -> undefined
    end.

%% @doc Snapshot the registry as `[{ServerId, Pid}]'. ETS-backed.
-spec list_clients() -> [{term(), pid()}].
list_clients() ->
    ets:foldl(fun({Id, Pid, _}, Acc) -> [{Id, Pid} | Acc] end, [], ?TABLE).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = ets:new(?TABLE, [set, named_table, protected, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({start_client, ServerId, Spec}, _From, State) ->
    case ets:lookup(?TABLE, ServerId) of
        [{_, Pid, _}] when is_pid(Pid) ->
            {reply, {error, {already_registered, Pid}}, State};
        [] ->
            case barrel_mcp_client_sup:start_child(ServerId, Spec) of
                {ok, Pid} = Ok ->
                    Ref = erlang:monitor(process, Pid),
                    true = ets:insert(?TABLE, {ServerId, Pid, Ref}),
                    {reply, Ok, State};
                Err ->
                    {reply, Err, State}
            end
    end;
handle_call({stop_client, ServerId}, _From, State) ->
    case ets:lookup(?TABLE, ServerId) of
        [{_, Pid, Ref}] ->
            erlang:demonitor(Ref, [flush]),
            true = ets:delete(?TABLE, ServerId),
            barrel_mcp_client:close(Pid),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, State) ->
    %% Client crashed or shut down — remove its registration.
    Match = ets:match_object(?TABLE, {'_', Pid, '_'}),
    [ets:delete(?TABLE, Id) || {Id, _, _} <- Match],
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
