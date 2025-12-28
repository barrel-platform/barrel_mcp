%%%-------------------------------------------------------------------
%%% @doc MCP protocol implementation over JSON-RPC 2.0.
%%%
%%% Handles encoding/decoding and routing of MCP methods.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_protocol).

-include("barrel_mcp.hrl").

%% API
-export([
    decode/1,
    encode/1,
    handle/1,
    handle/2,
    error_response/3,
    notification_response/0
]).

%%====================================================================
%% API
%%====================================================================

%% @doc Decode a JSON-RPC request.
-spec decode(binary()) -> {ok, map()} | {error, term()}.
decode(Binary) ->
    try
        {ok, json:decode(Binary)}
    catch
        _:_ ->
            {error, parse_error}
    end.

%% @doc Encode a JSON-RPC response.
-spec encode(map()) -> binary().
encode(Response) ->
    iolist_to_binary(json:encode(Response)).

%% @doc Handle a JSON-RPC request with default state.
-spec handle(map()) -> map() | no_response.
handle(Request) ->
    handle(Request, #{}).

%% @doc Handle a JSON-RPC request with state.
-spec handle(map(), map()) -> map() | no_response.
handle(#{<<"jsonrpc">> := <<"2.0">>, <<"method">> := Method} = Request, State) ->
    Id = maps:get(<<"id">>, Request, undefined),
    Params = maps:get(<<"params">>, Request, #{}),
    case Id of
        undefined ->
            %% Notification - no response expected
            handle_notification(Method, Params, State),
            no_response;
        _ ->
            %% Request - response required
            handle_request(Method, Params, Id, State)
    end;
handle(#{<<"id">> := Id}, _State) ->
    error_response(Id, ?JSONRPC_INVALID_REQUEST, <<"Invalid Request">>);
handle(_, _State) ->
    error_response(null, ?JSONRPC_INVALID_REQUEST, <<"Invalid Request">>).

%% @doc Create an error response.
-spec error_response(term(), integer(), binary()) -> map().
error_response(Id, Code, Message) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => #{
            <<"code">> => Code,
            <<"message">> => Message
        }
    }.

%% @doc Return a marker for no response (notifications).
-spec notification_response() -> no_response.
notification_response() ->
    no_response.

%%====================================================================
%% Request Handlers
%%====================================================================

handle_request(<<"initialize">>, _Params, Id, _State) ->
    ServerName = application:get_env(barrel_mcp, server_name, <<"barrel">>),
    ServerVersion = application:get_env(barrel_mcp, server_version, <<"1.0.0">>),
    success_response(Id, #{
        <<"protocolVersion">> => ?MCP_PROTOCOL_VERSION,
        <<"capabilities">> => #{
            <<"tools">> => #{},
            <<"resources">> => #{<<"subscribe">> => true},
            <<"prompts">> => #{},
            <<"logging">> => #{}
        },
        <<"serverInfo">> => #{
            <<"name">> => ServerName,
            <<"version">> => ServerVersion
        }
    });

