%%%-------------------------------------------------------------------
%%% @doc Supervisor of the client shells.
%%%
%%% Each child is a {@link barrel_mcp_client_shell}, one per
%%% `ServerId', holding one connection to one MCP server and that
%%% connection's own restart budget. Shells are temporary here: a
%%% shell that ends, because its client left normally or exhausted its
%%% budget, is not restarted and its id becomes free, and the other
%%% shells never notice. Hosts start them through
%%% `barrel_mcp_clients:start_client/2'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_sup).

-behaviour(supervisor).

-export([start_link/0, start_child/2]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start the shell for `ServerId' with `Spec', the
%% `barrel_mcp_client:connect_spec()'.
-spec start_child(term(), barrel_mcp_client:connect_spec()) ->
    {ok, pid()} | {error, term()}.
start_child(ServerId, Spec) ->
    Child = #{
        id => ServerId,
        start => {barrel_mcp_client_shell, start_link, [ServerId, Spec]},
        restart => temporary,
        shutdown => infinity,
        type => supervisor,
        modules => [barrel_mcp_client_shell]
    },
    supervisor:start_child(?MODULE, Child).

init([]) ->
    %% Shells are temporary, so nothing here ever restarts; the
    %% intensity only bounds a storm of shells dying at once.
    SupFlags = #{strategy => one_for_one, intensity => 100, period => 60},
    {ok, {SupFlags, []}}.
