%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Long-lived notification streams (MCP 2026-07-28).
%%%
%%% `subscriptions/listen' replaced the standalone GET SSE stream and
%%% the `resources/subscribe' RPC. A client opens one by POSTing a
%%% request whose response stream stays open, naming the notification
%%% types it wants; the server sends those and nothing else.
%%%
%%% This module is the registry behind that. Each entry belongs to the
%%% request process holding the stream, and is keyed by that process
%%% together with the JSON-RPC id of the `subscriptions/listen'
%%% request, which is the subscription id on the wire. That id is only
%%% unique per connection, hence the pid in the key.
%%%
%%% Entries are monitored, so a stream whose process dies without
%%% cleaning up does not leak.
%%%
%%% Fan-out reads the table directly rather than going through the
%%% gen_server: a notification broadcast must not queue behind a
%%% registration.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_subscriptions).

-behaviour(gen_server).

-include("barrel_mcp.hrl").

-export([
    start_link/0,
    subscribe/2,
    unsubscribe/1,
    normalize_filter/1,
    list_changed/1,
    resource_updated/2,
    close_all/0,
    count/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, barrel_mcp_subscriptions_table).

%% What a client can ask to be told about. Anything else in the filter
%% is ignored, and the acknowledgment reports back only what we agreed
%% to honour.
-type filter() :: #{
    tools_list_changed => boolean(),
    prompts_list_changed => boolean(),
    resources_list_changed => boolean(),
    resource_subscriptions => [binary()]
}.

-export_type([filter/0]).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Register the calling process as the holder of a subscription.
%%
%% Called from the request process that owns the response stream, so
%% the monitor established here is what cleans up on disconnect.
-spec subscribe(term(), filter()) -> ok.
subscribe(SubId, Filter) ->
    gen_server:call(?MODULE, {subscribe, self(), SubId, Filter}).

-spec unsubscribe(term()) -> ok.
unsubscribe(SubId) ->
    gen_server:call(?MODULE, {unsubscribe, self(), SubId}).

%% @doc Read a client's notification filter off the wire.
%%
%% Unknown keys are dropped rather than rejected: the acknowledgment
%% tells the client what was actually honoured, which is the mechanism
%% the spec gives for a server that does not support a type.
-spec normalize_filter(map()) -> filter().
normalize_filter(Params) when is_map(Params) ->
    Wire =
        case maps:get(<<"notifications">>, Params, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    Flags = [
        {tools_list_changed, <<"toolsListChanged">>},
        {prompts_list_changed, <<"promptsListChanged">>},
        {resources_list_changed, <<"resourcesListChanged">>}
    ],
    Base = lists:foldl(
        fun({Key, WireKey}, Acc) ->
            case maps:get(WireKey, Wire, false) of
                true -> Acc#{Key => true};
                _ -> Acc
            end
        end,
        #{},
        Flags
    ),
    case maps:get(<<"resourceSubscriptions">>, Wire, []) of
        Uris when is_list(Uris) ->
            case [U || U <- Uris, is_binary(U)] of
                [] -> Base;
                Kept -> Base#{resource_subscriptions => Kept}
            end;
        _ ->
            Base
    end.

%% @doc Fan a list-changed notification out to every subscriber that
%% asked for that kind.
-spec list_changed(handler_type()) -> ok.
list_changed(Kind) ->
    case filter_key(Kind) of
        undefined ->
            ok;
        Key ->
            Method = list_changed_method(Kind),
            deliver(
                fun(Filter) -> maps:get(Key, Filter, false) end,
                fun(SubId) -> notification(Method, #{}, SubId) end
            )
    end.

%% @doc Fan a resource update out to the subscribers watching that URI.
-spec resource_updated(binary(), map()) -> ok.
resource_updated(Uri, Extra) ->
    deliver(
        fun(Filter) ->
            lists:member(Uri, maps:get(resource_subscriptions, Filter, []))
        end,
        fun(SubId) ->
            notification(
                <<"notifications/resources/updated">>,
                maps:merge(#{<<"uri">> => Uri}, Extra),
                SubId
            )
        end
    ).

%% @doc Ask every open stream to end gracefully, so a client can tell a
%% clean shutdown from a dropped connection.
-spec close_all() -> ok.
close_all() ->
    lists:foreach(
        fun({{Pid, SubId}, _Filter}) -> Pid ! {mcp_subscription_close, SubId} end,
        entries()
    ).

-spec count() -> non_neg_integer().
count() ->
    length(entries()).

%%====================================================================
%% Fan-out
%%====================================================================

deliver(Wants, Build) ->
    lists:foreach(
        fun({{Pid, SubId}, Filter}) ->
            case Wants(Filter) of
                true -> Pid ! {mcp_notification, SubId, Build(SubId)};
                false -> ok
            end
        end,
        entries()
    ).

entries() ->
    case ets:whereis(?TABLE) of
        undefined -> [];
        _ -> ets:tab2list(?TABLE)
    end.

%% Every message on a subscription carries its id, so a client sharing
%% one channel across subscriptions (stdio) can demultiplex.
notification(Method, Params, SubId) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params#{
            <<"_meta">> => #{?MCP_META_SUBSCRIPTION_ID => SubId}
        }
    }.

filter_key(tool) -> tools_list_changed;
filter_key(prompt) -> prompts_list_changed;
filter_key(resource) -> resources_list_changed;
filter_key(_) -> undefined.

list_changed_method(tool) -> <<"notifications/tools/list_changed">>;
list_changed_method(prompt) -> <<"notifications/prompts/list_changed">>;
list_changed_method(resource) -> <<"notifications/resources/list_changed">>.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    _ = ensure_table(),
    {ok, #{monitors => #{}}}.

ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            ets:new(?TABLE, [
                named_table,
                protected,
                set,
                {read_concurrency, true}
            ]);
        Tid ->
            Tid
    end.

handle_call({subscribe, Pid, SubId, Filter}, _From, State) ->
    true = ets:insert(?TABLE, {{Pid, SubId}, Filter}),
    {reply, ok, monitor_holder(Pid, State)};
handle_call({unsubscribe, Pid, SubId}, _From, State) ->
    true = ets:delete(?TABLE, {Pid, SubId}),
    {reply, ok, demonitor_if_last(Pid, State)};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% A stream that died without unsubscribing takes its entries with it.
handle_info({'DOWN', _Ref, process, Pid, _Reason}, #{monitors := Monitors} = State) ->
    drop_holder(Pid),
    {noreply, State#{monitors => maps:remove(Pid, Monitors)}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

monitor_holder(Pid, #{monitors := Monitors} = State) ->
    case maps:is_key(Pid, Monitors) of
        true -> State;
        false -> State#{monitors => Monitors#{Pid => erlang:monitor(process, Pid)}}
    end.

demonitor_if_last(Pid, #{monitors := Monitors} = State) ->
    case holds_any(Pid) of
        true ->
            State;
        false ->
            case maps:take(Pid, Monitors) of
                {Ref, Rest} ->
                    erlang:demonitor(Ref, [flush]),
                    State#{monitors => Rest};
                error ->
                    State
            end
    end.

holds_any(Pid) ->
    lists:any(fun({{P, _}, _}) -> P =:= Pid end, entries()).

drop_holder(Pid) ->
    lists:foreach(
        fun({{P, _} = Key, _}) ->
            case P =:= Pid of
                true -> ets:delete(?TABLE, Key);
                false -> ok
            end
        end,
        entries()
    ).
