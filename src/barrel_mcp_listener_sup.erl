%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Supervisor for HTTP listeners.
%%%
%%% Listeners are started at runtime with caller-supplied config, so
%%% they cannot be static children of {@link barrel_mcp_sup}. They are
%%% added here instead, which gets them the two things a bare spawn
%%% never had: a restart when one crashes, and termination when the
%%% application stops rather than an orphan holding the port.
%%%
%%% `restart => transient', so a deliberate stop stays stopped while a
%%% crash is restarted. The restart intensity bounds a listener that
%%% cannot bind its port, which would otherwise loop.
%%%
%%% == Running without the application ==
%%%
%%% The transports can also be driven with no `barrel_mcp' application
%%% around them, the same way
%%% `barrel_mcp_http_engine:ensure_session_manager/0' copes with a
%%% missing supervisor. When this supervisor is not running, both
%%% functions below fall back to the unsupervised listener and the
%%% caller owns its lifecycle.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_listener_sup).

-behaviour(supervisor).

-export([start_link/0, start_listener/3, stop_listener/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% Low intensity on purpose: a listener whose port is taken fails
    %% on every restart, and looping on that hides the real problem.
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 60},
    {ok, {SupFlags, []}}.

%% @doc Start a listener under supervision, or standalone when the
%% supervisor is not running.
-spec start_listener(atom(), map(), barrel_mcp_http_engine:config()) ->
    {ok, pid()} | {error, term()}.
start_listener(Name, ListenOpts, EngineConfig) ->
    case whereis(?MODULE) of
        undefined ->
            barrel_mcp_http_listener:start(Name, ListenOpts, EngineConfig);
        _ ->
            supervised_start(Name, ListenOpts, EngineConfig)
    end.

supervised_start(Name, ListenOpts, EngineConfig) ->
    Spec = #{
        id => Name,
        start => {barrel_mcp_http_listener, start_link, [Name, ListenOpts, EngineConfig]},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [barrel_mcp_http_listener]
    },
    case supervisor:start_child(?MODULE, Spec) of
        {error, already_present} ->
            %% A spec left behind by a listener that terminated without
            %% going through stop_listener/1. Clear it and retry, or
            %% starting the same listener again would fail forever.
            _ = supervisor:delete_child(?MODULE, Name),
            supervisor:start_child(?MODULE, Spec);
        Result ->
            Result
    end.

%% @doc Stop a listener and forget its child spec, so the same name can
%% be started again.
-spec stop_listener(atom()) -> ok | {error, not_found}.
stop_listener(Name) ->
    case whereis(?MODULE) of
        undefined ->
            barrel_mcp_http_listener:stop(Name);
        _ ->
            case supervisor:terminate_child(?MODULE, Name) of
                ok ->
                    _ = supervisor:delete_child(?MODULE, Name),
                    ok;
                {error, not_found} ->
                    %% Possibly started before this supervisor existed.
                    barrel_mcp_http_listener:stop(Name)
            end
    end.
