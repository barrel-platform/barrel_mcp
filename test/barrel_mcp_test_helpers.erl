%%%-------------------------------------------------------------------
%%% @doc Scaffolding the suites share: waiting, building an HTTP
%%% request, building a JSON-RPC envelope, and launching the stdio
%%% child.
%%%
%%% Only what is genuinely common lives here. A suite's fixture tools
%%% (`echo_tool', `slow_tool') stay with the suite: their sleeps, arities
%%% and return shapes are what each suite is testing, not incidental
%%% copies.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_test_helpers).

-include("barrel_mcp.hrl").

-export([wait_until/2, wait_ready/2]).
-export([url/1, url/2, post/3, header/2]).
-export([request/3, legacy_request/3, modern_request/3, modern_meta/0, modern_meta/1]).
-export([init_params/0, init_params/1, init_params/2, init_body/0, init_body/1, init_body/2]).
-export([erl_executable/0, child_args/1, child_args/2]).
-export([case_port/3]).

%%====================================================================
%% Waiting
%%====================================================================

%% @doc Poll `Fun' until it returns `true' or `TimeoutMs' elapses.
%% Returns `ok' either way: a caller that needs the condition asserts it
%% afterwards, which reads as the assertion rather than a timeout.
-spec wait_until(fun(() -> boolean()), non_neg_integer()) -> ok.
wait_until(_Fun, Remaining) when Remaining =< 0 ->
    ok;
wait_until(Fun, Remaining) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(50),
            wait_until(Fun, Remaining - 50)
    end.

%% @doc Poll a client until it has negotiated and answers
%% `server_capabilities/1', up to `Attempts' times.
-spec wait_ready(pid(), non_neg_integer()) -> ok | {error, not_ready}.
wait_ready(_Pid, 0) ->
    {error, not_ready};
wait_ready(Pid, N) ->
    Ready =
        try barrel_mcp_client:server_capabilities(Pid) of
            {ok, _} -> true;
            _ -> false
        catch
            _:_ -> false
        end,
    case Ready of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.

%%====================================================================
%% HTTP
%%====================================================================

-spec url(inet:port_number()) -> binary().
url(Port) ->
    url(Port, <<"/mcp">>).

-spec url(inet:port_number(), iodata()) -> binary().
url(Port, Path) ->
    iolist_to_binary([io_lib:format("http://127.0.0.1:~B", [Port]), Path]).

%% @doc POST a JSON body. `ExtraHeaders' come after the two every
%% request carries.
-spec post(binary(), iodata(), [{binary(), binary()}]) ->
    {non_neg_integer(), [{binary(), binary()}], binary()}.
post(Url, Body, ExtraHeaders) ->
    Headers =
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ] ++ ExtraHeaders,
    {ok, Status, RespHeaders, RespBody} = hackney:request(
        post, Url, Headers, Body, [with_body]
    ),
    {Status, RespHeaders, RespBody}.

%% @doc Case-insensitive header lookup in a hackney header list.
-spec header(binary(), [{binary(), binary()}]) -> binary() | undefined.
header(Name, Headers) ->
    Lower = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(K) =:= Lower end, Headers) of
        {value, {_, V}} -> V;
        false -> undefined
    end.

%%====================================================================
%% JSON-RPC envelopes
%%====================================================================

%% @doc A request envelope, encoded. No `_meta': the legacy shape.
-spec request(term(), binary(), map()) -> binary().
request(Id, Method, Params) ->
    iolist_to_binary(json:encode(legacy_request(Id, Method, Params))).

%% @doc A request envelope as a map, without `_meta'.
-spec legacy_request(term(), binary(), map()) -> map().
legacy_request(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }.

%% @doc A request envelope as a map, carrying modern `_meta'.
-spec modern_request(term(), binary(), map()) -> map().
modern_request(Id, Method, Params) ->
    legacy_request(Id, Method, Params#{<<"_meta">> => modern_meta()}).

-spec modern_meta() -> map().
modern_meta() ->
    modern_meta(#{}).

-spec modern_meta(map()) -> map().
modern_meta(Capabilities) ->
    #{
        ?MCP_META_PROTOCOL_VERSION => <<"2026-07-28">>,
        ?MCP_META_CLIENT_CAPABILITIES => Capabilities
    }.

%%====================================================================
%% initialize
%%====================================================================

%% All three fields are required by every legacy revision, so every
%% suite gets a conformant body from the same place.
-spec init_params() -> map().
init_params() ->
    init_params(?MCP_LATEST_LEGACY_VERSION).

-spec init_params(binary()) -> map().
init_params(Version) ->
    init_params(Version, #{}).

-spec init_params(binary(), map()) -> map().
init_params(Version, Capabilities) ->
    #{
        <<"protocolVersion">> => Version,
        <<"capabilities">> => Capabilities,
        <<"clientInfo">> => #{<<"name">> => <<"barrel-suite">>, <<"version">> => <<"0">>}
    }.

-spec init_body() -> binary().
init_body() ->
    init_body(?MCP_LATEST_LEGACY_VERSION).

-spec init_body(binary()) -> binary().
init_body(Version) ->
    init_body(Version, #{}).

-spec init_body(binary(), map()) -> binary().
init_body(Version, Capabilities) ->
    request(1, <<"initialize">>, init_params(Version, Capabilities)).

%%====================================================================
%% stdio child
%%====================================================================

-spec erl_executable() -> string().
erl_executable() ->
    filename:join([code:root_dir(), "bin", "erl"]).

%% @doc Arguments that boot `Module:start()' as a stdio child. Logging
%% has to go to stderr: the default handler writes stdout, which is the
%% wire. The paths are reversed because each `-pa' prepends.
-spec child_args(module()) -> [string()].
child_args(Module) ->
    child_args(Module, start).

%% @doc Arguments that boot `Module:Function()' the same way, ending in
%% `-extra' so whatever a caller appends reaches the node as plain
%% arguments (`init:get_plain_arguments/0').
-spec child_args(module(), atom()) -> [string()].
child_args(Module, Function) ->
    Dirs = lists:reverse([D || D <- code:get_path(), filelib:is_dir(D)]),
    Paths = lists:append([["-pa", D] || D <- Dirs]),
    [
        "-noshell",
        "-boot",
        "no_dot_erlang",
        "-kernel",
        "logger",
        "[{handler,default,logger_std_h,#{config=>#{type=>standard_error}}}]"
    ] ++ Paths ++
        ["-eval", atom_to_list(Module) ++ ":" ++ atom_to_list(Function) ++ "()", "-extra"].

%% @doc A port of its own per case: `Base' plus the case's position in
%% `All', so cases never share a listener whatever order they run in.
-spec case_port(pos_integer(), atom(), [atom()]) -> pos_integer().
case_port(Base, TC, All) ->
    case_port(Base, TC, All, 0).

case_port(Base, TC, [TC | _], N) -> Base + N;
case_port(Base, TC, [_ | Rest], N) -> case_port(Base, TC, Rest, N + 1);
case_port(Base, _TC, [], N) -> Base + N.
