%%%-------------------------------------------------------------------
%%% @doc A fake stdin/stdout for driving `barrel_mcp_stdio' in-process.
%%%
%%% `io:get_chars(standard_io, ...)' and `io:format/2' both address the
%%% calling process's group leader, so setting that to one of these
%%% gives a test both ends of the transport without spawning an OS
%%% process. Everything written arrives at the owner as
%%% `{stdout, Binary}'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_stdio_io).

-export([start/0, feed/2, close/1, stop/1, next_line/1, next_line/2, silent/2]).
-export([stall/1, resume/1]).

%% @doc Start a device owned by the calling process.
start() ->
    Owner = self(),
    spawn(fun() ->
        loop(#{
            owner => Owner,
            in => <<>>,
            pending => undefined,
            closed => false,
            stalled => false,
            held => []
        })
    end).

%% @doc Hand bytes to the reader, as a peer writing to our stdin.
feed(Dev, Data) ->
    Dev ! {feed, iolist_to_binary(Data)},
    ok.

%% @doc EOF on stdin.
close(Dev) ->
    Dev ! close,
    ok.

stop(Dev) ->
    Dev ! stop,
    ok.

%% @doc Stop answering writes, as a peer that has stopped draining its
%% end of the pipe. Held writes are released in order by `resume/1'.
stall(Dev) ->
    Dev ! stall,
    ok.

resume(Dev) ->
    Dev ! resume,
    ok.

%% @doc The next decoded JSON envelope written to stdout.
next_line(Dev) ->
    next_line(Dev, 5000).

next_line(_Dev, Timeout) ->
    receive
        {stdout, Bin} ->
            case string:trim(Bin) of
                <<>> -> next_line(undefined, Timeout);
                Trimmed -> json:decode(Trimmed)
            end
    after Timeout -> timeout
    end.

%% @doc Assert nothing is written for `Timeout'.
silent(_Dev, Timeout) ->
    receive
        {stdout, Bin} ->
            case string:trim(Bin) of
                <<>> -> silent(undefined, Timeout);
                Trimmed -> {unexpected, Trimmed}
            end
    after Timeout -> ok
    end.

%%====================================================================
%% Internal
%%====================================================================

loop(S) ->
    receive
        {io_request, From, ReplyAs, Req} ->
            loop(request(Req, From, ReplyAs, S));
        {feed, Data} ->
            #{in := In} = S,
            loop(serve(S#{in := <<In/binary, Data/binary>>}));
        close ->
            loop(serve(S#{closed := true}));
        stall ->
            loop(S#{stalled := true});
        resume ->
            #{held := Held} = S,
            lists:foreach(
                fun({From, ReplyAs, Chars}) ->
                    emit(S, Chars),
                    reply(From, ReplyAs, ok)
                end,
                lists:reverse(Held)
            ),
            loop(S#{stalled := false, held := []});
        stop ->
            ok
    end.

request({setopts, _Opts}, From, ReplyAs, S) ->
    reply(From, ReplyAs, ok),
    S;
request(getopts, From, ReplyAs, S) ->
    reply(From, ReplyAs, []),
    S;
request({put_chars, _Enc, Chars}, From, ReplyAs, #{stalled := true, held := Held} = S) ->
    S#{held := [{From, ReplyAs, Chars} | Held]};
request({put_chars, _Enc, Chars}, From, ReplyAs, S) ->
    emit(S, Chars),
    reply(From, ReplyAs, ok),
    S;
request({put_chars, _Enc, M, F, A}, From, ReplyAs, S) ->
    emit(S, apply(M, F, A)),
    reply(From, ReplyAs, ok),
    S;
request({get_chars, _Enc, _Prompt, N}, From, ReplyAs, S) ->
    serve(S#{pending := {From, ReplyAs, {chars, N}}});
request({get_line, _Enc, _Prompt}, From, ReplyAs, S) ->
    serve(S#{pending := {From, ReplyAs, line}});
request(_Other, From, ReplyAs, S) ->
    reply(From, ReplyAs, {error, request}),
    S.

emit(#{owner := Owner}, Chars) ->
    Owner ! {stdout, iolist_to_binary(Chars)},
    ok.

%% A real `get_chars' blocks until it has the full count, and only
%% returns short at EOF. Handing back whatever happens to be buffered
%% would let a reader that asks for more than one message at a time look
%% like it works here and deadlock against a real pipe.
serve(#{pending := undefined} = S) ->
    S;
serve(#{pending := {From, ReplyAs, {chars, N}}, in := In, closed := Closed} = S) ->
    case {byte_size(In) >= N, Closed, In} of
        {true, _, _} ->
            <<Chunk:N/binary, Rest/binary>> = In,
            reply(From, ReplyAs, Chunk),
            S#{pending := undefined, in := Rest};
        {false, true, <<>>} ->
            reply(From, ReplyAs, eof),
            S#{pending := undefined};
        {false, true, _} ->
            reply(From, ReplyAs, In),
            S#{pending := undefined, in := <<>>};
        {false, false, _} ->
            S
    end;
%% `get_line' blocks until a newline or EOF, and the newline it returns
%% is part of the line.
serve(#{pending := {From, ReplyAs, line}, in := In, closed := Closed} = S) ->
    case binary:split(In, <<"\n">>) of
        [Line, Rest] ->
            reply(From, ReplyAs, <<Line/binary, "\n">>),
            S#{pending := undefined, in := Rest};
        [<<>>] when Closed ->
            reply(From, ReplyAs, eof),
            S#{pending := undefined};
        [Trailing] when Closed ->
            reply(From, ReplyAs, Trailing),
            S#{pending := undefined, in := <<>>};
        _ ->
            S
    end.

reply(From, ReplyAs, Reply) ->
    From ! {io_reply, ReplyAs, Reply},
    ok.
