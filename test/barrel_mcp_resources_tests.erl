%%%-------------------------------------------------------------------
%%% @doc Resources tests for barrel_mcp.
%%% Tests based on official MCP Python SDK test patterns.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_resources_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test handlers
-export([
    text_resource/1,
    binary_resource/1,
    json_resource/1
]).

%%====================================================================
%% Test Fixtures
%%====================================================================

resources_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
        {"List resources returns registered resources", fun test_list_resources/0},
        {"List resources returns empty when none registered", fun test_list_resources_empty/0},
        {"Read resource returns text content", fun test_read_resource_text/0},
        {"Read resource returns binary content", fun test_read_resource_binary/0},
        {"Read resource returns JSON content", fun test_read_resource_json/0},
        {"Read non-existent resource returns error", fun test_read_resource_not_found/0},
        {"Resource with mime type is listed correctly", fun test_resource_mime_type/0},
        {"List resource templates returns empty", fun test_list_resource_templates/0},
        {"Resource annotations are surfaced in resources/list",
         fun test_resource_annotations/0}
     ]
    }.

setup() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    lists:foreach(fun({Name, _}) ->
        barrel_mcp_registry:unreg(resource, Name)
    end, barrel_mcp_registry:all(resource)),
    ok.

%%====================================================================
%% Test Handlers
%%====================================================================

text_resource(_Args) ->
    <<"Hello World">>.

binary_resource(_Args) ->
    #{blob => <<1, 2, 3, 4, 5>>, mimeType => <<"application/octet-stream">>}.

json_resource(_Args) ->
    #{<<"name">> => <<"test">>, <<"value">> => 42}.

%%====================================================================
%% Tests
%%====================================================================

test_list_resources() ->
    ok = barrel_mcp_registry:reg(resource, <<"res1">>, ?MODULE, text_resource, #{
        name => <<"Resource 1">>,
        uri => <<"file:///res1">>,
        description => <<"First resource">>
    }),
    ok = barrel_mcp_registry:reg(resource, <<"res2">>, ?MODULE, json_resource, #{
        name => <<"Resource 2">>,
        uri => <<"file:///res2">>,
        description => <<"Second resource">>
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Resources = maps:get(<<"resources">>, Result),

    ?assertEqual(2, length(Resources)),

    %% Check resource structure
    [Res1 | _] = Resources,
    ?assert(maps:is_key(<<"uri">>, Res1)),
    ?assert(maps:is_key(<<"name">>, Res1)),
    ?assert(maps:is_key(<<"description">>, Res1)),
    ?assert(maps:is_key(<<"mimeType">>, Res1)),

    barrel_mcp_registry:unreg(resource, <<"res1">>),
    barrel_mcp_registry:unreg(resource, <<"res2">>).

test_list_resources_empty() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Resources = maps:get(<<"resources">>, Result),
    ?assertEqual([], Resources).

test_read_resource_text() ->
    ok = barrel_mcp_registry:reg(resource, <<"text_res">>, ?MODULE, text_resource, #{
        name => <<"Text Resource">>,
        uri => <<"file:///text">>,
        mime_type => <<"text/plain">>
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/read">>,
        <<"params">> => #{
            <<"uri">> => <<"file:///text">>
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Contents = maps:get(<<"contents">>, Result),

    ?assertEqual(1, length(Contents)),
    [Content] = Contents,
    ?assertEqual(<<"file:///text">>, maps:get(<<"uri">>, Content)),
    ?assertEqual(<<"Hello World">>, maps:get(<<"text">>, Content)),

    barrel_mcp_registry:unreg(resource, <<"text_res">>).

test_read_resource_binary() ->
    ok = barrel_mcp_registry:reg(resource, <<"bin_res">>, ?MODULE, binary_resource, #{
        name => <<"Binary Resource">>,
        uri => <<"file:///binary">>,
        mime_type => <<"application/octet-stream">>
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/read">>,
        <<"params">> => #{
            <<"uri">> => <<"file:///binary">>
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Contents = maps:get(<<"contents">>, Result),

    ?assertEqual(1, length(Contents)),
    [Content] = Contents,
    ?assertEqual(<<"file:///binary">>, maps:get(<<"uri">>, Content)),
    ?assert(maps:is_key(<<"blob">>, Content)),
    ?assertEqual(<<"application/octet-stream">>, maps:get(<<"mimeType">>, Content)),

    barrel_mcp_registry:unreg(resource, <<"bin_res">>).

test_read_resource_json() ->
    ok = barrel_mcp_registry:reg(resource, <<"json_res">>, ?MODULE, json_resource, #{
        name => <<"JSON Resource">>,
        uri => <<"file:///json">>,
        mime_type => <<"application/json">>
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/read">>,
        <<"params">> => #{
            <<"uri">> => <<"file:///json">>
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Contents = maps:get(<<"contents">>, Result),

    ?assertEqual(1, length(Contents)),
    [Content] = Contents,
    ?assertEqual(<<"file:///json">>, maps:get(<<"uri">>, Content)),
    %% Map should be JSON encoded as text
    ?assert(maps:is_key(<<"text">>, Content)),

    barrel_mcp_registry:unreg(resource, <<"json_res">>).

test_read_resource_not_found() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/read">>,
        <<"params">> => #{
            <<"uri">> => <<"file:///nonexistent">>
        }
    },
    Response = barrel_mcp_protocol:handle(Request),
    ?assert(maps:is_key(<<"error">>, Response)),
    Error = maps:get(<<"error">>, Response),
    ?assertEqual(-32601, maps:get(<<"code">>, Error)).

test_resource_mime_type() ->
    ok = barrel_mcp_registry:reg(resource, <<"html_res">>, ?MODULE, text_resource, #{
        name => <<"HTML Resource">>,
        uri => <<"file:///page.html">>,
        mime_type => <<"text/html">>
    }),

    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    [Resource] = maps:get(<<"resources">>, Result),

    ?assertEqual(<<"text/html">>, maps:get(<<"mimeType">>, Resource)),

    barrel_mcp_registry:unreg(resource, <<"html_res">>).

test_list_resource_templates() ->
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/templates/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    Templates = maps:get(<<"resourceTemplates">>, Result),
    ?assertEqual([], Templates).

test_resource_annotations() ->
    Annotations = #{<<"audience">> => [<<"user">>],
                    <<"priority">> => 0.8},
    ok = barrel_mcp_registry:reg(resource, <<"ann_res">>, ?MODULE, text_resource, #{
        name => <<"Annotated">>,
        uri => <<"mem://annotated">>,
        annotations => Annotations
    }),
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"resources/list">>
    },
    Response = barrel_mcp_protocol:handle(Request),
    Result = maps:get(<<"result">>, Response),
    [Resource] = maps:get(<<"resources">>, Result),
    ?assertEqual(Annotations, maps:get(<<"annotations">>, Resource)),
    barrel_mcp_registry:unreg(resource, <<"ann_res">>).