handle_request(<<"ping">>, _Params, Id, _State) ->
    success_response(Id, #{});

%% Tools
handle_request(<<"tools/list">>, _Params, Id, _State) ->
    Tools = lists:map(fun({Name, Handler}) ->
        #{
            <<"name">> => Name,
            <<"description">> => maps:get(description, Handler, <<>>),
            <<"inputSchema">> => maps:get(input_schema, Handler, #{<<"type">> => <<"object">>})
        }
    end, barrel_mcp_registry:all(tool)),
    success_response(Id, #{<<"tools">> => Tools});

handle_request(<<"tools/call">>, Params, Id, _State) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    Args = maps:get(<<"arguments">>, Params, #{}),
    case barrel_mcp_registry:run(tool, Name, Args) of
        {ok, Result} ->
            Content = format_tool_result(Result),
            success_response(Id, #{<<"content">> => Content});
        {error, {not_found, _, _}} ->
            error_response(Id, ?JSONRPC_METHOD_NOT_FOUND, <<"Tool not found">>);
        {error, Reason} ->
            error_response(Id, ?MCP_TOOL_ERROR, format_error(Reason))
    end;

%% Resources
handle_request(<<"resources/list">>, _Params, Id, _State) ->
    Resources = lists:map(fun({_Name, Handler}) ->
        #{
            <<"uri">> => maps:get(uri, Handler, <<>>),
            <<"name">> => maps:get(name, Handler, <<>>),
            <<"description">> => maps:get(description, Handler, <<>>),
            <<"mimeType">> => maps:get(mime_type, Handler, <<"text/plain">>)
        }
    end, barrel_mcp_registry:all(resource)),
    success_response(Id, #{<<"resources">> => Resources});

handle_request(<<"resources/read">>, Params, Id, _State) ->
    Uri = maps:get(<<"uri">>, Params, <<>>),
    %% Find resource by URI
    Resources = barrel_mcp_registry:all(resource),
    case lists:keyfind(Uri, 1, [{maps:get(uri, H, <<>>), N, H} || {N, H} <- Resources]) of
        {Uri, Name, _Handler} ->
            case barrel_mcp_registry:run(resource, Name, Params) of
                {ok, Result} ->
                    Content = format_resource_result(Uri, Result),
                    success_response(Id, #{<<"contents">> => Content});
                {error, Reason} ->
                    error_response(Id, ?MCP_RESOURCE_ERROR, format_error(Reason))
            end;
        false ->
            error_response(Id, ?JSONRPC_METHOD_NOT_FOUND, <<"Resource not found">>)
    end;

handle_request(<<"resources/templates/list">>, _Params, Id, _State) ->
    %% Return empty list for now - templates can be added later
    success_response(Id, #{<<"resourceTemplates">> => []});

%% Prompts
handle_request(<<"prompts/list">>, _Params, Id, _State) ->
    Prompts = lists:map(fun({Name, Handler}) ->
        #{
            <<"name">> => Name,
            <<"description">> => maps:get(description, Handler, <<>>),
            <<"arguments">> => lists:map(fun(Arg) ->
                #{
                    <<"name">> => maps:get(name, Arg, <<>>),
                    <<"description">> => maps:get(description, Arg, <<>>),
                    <<"required">> => maps:get(required, Arg, false)
                }
            end, maps:get(arguments, Handler, []))
        }
    end, barrel_mcp_registry:all(prompt)),
    success_response(Id, #{<<"prompts">> => Prompts});

handle_request(<<"prompts/get">>, Params, Id, _State) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    Args = maps:get(<<"arguments">>, Params, #{}),
    case barrel_mcp_registry:run(prompt, Name, Args) of
        {ok, Result} ->
            success_response(Id, #{
                <<"description">> => maps:get(description, Result, <<>>),
                <<"messages">> => maps:get(messages, Result, [])
            });
        {error, {not_found, _, _}} ->
            error_response(Id, ?JSONRPC_METHOD_NOT_FOUND, <<"Prompt not found">>);
        {error, Reason} ->
            error_response(Id, ?MCP_PROMPT_ERROR, format_error(Reason))
    end;

%% Logging
handle_request(<<"logging/setLevel">>, _Params, Id, _State) ->
    success_response(Id, #{});

%% Unknown method
handle_request(Method, _Params, Id, _State) ->
    error_response(Id, ?JSONRPC_METHOD_NOT_FOUND,
        <<"Method not found: ", Method/binary>>).

%%====================================================================
%% Notification Handlers
%%====================================================================

handle_notification(<<"initialized">>, _Params, _State) ->
    ok;

handle_notification(<<"notifications/cancelled">>, _Params, _State) ->
    %% Request cancellation - not implemented yet
    ok;

handle_notification(<<"notifications/progress">>, _Params, _State) ->
    %% Progress updates - not implemented yet
    ok;

handle_notification(<<"notifications/roots/list_changed">>, _Params, _State) ->
    %% Roots changed - not implemented yet
    ok;

handle_notification(_, _Params, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

success_response(Id, Result) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => Result
    }.

format_tool_result(Result) when is_binary(Result) ->
    [#{<<"type">> => <<"text">>, <<"text">> => Result}];
format_tool_result(Result) when is_map(Result) ->
    case maps:get(<<"type">>, Result, undefined) of
        undefined ->
            [#{<<"type">> => <<"text">>, <<"text">> => iolist_to_binary(json:encode(Result))}];
        _ ->
            [Result]
    end;
format_tool_result(Result) when is_list(Result) ->
    Result;
format_tool_result(Result) ->
    [#{<<"type">> => <<"text">>, <<"text">> => io_lib:format("~p", [Result])}].

format_resource_result(Uri, Result) when is_binary(Result) ->
    [#{<<"uri">> => Uri, <<"text">> => Result}];
format_resource_result(Uri, #{text := Text}) ->
    [#{<<"uri">> => Uri, <<"text">> => Text}];
format_resource_result(Uri, #{blob := Blob, mimeType := MimeType}) ->
    [#{<<"uri">> => Uri, <<"blob">> => base64:encode(Blob), <<"mimeType">> => MimeType}];
format_resource_result(Uri, Result) when is_map(Result) ->
    [#{<<"uri">> => Uri, <<"text">> => iolist_to_binary(json:encode(Result))}];
format_resource_result(Uri, Result) ->
    [#{<<"uri">> => Uri, <<"text">> => io_lib:format("~p", [Result])}].

format_error({Class, Reason, _Stack}) ->
    iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]));
format_error(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
