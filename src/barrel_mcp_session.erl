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
    cleanup_expired/1,
    %% Capability tracking (set during MCP `initialize').
    set_client_capabilities/2,
    has_sampling/1,
    list_sampling_capable/0,
    %% sse_pid management.
    set_sse_pid/2,
    get_sse_pid/1,
    %% Resource subscription tracking (server-side, used to emit
    %% notifications/resources/updated when an exposed resource changes).
    subscribe_resource/2,
    unsubscribe_resource/2,
    subscribers_for/1,
    %% Server -> client request via the session's SSE channel.
    sampling_create_message/3,
    deliver_response/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SESSION_TABLE, barrel_mcp_sessions).
-define(SUBSCRIPTIONS_TABLE, barrel_mcp_resource_subs).
-define(PENDING_TABLE, barrel_mcp_pending_requests).
-define(CLEANUP_INTERVAL, 60000). %% 1 minute
-define(DEFAULT_SAMPLING_TIMEOUT, 30000).

-record(mcp_session, {
    id :: binary(),
    created_at :: integer(),
    last_activity :: integer(),
    client_info :: map(),
    client_capabilities :: map(),
    protocol_version :: binary(),
    sse_pid :: pid() | undefined  %% Process handling SSE stream
}).

-record(pending, {
    id :: binary(),
    session_id :: binary(),
    caller :: pid(),
    caller_ref :: reference(),
    expires_at :: integer()
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
        client_capabilities = maps:get(client_capabilities, Opts, #{}),
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

%% @doc Set the client_capabilities map for a session. Called from the
%% protocol handler after parsing the `initialize' request.
-spec set_client_capabilities(binary(), map()) -> ok | {error, not_found}.
set_client_capabilities(SessionId, Capabilities) when is_map(Capabilities) ->
    case ets:lookup(?SESSION_TABLE, SessionId) of
        [{_, Session}] ->
            Updated = Session#mcp_session{client_capabilities = Capabilities},
            true = ets:insert(?SESSION_TABLE, {SessionId, Updated}),
            ok;
        [] ->
            {error, not_found}
    end.

%% @doc Whether a session declared sampling capability in its initialize
%% request.
-spec has_sampling(binary()) -> boolean().
has_sampling(SessionId) ->
    case ets:lookup(?SESSION_TABLE, SessionId) of
        [{_, #mcp_session{client_capabilities = Caps}}] ->
            maps:is_key(<<"sampling">>, Caps);
        [] ->
            false
    end.

%% @doc List session ids whose client declared sampling capability.
-spec list_sampling_capable() -> [binary()].
list_sampling_capable() ->
    ets:foldl(fun({Id, #mcp_session{client_capabilities = Caps}}, Acc) ->
        case maps:is_key(<<"sampling">>, Caps) of
            true -> [Id | Acc];
            false -> Acc
        end
    end, [], ?SESSION_TABLE).

%% @doc Set the SSE process pid for a session.
-spec set_sse_pid(binary(), pid() | undefined) -> ok | {error, not_found}.
set_sse_pid(SessionId, Pid) ->
    case ets:lookup(?SESSION_TABLE, SessionId) of
        [{_, Session}] ->
            Updated = Session#mcp_session{sse_pid = Pid},
            true = ets:insert(?SESSION_TABLE, {SessionId, Updated}),
            ok;
        [] -> {error, not_found}
    end.

-spec get_sse_pid(binary()) -> {ok, pid()} | {error, not_found | no_sse}.
get_sse_pid(SessionId) ->
    case ets:lookup(?SESSION_TABLE, SessionId) of
        [{_, #mcp_session{sse_pid = undefined}}] -> {error, no_sse};
        [{_, #mcp_session{sse_pid = Pid}}] when is_pid(Pid) -> {ok, Pid};
        [] -> {error, not_found}
    end.

%% @doc Subscribe a session to resource updates for a given URI.
-spec subscribe_resource(binary(), binary()) -> ok.
subscribe_resource(SessionId, Uri)
        when is_binary(SessionId), is_binary(Uri) ->
    _ = ensure_subs_table(),
    true = ets:insert(?SUBSCRIPTIONS_TABLE, {{SessionId, Uri}}),
    ok.

-spec unsubscribe_resource(binary(), binary()) -> ok.
unsubscribe_resource(SessionId, Uri) ->
    _ = ensure_subs_table(),
    true = ets:delete(?SUBSCRIPTIONS_TABLE, {SessionId, Uri}),
    ok.

%% @doc Return all session ids that subscribed to a URI.
-spec subscribers_for(binary()) -> [binary()].
subscribers_for(Uri) when is_binary(Uri) ->
    _ = ensure_subs_table(),
    %% match-spec to find all {SessionId, Uri} for the given Uri
    Pattern = {{'$1', Uri}},
    Match = [{Pattern, [], ['$1']}],
    ets:select(?SUBSCRIPTIONS_TABLE, Match).

%% @doc Send `sampling/createMessage' to the client behind a session and
%% wait for the response. The session must (a) exist, (b) have an active
%% sse_pid, and (c) have declared sampling capability in initialize.
-spec sampling_create_message(binary(), map(), map()) ->
    {ok, map(), map()}
  | {error, timeout | not_supported | no_sse | not_found | term()}.
sampling_create_message(SessionId, Params, Opts) ->
    case has_sampling(SessionId) of
        false -> {error, not_supported};
        true ->
            case get_sse_pid(SessionId) of
                {error, _} = E -> E;
                {ok, Pid} -> do_sampling(SessionId, Pid, Params, Opts)
            end
    end.

%% @doc Deliver a JSON-RPC response from the client back to the waiting
%% caller. Called by the HTTP handler when an inbound POST contains a
%% `result' or `error' for a server-initiated id.
-spec deliver_response(binary() | integer(), map()) -> ok | {error, unknown_id}.
deliver_response(Id, Response) ->
    Key = id_to_binary(Id),
    _ = ensure_pending_table(),
    case ets:lookup(?PENDING_TABLE, Key) of
        [{_, #pending{caller = Caller, caller_ref = Ref}}] ->
            true = ets:delete(?PENDING_TABLE, Key),
            Caller ! {sampling_response, Ref, Response},
            ok;
        [] ->
            {error, unknown_id}
    end.

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
    %% Create ETS tables if they don't exist
    _ = ensure_session_table(),
    _ = ensure_subs_table(),
    _ = ensure_pending_table(),
    %% Schedule periodic cleanup
    _ = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
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
    client_capabilities = Caps,
    protocol_version = ProtocolVersion,
    sse_pid = SsePid
}) ->
    #{
        id => Id,
        created_at => CreatedAt,
        last_activity => LastActivity,
        client_info => ClientInfo,
        client_capabilities => Caps,
        protocol_version => ProtocolVersion,
        sse_pid => SsePid
    }.

%% ============================================================================
%% Internal helpers (table init + sampling implementation)
%% ============================================================================

ensure_session_table() ->
    case ets:whereis(?SESSION_TABLE) of
        undefined ->
            ets:new(?SESSION_TABLE, [
                named_table, public, set,
                {read_concurrency, true},
                {write_concurrency, true}
            ]);
        _ -> ok
    end.

ensure_subs_table() ->
    case ets:whereis(?SUBSCRIPTIONS_TABLE) of
        undefined ->
            ets:new(?SUBSCRIPTIONS_TABLE, [
                named_table, public, set,
                {read_concurrency, true}
            ]);
        _ -> ok
    end.

ensure_pending_table() ->
    case ets:whereis(?PENDING_TABLE) of
        undefined ->
            ets:new(?PENDING_TABLE, [
                named_table, public, set,
                {read_concurrency, true}
            ]);
        _ -> ok
    end.

do_sampling(SessionId, SsePid, Params, Opts) ->
    Timeout = maps:get(timeout_ms, Opts, ?DEFAULT_SAMPLING_TIMEOUT),
    RequestId = generate_request_id(),
    Ref = make_ref(),
    Pending = #pending{
        id = RequestId,
        session_id = SessionId,
        caller = self(),
        caller_ref = Ref,
        expires_at = erlang:system_time(millisecond) + Timeout
    },
    _ = ensure_pending_table(),
    true = ets:insert(?PENDING_TABLE, {RequestId, Pending}),
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => RequestId,
        <<"method">> => <<"sampling/createMessage">>,
        <<"params">> => Params
    },
    SsePid ! {sse_send_message, Request},
    receive
        {sampling_response, Ref, #{<<"result">> := Result} = R} ->
            Usage = maps:get(<<"usage">>, Result, maps:get(usage, R, #{})),
            {ok, Result, Usage};
        {sampling_response, Ref, #{<<"error">> := Err}} ->
            {error, {client_error, Err}}
    after Timeout ->
        true = ets:delete(?PENDING_TABLE, RequestId),
        {error, timeout}
    end.

generate_request_id() ->
    <<"sampling-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

id_to_binary(Id) when is_binary(Id) -> Id;
id_to_binary(Id) when is_integer(Id) -> integer_to_binary(Id);
id_to_binary(Id) -> iolist_to_binary(io_lib:format("~p", [Id])).
