%%%-------------------------------------------------------------------
%%% @doc Federation registry for connected MCP clients.
%%%
%%% Lets a host application keep one supervised `barrel_mcp_client'
%%% per remote MCP server, looked up by an opaque `ServerId' the host
%%% chooses (typically a binary name like `<<"github">>'). Tool-name
%%% namespacing across servers is the host's policy and is not
%%% enforced here.
%%%
%%% The registry is the supervisor's child list. A client is a
%%% transient child of {@link barrel_mcp_client_sup} under its
%%% `ServerId', so a restart keeps the id bound to the new pid and
%%% there is no second table to fall out of step with it.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_clients).

-export([
    start_client/2,
    stop_client/1,
    whereis_client/1,
    list_clients/0
]).

-define(SUP, barrel_mcp_client_sup).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Start a supervised `barrel_mcp_client' worker registered as
%% `ServerId'. Fails with `{already_registered, Pid}' if a worker
%% already holds that id, and `{restarting, ServerId}' while the
%% supervisor is still retrying a failed restart of it.
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
    %% `start_child/2' drops a terminated spec to allow a reconnect,
    %% which would also drop one the supervisor is still retrying.
    case lists:keyfind(ServerId, 1, supervisor:which_children(?SUP)) of
        {_, restarting, _, _} ->
            {error, {restarting, ServerId}};
        _ ->
            case barrel_mcp_client_sup:start_child(ServerId, Spec) of
                {ok, _} = Ok -> Ok;
                {error, {already_started, Pid}} -> {error, {already_registered, Pid}};
                {error, _} = Err -> Err
            end
    end.

%% @doc Stop the client worker registered as `ServerId'. Returns
%% `{error, not_found}' if no worker holds that id.
-spec stop_client(term()) -> ok | {error, not_found}.
stop_client(ServerId) ->
    case supervisor:terminate_child(?SUP, ServerId) of
        ok ->
            _ = supervisor:delete_child(?SUP, ServerId),
            ok;
        {error, not_found} ->
            {error, not_found}
    end.

%% @doc Look up a worker pid by its `ServerId'. Returns `undefined' if
%% none is running, including while a restart is pending.
-spec whereis_client(term()) -> pid() | undefined.
whereis_client(ServerId) ->
    case lists:keyfind(ServerId, 1, supervisor:which_children(?SUP)) of
        {_, Pid, _, _} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

%% @doc Snapshot the registry as `[{ServerId, Pid}]'.
-spec list_clients() -> [{term(), pid()}].
list_clients() ->
    [{Id, Pid} || {Id, Pid, _, _} <- supervisor:which_children(?SUP), is_pid(Pid)].
