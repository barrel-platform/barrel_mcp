%%%-------------------------------------------------------------------
%%% @doc Federation registry for connected MCP clients.
%%%
%%% Lets a host application keep one supervised `barrel_mcp_client'
%%% per remote MCP server, looked up by an opaque `ServerId' the host
%%% chooses (typically a binary name like `<<"github">>'). Tool-name
%%% namespacing across servers is the host's policy and is not
%%% enforced here.
%%%
%%% The registry is the supervision tree: {@link barrel_mcp_client_sup}
%%% holds one {@link barrel_mcp_client_shell} per `ServerId', and the
%%% shell holds the client. A restart keeps the id bound to the new
%%% pid, and there is no second table to fall out of step with it.
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
%% already holds that id, and `{restarting, ServerId}' while its shell
%% is still retrying a failed restart of it.
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
    case barrel_mcp_client_sup:start_child(ServerId, Spec) of
        {ok, Shell} ->
            case barrel_mcp_client_shell:client(Shell) of
                Pid when is_pid(Pid) -> {ok, Pid};
                _ -> {error, {restarting, ServerId}}
            end;
        {error, {already_started, Shell}} ->
            case barrel_mcp_client_shell:client(Shell) of
                Pid when is_pid(Pid) -> {error, {already_registered, Pid}};
                _ -> {error, {restarting, ServerId}}
            end;
        {error, {shutdown, Reason}} ->
            %% The shell's client refused to start, so the shell shut
            %% itself down: the id is free again and the reason is
            %% the client's.
            {error, unwrap_start_error(Reason)};
        {error, _} = Err ->
            Err
    end.

unwrap_start_error({failed_to_start_child, client, Reason}) -> Reason;
unwrap_start_error(Reason) -> Reason.

%% @doc Stop the client worker registered as `ServerId'. Returns
%% `{error, not_found}' if no worker holds that id.
-spec stop_client(term()) -> ok | {error, not_found}.
stop_client(ServerId) ->
    case supervisor:terminate_child(?SUP, ServerId) of
        ok ->
            %% A temporary child's spec goes with it; this only matters
            %% for a spec left behind, and either answer is fine.
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
        {_, Shell, _, _} when is_pid(Shell) ->
            case barrel_mcp_client_shell:client(Shell) of
                Pid when is_pid(Pid) -> Pid;
                _ -> undefined
            end;
        _ ->
            undefined
    end.

%% @doc Snapshot the registry as `[{ServerId, Pid}]'.
-spec list_clients() -> [{term(), pid()}].
list_clients() ->
    [
        {Id, Pid}
     || {Id, Shell, _, _} <- supervisor:which_children(?SUP),
        is_pid(Shell),
        Pid <- [barrel_mcp_client_shell:client(Shell)],
        is_pid(Pid)
    ].
