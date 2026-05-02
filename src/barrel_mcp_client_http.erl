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

%% Transport API
-export([connect/2, send/2, close/1]).

%% Public helpers
-export([set_session_id/2, set_protocol_version/2, open_event_stream/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(req, {
    body :: binary(),
    status :: undefined | non_neg_integer(),
    headers = [] :: list(),
    buffer = <<>> :: binary(),
    format :: undefined | json | sse,
    retried = false :: boolean()
}).

-record(state, {
    owner :: pid(),
    url :: binary(),
    extra_headers = [] :: list(),
    session_id :: binary() | undefined,
    protocol_version :: binary() | undefined,
    auth :: barrel_mcp_client_auth:t(),
    requests = #{} :: #{reference() => #req{}},
    sse_ref :: reference() | undefined,
    sse_buffer = <<>> :: binary(),
    sse_last_event_id :: binary() | undefined,
    sse_enabled = false :: boolean()
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

%%====================================================================
%% gen_server
%%====================================================================

init({Owner, Opts}) ->
    process_flag(trap_exit, true),
    Url = case maps:get(url, Opts) of
              U when is_binary(U) -> U;
              U when is_list(U) -> iolist_to_binary(U)
          end,
    Auth = maps:get(auth, Opts, none),
    Headers = lists:map(fun({K, V}) -> {to_bin(K), to_bin(V)} end,
                        maps:get(headers, Opts, [])),
    SseEnabled = maps:get(open_event_stream, Opts, true),
    {ok, #state{owner = Owner,
                url = Url,
                extra_headers = Headers,
                auth = Auth,
                sse_enabled = SseEnabled}}.

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
handle_cast(open_event_stream, #state{sse_ref = Ref} = State) when is_reference(Ref) ->
    {noreply, State};
handle_cast(open_event_stream, State) ->
    {noreply, start_get_sse(State)};
handle_cast(close, State) ->
    _ = send_delete(State),
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% Hackney async response messages.
handle_info({hackney_response, Ref, {status, Status, _Reason}},
            #state{requests = Reqs} = State) ->
    case maps:find(Ref, Reqs) of
        {ok, R} ->
            {noreply, State#state{requests = Reqs#{Ref => R#req{status = Status}}}};
        error ->
            handle_sse_status(Ref, Status, State)
    end;
handle_info({hackney_response, Ref, {headers, Headers}},
            #state{requests = Reqs} = State) ->
    case maps:find(Ref, Reqs) of
        {ok, R} ->
            Format = detect_format(Headers),
            R1 = R#req{headers = Headers, format = Format},
            State1 = capture_session_header(Headers, State),
            {noreply, State1#state{requests = Reqs#{Ref => R1}}};
        error ->
            handle_sse_headers(Ref, Headers, State)
    end;
handle_info({hackney_response, Ref, done},
            #state{requests = Reqs, sse_ref = SseRef} = State) ->
    case maps:find(Ref, Reqs) of
        {ok, R} ->
            State1 = finalize_request(Ref, R, State),
            {noreply, State1};
        error when Ref =:= SseRef ->
            handle_sse_done(State);
        error ->
            {noreply, State}
    end;
handle_info({hackney_response, Ref, {error, Reason}},
            #state{requests = Reqs, sse_ref = SseRef, owner = Owner} = State) ->
    case maps:is_key(Ref, Reqs) of
        true ->
            Owner ! {mcp_closed, self(), {request_failed, Reason}},
            {noreply, State#state{requests = maps:remove(Ref, Reqs)}};
        false when Ref =:= SseRef ->
            {noreply, State#state{sse_ref = undefined, sse_buffer = <<>>}};
        false ->
            {noreply, State}
    end;
handle_info({hackney_response, Ref, Chunk},
            #state{requests = Reqs, sse_ref = SseRef} = State)
  when is_binary(Chunk) ->
    case maps:find(Ref, Reqs) of
        {ok, #req{format = sse, buffer = Buf} = R} ->
            {Events, NewBuf} = parse_sse(<<Buf/binary, Chunk/binary>>),
            State1 = forward_sse_events(Events, State),
            R1 = R#req{buffer = NewBuf},
            {noreply, State1#state{requests = Reqs#{Ref => R1}}};
        {ok, #req{buffer = Buf} = R} ->
            R1 = R#req{buffer = <<Buf/binary, Chunk/binary>>},
            {noreply, State#state{requests = Reqs#{Ref => R1}}};
        error when Ref =:= SseRef ->
            handle_sse_chunk(Chunk, State);
        error ->
            {noreply, State}
    end;
handle_info(reopen_sse, #state{sse_enabled = true, sse_ref = undefined} = State) ->
    {noreply, start_get_sse(State)};
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
    Headers = build_headers(State),
    case hackney:request(post, State#state.url, Headers, Body,
                         [async, {recv_timeout, infinity}]) of
        {ok, Ref} ->
            Req = #req{body = Body, retried = Retried},
            {ok, State#state{requests = (State#state.requests)#{Ref => Req}}};
        {error, _} = Err ->
            Err
    end.

finalize_request(Ref, #req{format = sse} = _R, #state{requests = Reqs} = State) ->
    %% SSE stream ended (server done). Drop the request slot.
    State#state{requests = maps:remove(Ref, Reqs)};
finalize_request(Ref, #req{status = 401, retried = false, body = Body, headers = H},
                 #state{requests = Reqs, auth = Auth, owner = Owner} = State) ->
    Www = header_value(<<"www-authenticate">>, H),
    case barrel_mcp_client_auth:refresh(Auth, Www) of
        {ok, NewAuth} ->
            State1 = State#state{auth = NewAuth,
                                 requests = maps:remove(Ref, Reqs)},
            case start_post(Body, true, State1) of
                {ok, State2} -> State2;
                {error, _} ->
                    Owner ! {mcp_closed, self(), unauthorized},
                    State1
            end;
        {error, _} ->
            Owner ! {mcp_closed, self(), unauthorized},
            State#state{requests = maps:remove(Ref, Reqs)}
    end;
finalize_request(Ref, #req{status = Status, buffer = Buf} = _R,
                 #state{requests = Reqs, owner = Owner} = State)
  when Status >= 200, Status < 300 ->
    case Buf of
        <<>> -> ok;  %% 204 No Content for notifications
        _ ->
            Owner ! {mcp_in, self(), Buf},
            ok
    end,
    State#state{requests = maps:remove(Ref, Reqs)};
finalize_request(Ref, #req{status = Status, buffer = Buf},
                 #state{requests = Reqs, owner = Owner} = State) ->
    Owner ! {mcp_closed, self(), {http_error, Status, Buf}},
    State#state{requests = maps:remove(Ref, Reqs)}.

%%====================================================================
%% SSE GET stream (unsolicited server-to-client)
%%====================================================================

start_get_sse(#state{sse_enabled = false} = State) -> State;
start_get_sse(State) ->
    Headers0 = build_headers(State),
    Headers = case State#state.sse_last_event_id of
                  undefined -> Headers0;
                  Id -> [{<<"last-event-id">>, Id} | Headers0]
              end,
    case hackney:request(get, State#state.url, Headers, <<>>,
                         [async, {recv_timeout, infinity}]) of
        {ok, Ref} ->
            State#state{sse_ref = Ref};
        {error, _} ->
            State
    end.

handle_sse_status(_Ref, Status, State) when Status >= 200, Status < 300 ->
    {noreply, State};
handle_sse_status(_Ref, _Status, State) ->
    %% Server doesn't support GET SSE (e.g. 405). Quietly drop.
    {noreply, State#state{sse_ref = undefined}}.

handle_sse_headers(_Ref, _Headers, State) ->
    {noreply, State}.

handle_sse_chunk(Chunk, #state{sse_buffer = Buf} = State) ->
    {Events, NewBuf} = parse_sse(<<Buf/binary, Chunk/binary>>),
    State1 = forward_sse_events(Events, State),
    {noreply, State1#state{sse_buffer = NewBuf}}.

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
    lists:foldl(fun(Line, {Id, Ev, DataAcc}) ->
        case Line of
            <<"id: ", V/binary>>    -> {V, Ev, DataAcc};
            <<"id:", V/binary>>     -> {trim_leading_space(V), Ev, DataAcc};
            <<"event: ", V/binary>> -> {Id, V, DataAcc};
            <<"event:", V/binary>>  -> {Id, trim_leading_space(V), DataAcc};
            <<"data: ", V/binary>>  -> {Id, Ev, append_data(DataAcc, V)};
            <<"data:", V/binary>>   -> {Id, Ev, append_data(DataAcc, trim_leading_space(V))};
            <<":", _/binary>>       -> {Id, Ev, DataAcc};  %% comment
            _                       -> {Id, Ev, DataAcc}   %% unknown field
        end
    end, {undefined, undefined, <<>>}, Lines).

append_data(<<>>, V) -> V;
append_data(Acc, V)  -> <<Acc/binary, "\n", V/binary>>.

trim_leading_space(<<" ", R/binary>>) -> R;
trim_leading_space(B) -> B.

forward_sse_events([], State) -> State;
forward_sse_events([{Id, _Ev, Data} | Rest], #state{owner = Owner} = State) ->
    case Data of
        <<>> -> ok;
        _ ->
            Owner ! {mcp_in, self(), Data},
            ok
    end,
    State1 = case Id of
                 undefined -> State;
                 _         -> State#state{sse_last_event_id = Id}
             end,
    forward_sse_events(Rest, State1).

%%====================================================================
%% Header helpers
%%====================================================================

build_headers(#state{extra_headers = Extra,
                     session_id = Sid,
                     protocol_version = PV,
                     auth = Auth}) ->
    Base = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>}
    ],
    H1 = case Sid of
             undefined -> Base;
             _ -> [{<<"mcp-session-id">>, Sid} | Base]
         end,
    H2 = case PV of
             undefined -> H1;
             _ -> [{<<"mcp-protocol-version">>, PV} | H1]
         end,
    H3 = case barrel_mcp_client_auth:header(Auth) of
             {ok, AuthHdr} -> [{<<"authorization">>, AuthHdr} | H2];
             _ -> H2
         end,
    H3 ++ Extra.

detect_format(Headers) ->
    case header_value(<<"content-type">>, Headers) of
        undefined -> json;
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
    Found = lists:filter(fun({K, _}) ->
                                 string:lowercase(to_bin(K)) =:= Lower
                         end, Headers),
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

send_delete(#state{session_id = undefined}) -> ok;
send_delete(State) ->
    Headers = build_headers(State),
    _ = hackney:request(delete, State#state.url, Headers, <<>>, []),
    ok.
