%%%-------------------------------------------------------------------
%%% @doc One supervisor per client, holding that client's restart
%%% budget so a client that cannot come back exhausts its own budget
%%% and nobody else's.
%%%
%%% The client is a transient child: a crash restarts it under the
%%% same `ServerId', a normal exit (the server closed the connection)
%%% does not, and since the client is the shell's only significant
%%% child the shell shuts itself down when that happens, which frees
%%% the id. A budget exhausted ends the shell the same way.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_shell).

-behaviour(supervisor).

-export([start_link/2, client/1]).
-export([init/1]).

-define(DEFAULT_INTENSITY, 5).
-define(DEFAULT_PERIOD, 60).

%% @doc Start the shell and, under it, the client for `Spec'. The
%% spec's `restart => #{intensity, period}' is the client's own budget:
%% at most `intensity' restarts in `period' seconds, 5 in 60 by default.
-spec start_link(term(), barrel_mcp_client:connect_spec()) -> {ok, pid()} | {error, term()}.
start_link(ServerId, Spec) ->
    supervisor:start_link(?MODULE, {ServerId, Spec}).

%% @doc The client's pid, `restarting' while a failed restart is being
%% retried, `undefined' when there is none.
-spec client(pid()) -> pid() | restarting | undefined.
client(Shell) ->
    try supervisor:which_children(Shell) of
        [{client, Pid, _, _}] when is_pid(Pid) -> Pid;
        [{client, restarting, _, _}] -> restarting;
        _ -> undefined
    catch
        exit:_ -> undefined
    end.

init({_ServerId, Spec}) ->
    Budget = maps:get(restart, Spec, #{}),
    Flags = #{
        strategy => one_for_one,
        intensity => maps:get(intensity, Budget, ?DEFAULT_INTENSITY),
        period => maps:get(period, Budget, ?DEFAULT_PERIOD),
        auto_shutdown => any_significant
    },
    Child = #{
        id => client,
        start => {barrel_mcp_client, start_link, [Spec]},
        restart => transient,
        significant => true,
        shutdown => 5000,
        type => worker,
        modules => [barrel_mcp_client]
    },
    {ok, {Flags, [Child]}}.
