%%%-------------------------------------------------------------------
%%% @doc Tiny mock HTTP server for the OAuth test suites, built on the
%%% project's own `h1' server (no extra dependency, and it exercises
%%% the same stack we ship).
%%%
%%% Replaces the former cowboy test dependency. The suites only need a
%%% mock authorization server: route on the request path, read the
%%% body (raw or urlencoded) and the `authorization' header, and reply
%%% with a status code plus a JSON body.
%%%
%%% A handler is a fun taking a request map and returning the response:
%%%
%%% ```
%%% fun(#{method := M, path := P, headers := H, body := B}) ->
%%%     {Status :: integer(), Headers :: map(), Body :: iodata()}
%%% end
%%% '''
%%%
%%% Use {@link form/1} to parse an urlencoded body and {@link header/2}
%%% to read a (case-insensitive) request header.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_test_http).

-export([start/3, stop/1]).
-export([form/1, header/2]).

-define(BODY_TIMEOUT, 5000).

%% @doc Start a mock server registered as `Name' on `Port'.
%%
%% h1 links the listener to whoever calls `h1:start_server', so a
%% long-lived owner process (registered as `Name') holds it open —
%% otherwise it would die with the transient caller (e.g. a CT
%% `init_per_suite' process).
start(Name, Port, Handler) when is_function(Handler, 1) ->
    {ok, _} = application:ensure_all_started(h1),
    Parent = self(),
    Pid = spawn(fun() -> owner(Parent, Port, Handler) end),
    receive
        {Pid, {ok, _} = Ok} ->
            try unregister(Name) catch error:badarg -> ok end,
            true = register(Name, Pid),
            Ok;
        {Pid, {error, _} = Err} ->
            Err
    after 5000 ->
        {error, start_timeout}
    end.

%% @doc Stop a mock server by registered name.
stop(Name) ->
    case whereis(Name) of
        undefined ->
            ok;
        Pid ->
            Ref = erlang:monitor(process, Pid),
            Pid ! stop,
            receive {'DOWN', Ref, process, Pid, _} -> ok
            after 5000 -> ok end
    end.

owner(Parent, Port, Handler) ->
    case h1:start_server(Port, #{handler => make_handler(Handler)}) of
        {ok, ServerRef} ->
            Parent ! {self(), {ok, ServerRef}},
            receive stop -> _ = h1:stop_server(ServerRef), ok end;
        {error, _} = Err ->
            Parent ! {self(), Err}
    end.

%% @doc Parse an `application/x-www-form-urlencoded' body into a map.
form(#{body := Body}) ->
    lists:foldl(
      fun(<<>>, Acc) -> Acc;
         (Pair, Acc) ->
              case binary:split(Pair, <<"=">>) of
                  [K, V] -> Acc#{urldecode(K) => urldecode(V)};
                  [K]    -> Acc#{urldecode(K) => <<>>}
              end
      end, #{}, binary:split(Body, <<"&">>, [global])).

%% @doc Look up a request header by (case-insensitive) name.
header(Name, #{headers := H}) ->
    maps:get(lower(Name), H, undefined).

%%====================================================================
%% h1 handler
%%====================================================================

make_handler(UserFun) ->
    fun(Conn, StreamId, Method, Path, Headers) ->
        Req = #{method  => Method,
                path    => path_only(Path),
                headers => headers_map(Headers),
                body    => read_body(Method, StreamId)},
        {Status, RHeaders, RBody} = UserFun(Req),
        h1:respond(Conn, StreamId, Status,
                   maps:to_list(RHeaders), iolist_to_binary(RBody))
    end.

%% Only methods that carry a body wait for one; a bodyless GET never
%% gets an `{h1_stream, _}' frame, so reading it would just block.
read_body(M, StreamId) when M =:= <<"POST">>;
                            M =:= <<"PUT">>;
                            M =:= <<"PATCH">> ->
    collect_body(StreamId, <<>>);
read_body(_M, _StreamId) ->
    <<>>.

collect_body(StreamId, Acc) ->
    receive
        {h1_stream, StreamId, {data, Data, true}} ->
            <<Acc/binary, Data/binary>>;
        {h1_stream, StreamId, {data, Data, false}} ->
            collect_body(StreamId, <<Acc/binary, Data/binary>>);
        {h1_stream, StreamId, {stream_reset, _}} ->
            Acc
    after ?BODY_TIMEOUT ->
        Acc
    end.

%%====================================================================
%% Misc
%%====================================================================

headers_map(Headers) ->
    maps:from_list([{lower(N), V} || {N, V} <- Headers]).

path_only(Path) ->
    case binary:split(Path, <<"?">>) of
        [P | _] -> P
    end.

urldecode(B) ->
    Spaces = binary:replace(B, <<"+">>, <<" ">>, [global]),
    case uri_string:percent_decode(Spaces) of
        Bin when is_binary(Bin) -> Bin;
        _                       -> Spaces
    end.

lower(B) -> iolist_to_binary(string:lowercase(B)).
