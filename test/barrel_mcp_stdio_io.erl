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

%% @doc Start a device owned by the calling process.
start() ->
    Owner = self(),
    spawn(fun() ->
        loop(#{owner => Owner, in => <<>>, pending => undefined, closed => false})
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
        stop ->
            ok
    end.

request({setopts, _Opts}, From, ReplyAs, S) ->
    reply(From, ReplyAs, ok),
    S;
request(getopts, From, ReplyAs, S) ->
    reply(From, ReplyAs, []),
    S;
request({put_chars, _Enc, Chars}, From, ReplyAs, S) ->
    emit(S, Chars),
    reply(From, ReplyAs, ok),
    S;
request({put_chars, _Enc, M, F, A}, From, ReplyAs, S) ->
    emit(S, apply(M, F, A)),
    reply(From, ReplyAs, ok),
    S;
request({get_chars, _Enc, _Prompt, N}, From, ReplyAs, S) ->
    serve(S#{pending := {From, ReplyAs, N}});
request(_Other, From, ReplyAs, S) ->
    reply(From, ReplyAs, {error, request}),
    S.

emit(#{owner := Owner}, Chars) ->
    Owner ! {stdout, iolist_to_binary(Chars)},
    ok.

serve(#{pending := undefined} = S) ->
    S;
serve(#{pending := {From, ReplyAs, N}, in := In, closed := Closed} = S) ->
    case In of
        <<>> when Closed ->
            reply(From, ReplyAs, eof),
            S#{pending := undefined};
        <<>> ->
            S;
        _ ->
            Take = min(N, byte_size(In)),
            <<Chunk:Take/binary, Rest/binary>> = In,
            reply(From, ReplyAs, Chunk),
            S#{pending := undefined, in := Rest}
    end.

reply(From, ReplyAs, Reply) ->
    From ! {io_reply, ReplyAs, Reply},
    ok.
