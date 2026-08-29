%%%-------------------------------------------------------------------
%%% @doc The spec's own wire-shape vectors, checked with our validator.
%%%
%%% `schema.json' is the protocol's JSON Schema and `examples/<Type>/'
%%% holds canonical instances of each message type. Two things are
%%% proved: our validator accepts every canonical instance, and what
%%% our server puts on the wire for the same types is accepted too.
%%%
%%% The conformance runner checks behaviour; this checks shape. A field
%%% that is present but wrongly typed passes the first and fails the
%%% second, which is the case this suite exists for.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_schema_vectors_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([every_vector_validates/1, our_responses_validate/1]).
-export([a_tool/1, a_resource/1, a_prompt/1]).

-define(REVISION, "2026-07-28").

all() -> [every_vector_validates, our_responses_validate].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    {ok, Bin} = file:read_file(filename:join(vectors_dir(), "schema.json")),
    Schema = json:decode(Bin),
    [{schema, Schema} | Config].

end_per_suite(_Config) ->
    application:stop(barrel_mcp),
    ok.

%% Each example directory is named for the `$defs' entry it instantiates.
every_vector_validates(Config) ->
    Schema = ?config(schema, Config),
    Dirs = filelib:wildcard(filename:join([vectors_dir(), "examples", "*"])),
    ?assert(length(Dirs) > 50),
    Failures = lists:append([validate_dir(Schema, Dir) || Dir <- Dirs]),
    case Failures of
        [] -> ok;
        _ -> ct:fail({vectors_rejected, length(Failures), Failures})
    end.

validate_dir(Schema, Dir) ->
    Type = list_to_binary(filename:basename(Dir)),
    Compiled = compile_for(Schema, Type),
    lists:filtermap(
        fun(File) ->
            {ok, Bin} = file:read_file(File),
            case barrel_mcp_jsonschema:validate(json:decode(Bin), Compiled, #{}) of
                ok -> false;
                {error, Errors} -> {true, {Type, filename:basename(File), Errors}}
            end
        end,
        filelib:wildcard(filename:join(Dir, "*.json"))
    ).

%% Our own wire output for the types a client sees most, produced by
%% driving the protocol core with a small catalogue registered.
our_responses_validate(Config) ->
    Schema = ?config(schema, Config),
    ok = barrel_mcp:reg_tool(<<"vec_tool">>, ?MODULE, a_tool, #{
        description => <<"vector fixture">>,
        input_schema => #{<<"type">> => <<"object">>}
    }),
    ok = barrel_mcp:reg_resource(<<"vec_res">>, ?MODULE, a_resource, #{
        uri => <<"mem://vec">>, name => <<"Vec">>, mime_type => <<"text/plain">>
    }),
    ok = barrel_mcp:reg_prompt(<<"vec_prompt">>, ?MODULE, a_prompt, #{
        description => <<"vector fixture">>
    }),
    try
        Cases = [
            {<<"DiscoverResult">>, <<"server/discover">>, #{}},
            {<<"ListToolsResult">>, <<"tools/list">>, #{}},
            {<<"CallToolResult">>, <<"tools/call">>, #{
                <<"name">> => <<"vec_tool">>, <<"arguments">> => #{}
            }},
            {<<"CallToolResult">>, <<"tools/call">>, #{
                <<"name">> => <<"absent">>, <<"arguments">> => #{}
            }},
            {<<"ListResourcesResult">>, <<"resources/list">>, #{}},
            {<<"ReadResourceResult">>, <<"resources/read">>, #{<<"uri">> => <<"mem://vec">>}},
            {<<"ListPromptsResult">>, <<"prompts/list">>, #{}},
            {<<"GetPromptResult">>, <<"prompts/get">>, #{<<"name">> => <<"vec_prompt">>}}
        ],
        Failures = lists:filtermap(
            fun({Type, Method, Params}) ->
                Result = modern_result(Method, Params),
                case barrel_mcp_jsonschema:validate(Result, compile_for(Schema, Type), #{}) of
                    ok -> false;
                    {error, Errors} -> {true, {Type, Method, Errors, Result}}
                end
            end,
            Cases
        ),
        case Failures of
            [] -> ok;
            _ -> ct:fail({our_wire_rejected, Failures})
        end
    after
        barrel_mcp_registry:unreg(tool, <<"vec_tool">>),
        barrel_mcp_registry:unreg(resource, <<"vec_res">>),
        barrel_mcp_registry:unreg(prompt, <<"vec_prompt">>)
    end.

a_tool(_) -> <<"vector">>.
a_resource(_) -> <<"vector body">>.
a_prompt(_) ->
    #{
        messages => [
            #{
                <<"role">> => <<"user">>,
                <<"content">> => #{<<"type">> => <<"text">>, <<"text">> => <<"vector">>}
            }
        ]
    }.

%%====================================================================
%% Helpers
%%====================================================================

%% A schema whose root is one named definition, with every other
%% definition still reachable by `$ref'.
compile_for(Schema, Type) ->
    Root = (maps:get(<<"$defs">>, Schema))#{},
    ?assert(maps:is_key(Type, Root)),
    Doc = #{
        <<"$schema">> => maps:get(<<"$schema">>, Schema),
        <<"$defs">> => Root,
        <<"$ref">> => <<"#/$defs/", Type/binary>>
    },
    {ok, Compiled} = barrel_mcp_jsonschema:compile(Doc),
    Compiled.

modern_result(Method, Params) ->
    Meta = #{
        ?MCP_META_PROTOCOL_VERSION => <<?REVISION>>,
        ?MCP_META_CLIENT_CAPABILITIES => #{}
    },
    Request = #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => Method,
        <<"params">> => Params#{<<"_meta">> => Meta}
    },
    Response =
        case barrel_mcp_protocol:handle(Request, #{}) of
            {async, Plan} -> barrel_mcp_protocol:drive_async_plan(Plan, 5000);
            Other -> Other
        end,
    ?assertMatch(#{<<"result">> := _}, Response),
    maps:get(<<"result">>, Response).

vectors_dir() ->
    Under = filename:join([
        code:lib_dir(barrel_mcp), "..", "..", "..", "..", "test", "schema_vectors", ?REVISION
    ]),
    case filelib:is_dir(Under) of
        true -> Under;
        false -> filename:join(["test", "schema_vectors", ?REVISION])
    end.
