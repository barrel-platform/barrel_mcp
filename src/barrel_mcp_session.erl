%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc MCP Session Management.
%%%
%%% Provides ETS-based session management for MCP Streamable HTTP transport.
%%% Sessions track client connections, protocol versions, and activity.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_session).

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    create/1,
    get/1,
    update_activity/1,
    delete/1,
    generate_id/0,
    list/0,
    cleanup_expired/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SESSION_TABLE, barrel_mcp_sessions).
-define(CLEANUP_INTERVAL, 60000). %% 1 minute

-record(mcp_session, {
    id :: binary(),
    created_at :: integer(),
    last_activity :: integer(),
    client_info :: map(),
    protocol_version :: binary(),
    sse_pid :: pid() | undefined  %% Process handling SSE stream
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the session manager.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Create a new session.
-spec create(Opts) -> {ok, binary()} when
    Opts :: #{
        client_info => map(),
        protocol_version => binary()
    }.
create(Opts) ->
    SessionId = generate_id(),
    Now = erlang:system_time(millisecond),
    Session = #mcp_session{
        id = SessionId,
        created_at = Now,
        last_activity = Now,
        client_info = maps:get(client_info, Opts, #{}),
        protocol_version = maps:get(protocol_version, Opts, <<"2025-03-26">>),
        sse_pid = undefined
    },
    true = ets:insert(?SESSION_TABLE, {SessionId, Session}),
    {ok, SessionId}.

%% @doc Get a session by ID.
-spec get(binary()) -> {ok, map()} | {error, not_found}.
get(SessionId) ->
    case ets:lookup(?SESSION_TABLE, SessionId) of
        [{_, Session}] ->
            {ok, session_to_map(Session)};
        [] ->
            {error, not_found}
    end.

%% @doc Update last activity timestamp.
-spec update_activity(binary()) -> ok | {error, not_found}.
update_activity(SessionId) ->
    case ets:lookup(?SESSION_TABLE, SessionId) of
        [{_, Session}] ->
            Now = erlang:system_time(millisecond),
            Updated = Session#mcp_session{last_activity = Now},
            true = ets:insert(?SESSION_TABLE, {SessionId, Updated}),
            ok;
        [] ->
            {error, not_found}
    end.

%% @doc Delete a session.
-spec delete(binary()) -> ok.
delete(SessionId) ->
    %% Notify SSE process if exists
    case ets:lookup(?SESSION_TABLE, SessionId) of
        [{_, #mcp_session{sse_pid = Pid}}] when is_pid(Pid) ->
            Pid ! session_terminated;
        _ ->
            ok
    end,
    true = ets:delete(?SESSION_TABLE, SessionId),
    ok.

%% @doc Generate a unique session ID.
-spec generate_id() -> binary().
generate_id() ->
    Rand = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(Rand, lowercase),
    <<"mcp_", Hex/binary>>.

%% @doc List all sessions.
-spec list() -> [map()].
list() ->
    ets:foldl(fun({_, Session}, Acc) ->
        [session_to_map(Session) | Acc]
    end, [], ?SESSION_TABLE).

%% @doc Cleanup sessions older than TTL milliseconds.
-spec cleanup_expired(pos_integer()) -> non_neg_integer().
cleanup_expired(TTL) ->
    Now = erlang:system_time(millisecond),
    Cutoff = Now - TTL,
    Expired = ets:foldl(fun({Id, #mcp_session{last_activity = LastActivity}}, Acc) ->
        case LastActivity < Cutoff of
            true -> [Id | Acc];
            false -> Acc
        end
    end, [], ?SESSION_TABLE),
    lists:foreach(fun(Id) -> delete(Id) end, Expired),
    length(Expired).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Create ETS table if it doesn't exist
    _ = case ets:whereis(?SESSION_TABLE) of
        undefined ->
            ets:new(?SESSION_TABLE, [
                named_table,
                public,
                set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]);
        _ ->
            ok
    end,
    %% Schedule periodic cleanup
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {ok, #{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    %% Default TTL: 30 minutes
    TTL = application:get_env(barrel_mcp, session_ttl, 1800000),
    Cleaned = cleanup_expired(TTL),
    case Cleaned > 0 of
        true ->
            logger:debug("Cleaned up ~p expired MCP sessions", [Cleaned]);
        false ->
            ok
    end,
    erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

session_to_map(#mcp_session{
    id = Id,
    created_at = CreatedAt,
    last_activity = LastActivity,
    client_info = ClientInfo,
    protocol_version = ProtocolVersion,
    sse_pid = SsePid
}) ->
    #{
        id => Id,
        created_at => CreatedAt,
        last_activity => LastActivity,
        client_info => ClientInfo,
        protocol_version => ProtocolVersion,
        sse_pid => SsePid
    }.
