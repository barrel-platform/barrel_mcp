%%%-------------------------------------------------------------------
%%% @doc Supervisor for `barrel_mcp_client' workers.
%%%
%%% Each child is one connection to one MCP server. Hosts spawn
%%% children on demand via `barrel_mcp_clients:start_client/2'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_sup).

-behaviour(supervisor).

-export([start_link/0, start_child/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a new client worker. `Spec' is the
%% `barrel_mcp_client:connect_spec()'.
-spec start_child(term(), barrel_mcp_client:connect_spec()) ->
    {ok, pid()} | {error, term()}.
start_child(ServerId, Spec) ->
    Child = #{
        id => ServerId,
        start => {barrel_mcp_client, start_link, [Spec]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [barrel_mcp_client]
    },
    case supervisor:start_child(?MODULE, Child) of
        {error, already_present} ->
            %% A prior transient child exited normally (e.g. the server closed
            %% the stream) and left its spec behind in a terminated state.
            %% Drop the dead spec so this id can be reconnected.
            _ = supervisor:delete_child(?MODULE, ServerId),
            supervisor:start_child(?MODULE, Child);
        Other ->
            Other
    end.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 60},
    {ok, {SupFlags, []}}.
