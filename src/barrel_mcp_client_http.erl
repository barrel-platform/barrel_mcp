%%%-------------------------------------------------------------------
%%% @doc Streamable HTTP transport for `barrel_mcp_client'.
%%%
%%% Implements MCP's Streamable HTTP transport (2025-03-26 onward) on
%%% the client side:
%%% <ul>
%%%   <li>POST every request with `Accept: application/json,
%%%       text/event-stream'. The server may answer with a single JSON
%%%       envelope or with an SSE stream that interleaves
%%%       server-initiated requests/notifications until the matching
%%%       response arrives.</li>
%%%   <li>GET opens a long-lived SSE channel for unsolicited
%%%       server-to-client traffic. Optional: a server may return 405,
%%%       in which case server messages only arrive on POST streams.</li>
%%%   <li>DELETE on close, with the captured `Mcp-Session-Id'.</li>
%%%   <li>`MCP-Protocol-Version' header echoed on every request after
%%%       the initialize response has been processed by the client.</li>
%%%   <li>401 with `WWW-Authenticate' triggers the configured auth
%%%       refresh; the original request is retried once.</li>
%%% </ul>
%%%
%%% Each parsed SSE event's `data:' payload is forwarded to the owning
%%% client as `{mcp_in, self(), Json}'. The owner sees the same shape
%%% as it does from the stdio transport.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_http).

-behaviour(gen_server).
-behaviour(barrel_mcp_client_transport).

-include("barrel_mcp.hrl").

%% Transport API
-export([connect/2, send/2, close/1]).

%% Public helpers
-export([set_session_id/2, set_protocol_version/2, open_event_stream/1]).
-export([open_subscription/2, close_subscription/1]).
-export([set_tool_headers/2]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(req, {
    body :: binary(),
    status :: undefined | non_neg_integer(),
    headers = [] :: list(),
    buffer = <<>> :: binary(),
    format :: undefined | json | sse,
    retried = false :: boolean()
}).

%% Cap incoming response and SSE buffers so a malicious or
%% misbehaving MCP server cannot drive unbounded memory growth on
%% the host. A request that overflows is closed with a
%% `{response_too_large, ...}' reason; the long-lived SSE stream is
%% torn down and rescheduled.
-define(MAX_RESP_BYTES, 16 * 1024 * 1024).
-define(MAX_SSE_BUFFER_BYTES, 4 * 1024 * 1024).

-record(state, {
    owner :: pid(),
    url :: binary(),
    extra_headers = [] :: list(),
    session_id :: binary() | undefined,
    protocol_version :: binary() | undefined,
    auth :: barrel_mcp_client_auth:t(),
    requests = #{} :: #{reference() => #req{}},
    %% hackney's async stream handle is a connection pid, not a ref.
    sse_ref :: pid() | undefined,
    sse_buffer = <<>> :: binary(),
    sse_last_event_id :: binary() | undefined,
    sse_enabled = false :: boolean(),
    %% How the long-lived stream is opened. Legacy servers hand it out
    %% on a GET; 2026-07-28 removed that endpoint, so a modern one
    %% delivers the same traffic on the response to a
    %% `subscriptions/listen' POST.
    sse_mode = get :: get | {post, binary()},
    %% Per-tool `x-mcp-header' bindings, learned from `tools/list'.
    %% Held here rather than passed per send: the headers are derived
    %% from the body about to go out, and this is where that happens.
    tool_headers = #{} :: #{binary() => [barrel_mcp_headers:param_binding()]}
}).

%%====================================================================
%% Transport API
%%====================================================================

connect(Owner, Opts) ->
    gen_server:start_link(?MODULE, {Owner, Opts}, []).

send(Pid, Body) ->
    gen_server:call(Pid, {send, iolist_to_binary(Body)}, 30000).

close(Pid) ->
    gen_server:cast(Pid, close).

%%====================================================================
%% Public helpers
%%====================================================================

