%%%-------------------------------------------------------------------
%%% @doc `subscriptions/listen': the long-lived notification stream
%%% that replaced the standalone GET SSE endpoint and
%%% `resources/subscribe'.
%%%
%%% The stream is driven over real HTTP so ordering, filtering and
%%% cleanup are observed as a client sees them.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_subscriptions_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-import(barrel_mcp_test_helpers, [wait_until/2, header/2, url/1]).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_testcase/2,
    end_per_testcase/2
]).
-export([
    acknowledgment_is_first/1,
    tools_list_changed_delivered/1,
    filter_excludes_other_kinds/1,
    resource_subscription_filters_by_uri/1,
    two_subscriptions_demultiplex/1,
    unsupported_type_omitted_from_ack/1,
    disconnect_cleans_up/1,
    graceful_close_sends_response/1,
    keepalive_comment_sent/1,
    legacy_cannot_listen/1
]).

-export([a_tool/1, a_resource/1]).

-define(BASE_PORT, 21600).
-define(MODERN, <<"2026-07-28">>).

all() ->
    [
        acknowledgment_is_first,
        tools_list_changed_delivered,
        filter_excludes_other_kinds,
        resource_subscription_filters_by_uri,
        two_subscriptions_demultiplex,
        unsupported_type_omitted_from_ack,
        disconnect_cleans_up,
        graceful_close_sends_response,
        keepalive_comment_sent,
        legacy_cannot_listen
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp:reg_resource(<<"watched">>, ?MODULE, a_resource, #{
        uri => <<"file:///watched">>
    }),
    Config.

end_per_suite(_Config) ->
    barrel_mcp_registry:unreg(resource, <<"watched">>),
    application:stop(barrel_mcp),
    ok.

init_per_testcase(TC, Config) ->
    Port = barrel_mcp_test_helpers:case_port(?BASE_PORT, TC, all()),
    %% Only the keep-alive case wants a chatty stream; elsewhere the
    %% comments are noise the other assertions have to see past.
    Keepalive =
        case TC of
            keepalive_comment_sent -> 200;
            _ -> 60000
        end,
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => Port,
        session_enabled => true,
        subscription_keepalive_ms => Keepalive
    }),
    [{port, Port} | Config].

