%%%-------------------------------------------------------------------
%%% @doc barrel_mcp top level supervisor.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    Registry = #{
        id => barrel_mcp_registry,
        start => {barrel_mcp_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_mcp_registry]
    },

    Session = #{
        id => barrel_mcp_session,
        start => {barrel_mcp_session, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_mcp_session]
    },

    ClientSup = #{
        id => barrel_mcp_client_sup,
        start => {barrel_mcp_client_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [barrel_mcp_client_sup]
    },

    Clients = #{
        id => barrel_mcp_clients,
        start => {barrel_mcp_clients, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_mcp_clients]
    },

    {ok, {SupFlags, [Registry, Session, ClientSup, Clients]}}.
