%%%-------------------------------------------------------------------
%%% @doc Elicitation requests, in both modes, and the registry behind
%%% URL mode.
%%%
%%% Form mode collects structured data through the client. Secrets
%%% (passwords, API keys, tokens, payment credentials) **MUST** go
%%% through URL mode instead, where the interaction happens out of band
%%% (`2026-07-28/client/elicitation.mdx:30'). The two have separate
%%% constructors, {@link form/2} and {@link url/3}, so one cannot be
%%% sent as the other.
%%%
%%% URL checks are syntactic: https outside a development flag, no
%%% scheme but http(s), no userinfo. A pre-authenticated URL is not
%%% detectable and stays the caller's obligation
%%% (`2025-11-25/client/elicitation.mdx:716').
%%%
%%% 2025-11-25 URL mode carries an `elicitationId' and signals
%%% completion with `notifications/elicitation/complete', which the
%%% server "MUST only send to the client that initiated" it, keyed on
%%% something other than a session id alone (`elicitation.mdx:403,580').
%%% Entries here are owned by the principal; the session is only where
%%% to deliver. 2026-07-28 dropped the id and registers nothing.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_elicitation).

-behaviour(gen_server).

-export([
    start_link/0,
    form/2,
    form/3,
    url/3,
    url/4,
    complete/2,
    lookup/2,
    forget_session/1,
    inspect_url/1,
    count/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(TABLE, barrel_mcp_elicitations).
-define(SWEEP_INTERVAL, 60 * 1000).
%% Long enough for a real out-of-band flow, short enough that abandoned
%% ones do not accumulate.
-define(DEFAULT_TTL_MS, 15 * 60 * 1000).
-define(DEFAULT_MAX_PER_PRINCIPAL, 20).

-record(elicitation, {
    id :: binary(),
    %% Who may complete this. Never the session id on its own.
    principal :: term(),
    %% Only where to deliver the completion notification.
    session_id :: binary() | undefined,
    host :: binary(),
    created_at :: integer(),
    expires_at :: integer(),
    completed = false :: boolean()
}).

-type action() :: accept | decline | cancel.
-export_type([action/0]).

%%====================================================================
%% Building requests
%%====================================================================

%% @equiv form(Message, Schema, #{})
-spec form(binary(), map()) -> map().
form(Message, Schema) ->
    form(Message, Schema, #{}).

%% @doc Build a form-mode `elicitation/create' params map. `Schema' is
%% the restricted subset the spec allows: a flat object of primitives.
%%
%% Never for secrets; use {@link url/3}. Unchecked, because a schema may
%% name its properties anything.
-spec form(binary(), map(), map()) -> map().
form(Message, Schema, Extra) when is_binary(Message), is_map(Schema) ->
    maps:merge(Extra, #{
        <<"mode">> => <<"form">>,
        <<"message">> => Message,
        <<"requestedSchema">> => Schema
    }).

%% @equiv url(Message, Url, Ctx, #{})
-spec url(binary(), binary(), barrel_mcp_ctx:ctx()) ->
    {ok, map()} | {error, term()}.
url(Message, Url, Ctx) ->
    url(Message, Url, Ctx, #{}).

%% @doc Build a URL-mode `elicitation/create' params map, registering an
%% `elicitationId' when the era needs one. `{error, Reason}' when the
%% URL fails a check: `{bad_scheme, S}', `insecure_url',
%% `url_has_credentials', `url_has_no_host', `malformed_url'.
%%
%% Unchecked, and yours to honour: the URL "MUST NOT include sensitive
%% information about the end-user" and "MUST NOT" be "pre-authenticated
%% to access a protected resource"
%% (`2025-11-25/client/elicitation.mdx:715').
-spec url(binary(), binary(), barrel_mcp_ctx:ctx(), map()) ->
    {ok, map()} | {error, term()}.
url(Message, Url, Ctx, Extra) when is_binary(Message), is_binary(Url) ->
    case check_url(Url) of
        {error, _} = Err ->
            Err;
        {ok, Host} ->
            Base = maps:merge(Extra, #{
                <<"mode">> => <<"url">>,
                <<"message">> => Message,
                <<"url">> => Url
            }),
            with_elicitation_id(Base, Host, Ctx)
    end.

%% 2026-07-28 removed `elicitationId'; 2025-11-25 requires it
%% (`elicitation.mdx:345').
with_elicitation_id(Params, Host, Ctx) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        true ->
            {ok, Params};
        false ->
            Principal = barrel_mcp_ctx:principal(Ctx),
            SessionId = barrel_mcp_ctx:session_id(Ctx),
            case gen_server:call(?MODULE, {create, Principal, SessionId, Host}) of
                {ok, Id} -> {ok, Params#{<<"elicitationId">> => Id}};
                {error, _} = Err -> Err
            end
    end.

%%====================================================================
%% Registry
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Mark an elicitation complete and notify the client that started
%% it. Authorised against the owning principal, and terminal.
-spec complete(binary(), barrel_mcp_ctx:ctx() | term()) ->
    ok | {error, not_found | already_complete}.
complete(Id, Ctx) when is_map(Ctx), is_map_key(era, Ctx) ->
    complete(Id, barrel_mcp_ctx:principal(Ctx));
complete(Id, Principal) when is_binary(Id) ->
    gen_server:call(?MODULE, {complete, Id, Principal}).

%% @doc Read one elicitation, for the principal that owns it. Someone
%% else's id reads as not found.
-spec lookup(binary(), term()) -> {ok, map()} | {error, not_found}.
lookup(Id, Principal) when is_binary(Id) ->
    case ets:lookup(?TABLE, Id) of
        [{_, #elicitation{principal = Principal} = E}] -> {ok, to_map(E)};
        _ -> {error, not_found}
    end.

%% @doc Drop every elicitation waiting on a session that has ended.
-spec forget_session(binary()) -> ok.
forget_session(SessionId) when is_binary(SessionId) ->
    gen_server:cast(?MODULE, {forget_session, SessionId}).

-spec count() -> non_neg_integer().
count() ->
    ets:info(?TABLE, size).

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = ets:new(?TABLE, [named_table, protected, set, {read_concurrency, true}]),
    schedule_sweep(),
    {ok, #{}}.

handle_call({create, Principal, SessionId, Host}, _From, State) ->
    case admit(Principal) of
        {error, _} = Err ->
            {reply, Err, State};
        ok ->
            Now = erlang:system_time(millisecond),
            Id = new_id(),
            E = #elicitation{
                id = Id,
                principal = Principal,
                session_id = SessionId,
                host = Host,
                created_at = Now,
                expires_at = Now + ttl_ms()
            },
            true = ets:insert(?TABLE, {Id, E}),
            {reply, {ok, Id}, State}
    end;
handle_call({complete, Id, Principal}, _From, State) ->
    case ets:lookup(?TABLE, Id) of
        [{_, #elicitation{principal = P}}] when P =/= Principal ->
            %% Same answer as an unknown id, so the table cannot be probed.
            {reply, {error, not_found}, State};
        [{_, #elicitation{completed = true}}] ->
            {reply, {error, already_complete}, State};
        [{_, #elicitation{} = E}] ->
            true = ets:insert(?TABLE, {Id, E#elicitation{completed = true}}),
            notify_complete(E),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({forget_session, SessionId}, State) ->
    Dead = ets:foldl(
        fun
            ({Id, #elicitation{session_id = S}}, Acc) when S =:= SessionId -> [Id | Acc];
            (_, Acc) -> Acc
        end,
        [],
        ?TABLE
    ),
    lists:foreach(fun(Id) -> ets:delete(?TABLE, Id) end, Dead),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(sweep, State) ->
    Now = erlang:system_time(millisecond),
    Expired = ets:foldl(
        fun
            ({Id, #elicitation{expires_at = Exp}}, Acc) when Exp =< Now -> [Id | Acc];
            (_, Acc) -> Acc
        end,
        [],
        ?TABLE
    ),
    lists:foreach(fun(Id) -> ets:delete(?TABLE, Id) end, Expired),
    schedule_sweep(),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal
%%====================================================================

schedule_sweep() ->
    erlang:send_after(?SWEEP_INTERVAL, self(), sweep).

ttl_ms() ->
    application:get_env(barrel_mcp, elicitation_ttl_ms, ?DEFAULT_TTL_MS).

%% Expiry alone is not a bound: a peer can open far more inside one ttl
%% than it could ever answer.
admit(Principal) ->
    Max = application:get_env(
        barrel_mcp, max_elicitations_per_principal, ?DEFAULT_MAX_PER_PRINCIPAL
    ),
    Live = ets:foldl(
        fun
            ({_, #elicitation{principal = P, completed = false}}, N) when P =:= Principal ->
                N + 1;
            (_, N) ->
                N
        end,
        0,
        ?TABLE
    ),
    case Live >= Max of
        true -> {error, too_many_elicitations};
        false -> ok
    end.

%% The id travels in a URL and authorises a completion.
new_id() ->
    base64:encode(crypto:strong_rand_bytes(24), #{mode => urlsafe, padding => false}).

%% "MUST only send the notification to the client that initiated the
%% elicitation request" (`2025-11-25/client/elicitation.mdx:403').
notify_complete(#elicitation{session_id = undefined}) ->
    ok;
notify_complete(#elicitation{id = Id, session_id = SessionId}) ->
    _ = barrel_mcp_session:send_notification(
        SessionId,
        <<"notifications/elicitation/complete">>,
        #{<<"elicitationId">> => Id}
    ),
    ok.

to_map(#elicitation{} = E) ->
    #{
        id => E#elicitation.id,
        host => E#elicitation.host,
        session_id => E#elicitation.session_id,
        created_at => E#elicitation.created_at,
        expires_at => E#elicitation.expires_at,
        completed => E#elicitation.completed
    }.

%%====================================================================
%% URL checks
%%====================================================================

%% @doc Run the URL checks and return the host. Both ends use it: the
%% client must not offer a URL that fails them either.
-spec inspect_url(binary()) -> {ok, binary()} | {error, term()}.
inspect_url(Url) when is_binary(Url) ->
    check_url(Url);
inspect_url(_Url) ->
    {error, malformed_url}.

%% Returns the host, which is what gets logged: a capability would hide
%% in the path or query.
check_url(Url) ->
    case uri_string:parse(Url) of
        {error, _, _} ->
            {error, malformed_url};
        Parsed when is_map(Parsed) ->
            check_parsed(Parsed)
    end.

check_parsed(#{userinfo := _}) ->
    {error, url_has_credentials};
check_parsed(Parsed) ->
    case {maps:get(scheme, Parsed, undefined), maps:get(host, Parsed, undefined)} of
        {_, undefined} ->
            {error, url_has_no_host};
        {<<"https">>, Host} ->
            {ok, Host};
        {<<"http">>, Host} ->
            case allow_insecure() of
                true -> {ok, Host};
                false -> {error, insecure_url}
            end;
        {undefined, _} ->
            {error, url_has_no_scheme};
        {Scheme, _} ->
            {error, {bad_scheme, Scheme}}
    end.

%% The page behind a URL elicitation is where a credential gets typed,
%% so plain http has to be asked for.
allow_insecure() ->
    case application:get_env(barrel_mcp, allow_insecure_elicitation_url, false) of
        true -> true;
        _ -> false
    end.