end_per_testcase(_TC, _Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    %% Every stream must be gone before the next case runs. Waiting
    %% here rather than sleeping means a leak fails a test instead of
    %% quietly polluting the one after it.
    wait_until(fun() -> barrel_mcp_subscriptions:count() =:= 0 end, 5000),
    ?assertEqual(0, barrel_mcp_subscriptions:count()),
    ok.

a_tool(_Args) -> <<"ok">>.

a_resource(_Args) -> <<"body">>.

%%====================================================================
%% Ordering and delivery
%%====================================================================

acknowledgment_is_first(Config) ->
    {Ref, _} = listen(Config, 1, #{<<"toolsListChanged">> => true}),
    Ack = next_event(Ref),
    ?assertEqual(
        <<"notifications/subscriptions/acknowledged">>,
        maps:get(<<"method">>, Ack)
    ),
    Params = maps:get(<<"params">>, Ack),
    ?assertEqual(1, subscription_id(Ack)),
    ?assertEqual(
        #{<<"toolsListChanged">> => true},
        maps:get(<<"notifications">>, Params)
    ),
    close(Ref).

tools_list_changed_delivered(Config) ->
    {Ref, _} = listen(Config, 7, #{<<"toolsListChanged">> => true}),
    _Ack = next_event(Ref),
    ok = barrel_mcp:reg_tool(<<"late_tool">>, ?MODULE, a_tool, #{}),
    try
        Note = next_event(Ref),
        ?assertEqual(
            <<"notifications/tools/list_changed">>,
            maps:get(<<"method">>, Note)
        ),
        %% Every message carries the id of the request that opened the
        %% stream, so a client on one channel can demultiplex.
        ?assertEqual(7, subscription_id(Note))
    after
        barrel_mcp_registry:unreg(tool, <<"late_tool">>),
        close(Ref)
    end.

%% The server must not send a type the client did not ask for.
filter_excludes_other_kinds(Config) ->
    {Ref, _} = listen(Config, 1, #{<<"promptsListChanged">> => true}),
    _Ack = next_event(Ref),
    ok = barrel_mcp:reg_tool(<<"ignored_tool">>, ?MODULE, a_tool, #{}),
    try
        ?assertEqual(timeout, next_event(Ref, 300))
    after
        barrel_mcp_registry:unreg(tool, <<"ignored_tool">>),
        close(Ref)
    end.

resource_subscription_filters_by_uri(Config) ->
    {Ref, _} = listen(Config, 1, #{
        <<"resourceSubscriptions">> => [<<"file:///watched">>]
    }),
    _Ack = next_event(Ref),
    %% A URI we did not name produces nothing.
    ok = barrel_mcp:notify_resource_updated(<<"file:///other">>),
    ?assertEqual(timeout, next_event(Ref, 300)),
    ok = barrel_mcp:notify_resource_updated(<<"file:///watched">>),
    Note = next_event(Ref),
    ?assertEqual(
        <<"notifications/resources/updated">>,
        maps:get(<<"method">>, Note)
    ),
    ?assertEqual(
        <<"file:///watched">>,
        maps:get(<<"uri">>, maps:get(<<"params">>, Note))
    ),
    close(Ref).

two_subscriptions_demultiplex(Config) ->
    {RefA, _} = listen(Config, 11, #{<<"toolsListChanged">> => true}),
    {RefB, _} = listen(Config, 22, #{<<"toolsListChanged">> => true}),
    ?assertEqual(11, subscription_id(next_event(RefA))),
    ?assertEqual(22, subscription_id(next_event(RefB))),
    ok = barrel_mcp:reg_tool(<<"shared_tool">>, ?MODULE, a_tool, #{}),
    try
        ?assertEqual(11, subscription_id(next_event(RefA))),
        ?assertEqual(22, subscription_id(next_event(RefB)))
    after
        barrel_mcp_registry:unreg(tool, <<"shared_tool">>),
        close(RefA),
        close(RefB)
    end.

%% A type the server does not honour is left out of the acknowledgment,
%% which is how the client learns it will not arrive.
unsupported_type_omitted_from_ack(Config) ->
    {Ref, _} = listen(Config, 1, #{
        <<"toolsListChanged">> => true,
        <<"somethingElse">> => true
    }),
    Ack = next_event(Ref),
    Honoured = maps:get(<<"notifications">>, maps:get(<<"params">>, Ack)),
    ?assertEqual(#{<<"toolsListChanged">> => true}, Honoured),
    close(Ref).

%%====================================================================
%% Lifecycle
%%====================================================================

disconnect_cleans_up(Config) ->
    ?assertEqual(0, barrel_mcp_subscriptions:count()),
    {Ref, _} = listen(Config, 1, #{<<"toolsListChanged">> => true}),
    _Ack = next_event(Ref),
    ?assertEqual(1, barrel_mcp_subscriptions:count()),
    close(Ref),
    %% The stream process is monitored, so its entry goes with it even
    %% though it never got to unsubscribe.
    wait_until(fun() -> barrel_mcp_subscriptions:count() =:= 0 end, 5000),
    ?assertEqual(0, barrel_mcp_subscriptions:count()),
    ok.

graceful_close_sends_response(Config) ->
    {Ref, _} = listen(Config, 5, #{<<"toolsListChanged">> => true}),
    _Ack = next_event(Ref),
    ok = barrel_mcp_subscriptions:close_all(),
    %% "MUST send notifications/cancelled referencing a
    %% subscriptions/listen request ID when it tears down that
    %% subscription stream" (cancellation.mdx:12), and it comes first.
    Cancelled = next_event(Ref),
    ?assertEqual(<<"notifications/cancelled">>, maps:get(<<"method">>, Cancelled)),
    CParams = maps:get(<<"params">>, Cancelled),
    ?assertEqual(5, maps:get(<<"requestId">>, CParams)),
    ?assertEqual(
        5,
        maps:get(?MCP_META_SUBSCRIPTION_ID, maps:get(<<"_meta">>, CParams))
    ),
    Final = next_event(Ref),
    %% A response to the long-lived request, not a notification: that
    %% is what distinguishes a clean end from a dropped connection.
    ?assertEqual(5, maps:get(<<"id">>, Final)),
    Result = maps:get(<<"result">>, Final),
    ?assertEqual(<<"complete">>, maps:get(<<"resultType">>, Result)),
    ?assertEqual(
        5,
        maps:get(?MCP_META_SUBSCRIPTION_ID, maps:get(<<"_meta">>, Result))
    ),
    close(Ref).

%% A quiet stream still has to produce traffic, or intermediaries drop
%% it. SSE comments are the mechanism; clients ignore them.
keepalive_comment_sent(Config) ->
    {Ref, _} = listen(Config, 1, #{<<"toolsListChanged">> => true}),
    _Ack = next_event(Ref),
    ?assertEqual(comment, next_raw_comment(Ref, 2000)),
    close(Ref).

%% The method belongs to this revision; a legacy client has
%% `resources/subscribe' and the GET stream instead.
legacy_cannot_listen(Config) ->
    Port = ?config(port, Config),
    {ok, 200, InitHeaders, _} = hackney:request(
        post, url(Port), json_headers(), init_body(), [with_body]
    ),
    SessionId = header(<<"mcp-session-id">>, InitHeaders),
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 2,
        <<"method">> => <<"subscriptions/listen">>,
        <<"params">> => #{}
    }),
    {ok, 200, _, Resp} = hackney:request(
        post,
        url(Port),
        json_headers() ++ [{<<"mcp-session-id">>, SessionId}],
        Body,
        [with_body]
    ),
    Error = maps:get(<<"error">>, json:decode(Resp)),
    ?assertEqual(?JSONRPC_METHOD_NOT_FOUND, maps:get(<<"code">>, Error)),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

json_headers() ->
    [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>}
    ].

init_body() ->
    json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => <<"2025-11-25">>,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{<<"name">> => <<"subs">>, <<"version">> => <<"1.0">>}
        }
    }).

%% Open a listen stream and return a handle to read events from. The
%% response is consumed incrementally, since it never completes.
listen(Config, Id, Notifications) ->
    Port = ?config(port, Config),
    Params = #{
        <<"notifications">> => Notifications,
        <<"_meta">> => #{
            ?MCP_META_PROTOCOL_VERSION => ?MODERN,
            ?MCP_META_CLIENT_CAPABILITIES => #{}
        }
    },
    Body = json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => <<"subscriptions/listen">>,
        <<"params">> => Params
    }),
    Headers =
        json_headers() ++
            [
                {<<"mcp-protocol-version">>, ?MODERN},
                {<<"mcp-method">>, <<"subscriptions/listen">>}
            ],
    %% A dedicated socket per stream: these responses never complete,
    %% so returning them to the shared pool would block later checkouts.
    {ok, Ref} = hackney:request(
        post,
        url(Port),
        Headers,
        Body,
        [async, {pool, false}, {recv_timeout, 10000}]
    ),
    {Ref, Id}.

close(Ref) ->
    try
        hackney:close(Ref)
    catch
        _:_ -> ok
    end,
    ok.

next_event(Ref) -> next_event(Ref, 5000).

%% Read chunks until a complete SSE data block arrives.
next_event(Ref, Timeout) ->
    collect(Ref, deadline(Timeout), <<>>, data).

next_raw_comment(Ref, Timeout) ->
    collect(Ref, deadline(Timeout), <<>>, comment).

deadline(Timeout) ->
    erlang:monotonic_time(millisecond) + Timeout.

%% The budget is absolute. Restarting it per chunk would let a stream
%% that keeps sending something uninteresting block forever.
remaining(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

collect(Ref, Deadline, Buf, Want) ->
    receive
        {hackney_response, Ref, {status, _, _}} ->
            collect(Ref, Deadline, Buf, Want);
        {hackney_response, Ref, {headers, _}} ->
            collect(Ref, Deadline, Buf, Want);
        {hackney_response, Ref, Chunk} when is_binary(Chunk) ->
            Acc = <<Buf/binary, Chunk/binary>>,
            case take(Acc, Want) of
                {ok, Value} -> Value;
                more -> collect(Ref, Deadline, Acc, Want)
            end;
        {hackney_response, Ref, done} ->
            closed
    after remaining(Deadline) ->
        timeout
    end.

take(Buf, comment) ->
    case binary:match(Buf, <<":\r\n">>) of
        nomatch -> more;
        _ -> {ok, comment}
    end;
take(Buf, data) ->
    case binary:split(Buf, <<"\n\n">>) of
        [Block, _Rest] ->
            case [V || <<"data: ", V/binary>> <- binary:split(Block, <<"\n">>, [global])] of
                [Data | _] -> {ok, json:decode(Data)};
                [] -> more
            end;
        _ ->
            more
    end.

subscription_id(Envelope) ->
    Params = maps:get(<<"params">>, Envelope),
    maps:get(?MCP_META_SUBSCRIPTION_ID, maps:get(<<"_meta">>, Params)).