%% @doc Capture the `Mcp-Session-Id' returned on the initialize POST
%% so subsequent requests can echo it.
set_session_id(Pid, SessionId) when is_binary(SessionId); SessionId =:= undefined ->
    gen_server:cast(Pid, {set_session_id, SessionId}).

%% @doc Set the negotiated protocol version. Once set, every outgoing
%% request includes the `MCP-Protocol-Version' header.
set_protocol_version(Pid, Version) when is_binary(Version) ->
    gen_server:cast(Pid, {set_protocol_version, Version}).

%% @doc Open the long-lived GET SSE for unsolicited server messages.
%% Idempotent: a second call while the stream is open is a no-op.
open_event_stream(Pid) ->
    gen_server:cast(Pid, open_event_stream).

%% @doc Open (or replace) the long-lived stream as a
%% `subscriptions/listen' POST carrying `Body'.
%%
%% Replacing rather than adding: one stream whose filter covers
%% everything subscribed is simpler to reason about than several, and
%% the spec's multiple-subscription support is not needed to express
%% it.
-spec open_subscription(pid(), binary()) -> ok.
open_subscription(Pid, Body) when is_binary(Body) ->
    gen_server:cast(Pid, {open_subscription, Body}).

%% @doc Close the long-lived stream and stop reopening it.
-spec close_subscription(pid()) -> ok.
close_subscription(Pid) ->
    gen_server:cast(Pid, close_subscription).

