%%%-------------------------------------------------------------------
%%% @doc MCP client for connecting to external MCP servers.
%%%
%%% Supports both HTTP and stdio transports.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client).

%% API
-export([
    connect/1,
    close/1,
    initialize/1,
    %% Tools
    list_tools/1,
    call_tool/3,
    %% Resources
    list_resources/1,
    read_resource/2,
    subscribe/2,
    unsubscribe/2,
    %% Prompts
    list_prompts/1,
    get_prompt/3,
    %% Sampling
    create_message/3
]).

-record(client, {
    transport :: http | stdio,
    url :: binary() | undefined,
    port :: port() | undefined,
    request_id = 1 :: integer(),
    initialized = false :: boolean()
}).

-type client() :: #client{}.
-type transport_opts() :: {http, binary() | string()} |
                          {stdio, #{command := string(), args => [string()]}}.

%%====================================================================
%% API
%%====================================================================

%% @doc Connect to an MCP server.
-spec connect(#{transport := transport_opts()}) -> {ok, client()} | {error, term()}.
connect(#{transport := {http, Url}}) when is_list(Url) ->
    connect(#{transport => {http, list_to_binary(Url)}});
connect(#{transport := {http, Url}}) when is_binary(Url) ->
    {ok, #client{transport = http, url = Url}};

connect(#{transport := {stdio, #{command := Cmd} = Opts}}) ->
    Args = maps:get(args, Opts, []),
    Port = open_port({spawn_executable, Cmd}, [
        {args, Args},
        {line, 1048576},  % 1MB line buffer
        binary,
        use_stdio,
        exit_status,
        stderr_to_stdout
    ]),
    {ok, #client{transport = stdio, port = Port}}.

%% @doc Close connection.
-spec close(client()) -> ok.
close(#client{transport = stdio, port = Port}) when Port =/= undefined ->
    catch port_close(Port),
    ok;
close(_) ->
    ok.

%% @doc Send initialize request.
-spec initialize(client()) -> {ok, map(), client()} | {error, term()}.
initialize(Client) ->
    case request(Client, <<"initialize">>, #{
        <<"protocolVersion">> => <<"2024-11-05">>,
        <<"capabilities">> => #{},
        <<"clientInfo">> => #{
            <<"name">> => <<"barrel_mcp_client">>,
            <<"version">> => <<"1.0.0">>
        }
    }) of
        {ok, Result, Client1} ->
            %% Send initialized notification
            _ = notify(Client1, <<"initialized">>, #{}),
            {ok, Result, Client1#client{initialized = true}};
        Error ->
            Error
    end.

%% @doc List available tools.
-spec list_tools(client()) -> {ok, [map()], client()} | {error, term()}.
list_tools(Client) ->
    case request(Client, <<"tools/list">>, #{}) of
        {ok, #{<<"tools">> := Tools}, Client1} ->
            {ok, Tools, Client1};
        {ok, Result, Client1} ->
            {ok, maps:get(<<"tools">>, Result, []), Client1};
        Error ->
            Error
    end.

%% @doc Call a tool.
-spec call_tool(client(), binary(), map()) -> {ok, map(), client()} | {error, term()}.
call_tool(Client, Name, Args) ->
    request(Client, <<"tools/call">>, #{
        <<"name">> => Name,
        <<"arguments">> => Args
    }).

%% @doc List available resources.
-spec list_resources(client()) -> {ok, [map()], client()} | {error, term()}.
list_resources(Client) ->
    case request(Client, <<"resources/list">>, #{}) of
        {ok, #{<<"resources">> := Resources}, Client1} ->
            {ok, Resources, Client1};
        {ok, Result, Client1} ->
            {ok, maps:get(<<"resources">>, Result, []), Client1};
        Error ->
            Error
    end.

%% @doc Read a resource.
-spec read_resource(client(), binary()) -> {ok, map(), client()} | {error, term()}.
read_resource(Client, Uri) ->
    request(Client, <<"resources/read">>, #{<<"uri">> => Uri}).

%% @doc Subscribe to resource updates.
-spec subscribe(client(), binary()) -> {ok, map(), client()} | {error, term()}.
subscribe(Client, Uri) ->
    request(Client, <<"resources/subscribe">>, #{<<"uri">> => Uri}).

%% @doc Unsubscribe from resource updates.
-spec unsubscribe(client(), binary()) -> {ok, map(), client()} | {error, term()}.
unsubscribe(Client, Uri) ->
    request(Client, <<"resources/unsubscribe">>, #{<<"uri">> => Uri}).

%% @doc List available prompts.
-spec list_prompts(client()) -> {ok, [map()], client()} | {error, term()}.
list_prompts(Client) ->
    case request(Client, <<"prompts/list">>, #{}) of
        {ok, #{<<"prompts">> := Prompts}, Client1} ->
            {ok, Prompts, Client1};
        {ok, Result, Client1} ->
            {ok, maps:get(<<"prompts">>, Result, []), Client1};
        Error ->
            Error
    end.

%% @doc Get a prompt with arguments.
-spec get_prompt(client(), binary(), map()) -> {ok, map(), client()} | {error, term()}.
get_prompt(Client, Name, Args) ->
    request(Client, <<"prompts/get">>, #{
        <<"name">> => Name,
        <<"arguments">> => Args
    }).

%% @doc Request message generation (sampling).
-spec create_message(client(), [map()], map()) -> {ok, map(), client()} | {error, term()}.
create_message(Client, Messages, Opts) ->
    request(Client, <<"sampling/createMessage">>, #{
        <<"messages">> => Messages,
        <<"maxTokens">> => maps:get(max_tokens, Opts, 1024),
        <<"temperature">> => maps:get(temperature, Opts, 1.0),
        <<"stopSequences">> => maps:get(stop_sequences, Opts, [])
    }).

%%====================================================================
%% Internal Functions
%%====================================================================

request(#client{request_id = Id} = Client, Method, Params) ->
    RequestBody = iolist_to_binary(json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    })),
    Client1 = Client#client{request_id = Id + 1},
    case send_request(Client1, RequestBody) of
        {ok, Response} ->
            case parse_response(Response) of
                {ok, Result} ->
                    {ok, Result, Client1};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

notify(Client, Method, Params) ->
    RequestBody = iolist_to_binary(json:encode(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    })),
    send_request(Client, RequestBody).

send_request(#client{transport = http, url = Url}, Body) ->
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:post(Url, Headers, Body, []) of
        {ok, 200, _RespHeaders, ClientRef} ->
            {ok, ResponseBody} = hackney:body(ClientRef),
            {ok, ResponseBody};
        {ok, 204, _RespHeaders, _ClientRef} ->
            {ok, <<>>};
        {ok, Status, _RespHeaders, ClientRef} ->
            {ok, ResponseBody} = hackney:body(ClientRef),
            {error, {http_error, Status, ResponseBody}};
        {error, Reason} ->
            {error, Reason}
    end;

send_request(#client{transport = stdio, port = Port}, Body) ->
    port_command(Port, [Body, "\n"]),
    receive
        {Port, {data, {eol, Line}}} ->
            {ok, Line};
        {Port, {data, {noeol, _}}} ->
            {error, incomplete_response};
        {Port, {exit_status, Status}} ->
            {error, {exit, Status}}
    after 30000 ->
        {error, timeout}
    end.

parse_response(<<>>) ->
    {ok, #{}};
parse_response(Response) ->
    try
        case json:decode(Response) of
            #{<<"error">> := Error} ->
                {error, Error};
            #{<<"result">> := Result} ->
                {ok, Result};
            Other ->
                {ok, Other}
        end
    catch
        _:_ ->
            {error, {parse_error, Response}}
    end.