%% @doc Record which tool arguments each tool wants mirrored into
%% headers, as learned from `tools/list'.
-spec set_tool_headers(pid(), map()) -> ok.
set_tool_headers(Pid, Bindings) when is_map(Bindings) ->
    gen_server:cast(Pid, {set_tool_headers, Bindings}).

%%====================================================================
%% gen_server
%%====================================================================

init({Owner, Opts}) ->
    process_flag(trap_exit, true),
    Url =
        case maps:get(url, Opts) of
            U when is_binary(U) -> U;
            U when is_list(U) -> iolist_to_binary(U)
        end,
    Auth = maps:get(auth, Opts, none),
    Headers = lists:map(
        fun({K, V}) -> {to_bin(K), to_bin(V)} end,
        maps:get(headers, Opts, [])
    ),
    SseEnabled = maps:get(open_event_stream, Opts, true),
    {ok, #state{
        owner = Owner,
        url = Url,
        extra_headers = Headers,
        auth = Auth,
        sse_enabled = SseEnabled
    }}.

handle_call({send, Body}, _From, State) ->
    case start_post(Body, false, State) of
        {ok, State1} -> {reply, ok, State1};
        {error, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call(_Msg, _From, State) ->
    {reply, {error, badcall}, State}.

handle_cast({set_session_id, SessionId}, State) ->
    {noreply, State#state{session_id = SessionId}};
handle_cast({set_protocol_version, Version}, State) ->
    {noreply, State#state{protocol_version = Version}};
handle_cast({set_tool_headers, Bindings}, State) ->
    {noreply, State#state{tool_headers = Bindings}};
handle_cast({open_subscription, Body}, State) ->
    State1 = stop_stream(State),
    {noreply,
        start_stream(State1#state{
            sse_enabled = true,
            sse_mode = {post, Body}
        })};
handle_cast(close_subscription, State) ->
    {noreply, (stop_stream(State))#state{sse_enabled = false, sse_mode = get}};
handle_cast(open_event_stream, #state{sse_ref = Ref} = State) when is_pid(Ref) ->
    {noreply, State};
handle_cast(open_event_stream, State) ->
    {noreply, start_stream(State)};
handle_cast(close, State) ->
    _ = send_delete(State),
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% Hackney async response messages.
handle_info(
    {hackney_response, Ref, {status, Status, _Reason}},
    #state{requests = Reqs} = State
) ->
    case maps:find(Ref, Reqs) of
        {ok, R} ->
            {noreply, State#state{requests = Reqs#{Ref => R#req{status = Status}}}};
        error ->
            handle_sse_status(Ref, Status, State)
    end;
handle_info(
    {hackney_response, Ref, {headers, Headers}},
    #state{requests = Reqs} = State
) ->
    case maps:find(Ref, Reqs) of
        {ok, R} ->
            Format = detect_format(Headers),
            R1 = R#req{headers = Headers, format = Format},
            State1 = capture_session_header(Headers, State),
            {noreply, State1#state{requests = Reqs#{Ref => R1}}};
        error ->
            handle_sse_headers(Ref, Headers, State)
    end;
handle_info(
    {hackney_response, Ref, done},
    #state{requests = Reqs, sse_ref = SseRef} = State
) ->
    case maps:find(Ref, Reqs) of
        {ok, R} ->
            State1 = finalize_request(Ref, R, State),
            {noreply, State1};
        error when Ref =:= SseRef ->
            handle_sse_done(State);
        error ->
            {noreply, State}
    end;
handle_info(
    {hackney_response, Ref, {error, Reason}},
    #state{requests = Reqs, sse_ref = SseRef, owner = Owner} = State
) ->
    case maps:is_key(Ref, Reqs) of
        true ->
            Owner ! {mcp_closed, self(), {request_failed, Reason}},
            {noreply, State#state{requests = maps:remove(Ref, Reqs)}};
        false when Ref =:= SseRef ->
            {noreply, State#state{sse_ref = undefined, sse_buffer = <<>>}};
        false ->
            {noreply, State}
    end;
handle_info(
    {hackney_response, Ref, Chunk},
    #state{requests = Reqs, sse_ref = SseRef, owner = Owner} = State
) when
    is_binary(Chunk)
->
    case maps:find(Ref, Reqs) of
        {ok, #req{format = sse, buffer = Buf} = R} ->
            Combined = <<Buf/binary, Chunk/binary>>,
            case byte_size(Combined) > ?MAX_SSE_BUFFER_BYTES of
                true ->
                    %% Drop the request from tracking; further chunks
                    %% for this Ref fall through the unknown-ref clause.
                    Owner ! {mcp_closed, self(), {response_too_large, byte_size(Combined)}},
                    {noreply, State#state{requests = maps:remove(Ref, Reqs)}};
                false ->
                    {Events, NewBuf} = parse_sse(Combined),
                    State1 = forward_sse_events(Events, State),
                    R1 = R#req{buffer = NewBuf},
                    {noreply, State1#state{requests = Reqs#{Ref => R1}}}
            end;
        {ok, #req{buffer = Buf} = R} ->
            Combined = <<Buf/binary, Chunk/binary>>,
            case byte_size(Combined) > ?MAX_RESP_BYTES of
                true ->
                    %% Drop the request from tracking; further chunks
                    %% for this Ref fall through the unknown-ref clause.
                    Owner ! {mcp_closed, self(), {response_too_large, byte_size(Combined)}},
                    {noreply, State#state{requests = maps:remove(Ref, Reqs)}};
                false ->
                    R1 = R#req{buffer = Combined},
                    {noreply, State#state{requests = Reqs#{Ref => R1}}}
            end;
        error when Ref =:= SseRef ->
            handle_sse_chunk(Chunk, State);
        error ->
            {noreply, State}
    end;
handle_info(reopen_sse, #state{sse_enabled = true, sse_ref = undefined} = State) ->
    {noreply, start_stream(State)};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = send_delete(State),
    State#state.owner ! {mcp_closed, self(), terminated},
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% POST request lifecycle
%%====================================================================

start_post(Body, Retried, State) ->
    Headers = build_headers(State) ++ metadata_headers(Body, State#state.tool_headers),
    case
        hackney:request(
            post,
            State#state.url,
            Headers,
            Body,
            [async, {recv_timeout, infinity}]
        )
    of
        {ok, Ref} ->
            Req = #req{body = Body, retried = Retried},
            {ok, State#state{requests = (State#state.requests)#{Ref => Req}}};
        {error, _} = Err ->
            Err
    end.

finalize_request(Ref, #req{format = sse} = _R, #state{requests = Reqs} = State) ->
    %% SSE stream ended (server done). Drop the request slot.
    State#state{requests = maps:remove(Ref, Reqs)};
finalize_request(
    Ref,
    #req{status = 401, retried = false, body = Body, headers = H},
    #state{requests = Reqs, auth = Auth, owner = Owner} = State
) ->
    Www = header_value(<<"www-authenticate">>, H),
    case barrel_mcp_client_auth:refresh(Auth, Www) of
        {ok, NewAuth} ->
            State1 = State#state{
                auth = NewAuth,
                requests = maps:remove(Ref, Reqs)
            },
            case start_post(Body, true, State1) of
                {ok, State2} ->
                    State2;
                {error, _} ->
                    Owner ! {mcp_closed, self(), unauthorized},
                    State1
            end;
        {error, _} ->
            Owner ! {mcp_closed, self(), unauthorized},
            State#state{requests = maps:remove(Ref, Reqs)}
    end;
finalize_request(
    Ref,
    #req{status = Status, buffer = Buf} = _R,
    #state{requests = Reqs, owner = Owner} = State
) when
    Status >= 200, Status < 300
->
    case Buf of
        %% 204 No Content for notifications
        <<>> ->
            ok;
        _ ->
            Owner ! {mcp_in, self(), Buf},
            ok
    end,
    State#state{requests = maps:remove(Ref, Reqs)};
%% A 4xx is not necessarily a transport failure. The 2026-07-28 binding
%% pins several ordinary JSON-RPC errors to a status: an unimplemented
%% method is 404, and a malformed or unservable request is 400. Those
%% are answers, and the spec has the client inspect the body before
%% concluding anything about the connection. Only a body that is not a
%% JSON-RPC message means the peer stopped talking to us.
finalize_request(
    Ref,
    #req{status = Status, buffer = Buf},
    #state{requests = Reqs, owner = Owner} = State
) ->
    _ =
        case is_jsonrpc(Buf) of
            true -> Owner ! {mcp_in, self(), Buf};
            false -> Owner ! {mcp_closed, self(), {http_error, Status, Buf}}
        end,
    State#state{requests = maps:remove(Ref, Reqs)}.

is_jsonrpc(<<>>) ->
    false;
is_jsonrpc(Body) ->
    try json:decode(Body) of
        #{<<"jsonrpc">> := <<"2.0">>} = Msg ->
            maps:is_key(<<"error">>, Msg) orelse maps:is_key(<<"result">>, Msg);
        _ ->
            false
    catch
        _:_ -> false
    end.

%%====================================================================
%% SSE GET stream (unsolicited server-to-client)
%%====================================================================

start_stream(#state{sse_enabled = false} = State) ->
    State;
start_stream(#state{sse_mode = get} = State) ->
    Headers0 = build_headers(State),
    Headers =
        case State#state.sse_last_event_id of
            undefined -> Headers0;
            Id -> [{<<"last-event-id">>, Id} | Headers0]
        end,
    open_stream(get, Headers, <<>>, State);
start_stream(#state{sse_mode = {post, Body}} = State) ->
    %% A modern stream is a response, so it needs the same metadata
    %% headers any other request carries, derived from the same body
    %% the server will compare them against.
    Headers = build_headers(State) ++ metadata_headers(Body, State#state.tool_headers),
    open_stream(post, Headers, Body, State).

open_stream(Method, Headers, Body, State) ->
    case
        hackney:request(
            Method,
            State#state.url,
            Headers,
            Body,
            %% A dedicated socket: this response never completes, so
            %% returning it to the shared pool would block later
            %% checkouts and leave the server's end open after close.
            [async, {pool, false}, {recv_timeout, infinity}]
        )
    of
        {ok, Ref} ->
            State#state{sse_ref = Ref};
        {error, _} ->
            State
    end.

stop_stream(#state{sse_ref = undefined} = State) ->
    State;
stop_stream(#state{sse_ref = Ref} = State) ->
    try
        hackney:close(Ref)
    catch
        _:_ -> ok
    end,
    State#state{sse_ref = undefined, sse_buffer = <<>>}.

handle_sse_status(_Ref, Status, State) when Status >= 200, Status < 300 ->
    {noreply, State};
handle_sse_status(_Ref, _Status, State) ->
    %% Server doesn't support GET SSE (e.g. 405). Quietly drop.
    {noreply, State#state{sse_ref = undefined}}.

handle_sse_headers(_Ref, _Headers, State) ->
    {noreply, State}.

handle_sse_chunk(Chunk, #state{sse_buffer = Buf, owner = Owner} = State) ->
    Combined = <<Buf/binary, Chunk/binary>>,
    case byte_size(Combined) > ?MAX_SSE_BUFFER_BYTES of
        true ->
            %% Drop the long-lived SSE channel; reopen on the next
            %% timer tick so a transient overrun doesn't permanently
            %% disable server-to-client traffic.
            Owner ! {mcp_closed, self(), {response_too_large, byte_size(Combined)}},
            erlang:send_after(1000, self(), reopen_sse),
            {noreply, State#state{
                sse_ref = undefined,
                sse_buffer = <<>>
            }};
        false ->
            {Events, NewBuf} = parse_sse(Combined),
            State1 = forward_sse_events(Events, State),
            {noreply, State1#state{sse_buffer = NewBuf}}
    end.

handle_sse_done(State) ->
    %% Server closed the long-lived stream; reopen in a moment.
    erlang:send_after(1000, self(), reopen_sse),
    {noreply, State#state{sse_ref = undefined, sse_buffer = <<>>}}.

%%====================================================================
%% SSE parsing
%%====================================================================

%% Returns {Events, RemainderBuffer}. An event is `{Id | undefined,
%% Event | undefined, DataBinary}'. We only care about `data:' for
%% MCP, but `id:' is captured for Last-Event-ID resumability.
parse_sse(Buf) ->
    parse_sse(Buf, []).

parse_sse(Buf, Acc) ->
    case binary:split(Buf, <<"\n\n">>) of
        [_] ->
            {lists:reverse(Acc), Buf};
        [Block, Rest] ->
            Event = parse_event_block(Block),
            parse_sse(Rest, [Event | Acc])
    end.

parse_event_block(Block) ->
    Lines = binary:split(Block, <<"\n">>, [global, trim_all]),
    lists:foldl(
        fun(Line, {Id, Ev, DataAcc}) ->
            case Line of
                <<"id: ", V/binary>> -> {V, Ev, DataAcc};
                <<"id:", V/binary>> -> {trim_leading_space(V), Ev, DataAcc};
                <<"event: ", V/binary>> -> {Id, V, DataAcc};
                <<"event:", V/binary>> -> {Id, trim_leading_space(V), DataAcc};
                <<"data: ", V/binary>> -> {Id, Ev, append_data(DataAcc, V)};
                <<"data:", V/binary>> -> {Id, Ev, append_data(DataAcc, trim_leading_space(V))};
                %% comment
                <<":", _/binary>> -> {Id, Ev, DataAcc};
                %% unknown field
                _ -> {Id, Ev, DataAcc}
            end
        end,
        {undefined, undefined, <<>>},
        Lines
    ).

append_data(<<>>, V) -> V;
append_data(Acc, V) -> <<Acc/binary, "\n", V/binary>>.

trim_leading_space(<<" ", R/binary>>) -> R;
trim_leading_space(B) -> B.

forward_sse_events([], State) ->
    State;
forward_sse_events([{Id, _Ev, Data} | Rest], #state{owner = Owner} = State) ->
    case Data of
        <<>> ->
            ok;
        _ ->
            Owner ! {mcp_in, self(), Data},
            ok
    end,
    State1 =
        case Id of
            undefined -> State;
            _ -> State#state{sse_last_event_id = Id}
        end,
    forward_sse_events(Rest, State1).

%%====================================================================
%% Header helpers
%%====================================================================

build_headers(#state{
    extra_headers = Extra,
    session_id = Sid,
    protocol_version = PV,
    auth = Auth
}) ->
    Base = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>}
    ],
    H1 =
        case Sid of
            undefined -> Base;
            _ -> [{<<"mcp-session-id">>, Sid} | Base]
        end,
    H2 =
        case PV of
            undefined -> H1;
            _ -> [{<<"mcp-protocol-version">>, PV} | H1]
        end,
    H3 =
        case barrel_mcp_client_auth:header(Auth) of
            {ok, AuthHdr} -> [{<<"authorization">>, AuthHdr} | H2];
            _ -> H2
        end,
    H3 ++ Extra.

%% The metadata headers mirror fields of the body, so they are derived
%% from the envelope about to be sent rather than from connection
%% state. A legacy server ignores them; a modern one requires them and
%% rejects a request whose headers disagree with its body.
metadata_headers(Body, ToolHeaders) ->
    try json:decode(iolist_to_binary(Body)) of
        #{<<"method">> := Method, <<"params">> := Params} when is_map(Params) ->
            Standard = barrel_mcp_headers:standard(Method, Params),
            modern_only(Params, Standard ++ param_headers(Method, Params, ToolHeaders));
        _ ->
            []
    catch
        _:_ -> []
    end.

%% A tool may ask for some of its arguments to be mirrored, so that an
%% intermediary can route on them. The server checks these against the
%% body, so they are built from the same body.
param_headers(<<"tools/call">>, Params, ToolHeaders) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    case maps:get(Name, ToolHeaders, []) of
        [] ->
            [];
        Bindings ->
            Arguments =
                case maps:get(<<"arguments">>, Params, #{}) of
                    A when is_map(A) -> A;
                    _ -> #{}
                end,
            barrel_mcp_headers:param_headers(Arguments, Bindings)
    end;
param_headers(_Method, _Params, _ToolHeaders) ->
    [].

%% Only a modern request carries them. Adding them to a legacy one
%% would be harmless but misleading to an intermediary reading them.
%%
%% The version header comes from the same `_meta' the server compares
%% it against, rather than from connection state: a modern connection
%% negotiates nothing, so there is no state to have set.
modern_only(Params, Headers) ->
    Meta =
        case maps:get(<<"_meta">>, Params, #{}) of
            M when is_map(M) -> M;
            _ -> #{}
        end,
    case maps:get(?MCP_META_PROTOCOL_VERSION, Meta, undefined) of
        Version when is_binary(Version) ->
            [{<<"mcp-protocol-version">>, Version} | Headers];
        _ ->
            []
    end.

detect_format(Headers) ->
    case header_value(<<"content-type">>, Headers) of
        undefined ->
            json;
        CT ->
            case binary:match(string:lowercase(CT), <<"text/event-stream">>) of
                nomatch -> json;
                _ -> sse
            end
    end.

capture_session_header(Headers, State) ->
    case header_value(<<"mcp-session-id">>, Headers) of
        undefined -> State;
        Sid -> State#state{session_id = Sid}
    end.

header_value(Name, Headers) ->
    Lower = string:lowercase(Name),
    Found = lists:filter(
        fun({K, _}) ->
            string:lowercase(to_bin(K)) =:= Lower
        end,
        Headers
    ),
    case Found of
        [{_, V} | _] -> to_bin(V);
        [] -> undefined
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> iolist_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8).

%%====================================================================
%% DELETE on close
%%====================================================================

send_delete(#state{session_id = undefined}) ->
    ok;
send_delete(State) ->
    Headers = build_headers(State),
    _ = hackney:request(delete, State#state.url, Headers, <<>>, []),
    ok.
