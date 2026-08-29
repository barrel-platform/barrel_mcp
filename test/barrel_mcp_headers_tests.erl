%%%-------------------------------------------------------------------
%%% @doc Table-driven tests for the MCP request metadata headers.
%%%
%%% Encoding has to be exact: the client builds these headers and the
%%% server rejects the request when they disagree with the body, so any
%%% asymmetry between the two sides is a broken request rather than a
%%% cosmetic bug.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_headers_tests).

-include_lib("eunit/include/eunit.hrl").

-export([dummy_tool/1]).

dummy_tool(_Args) -> <<"ok">>.

%%====================================================================
%% Value encoding
%%====================================================================

encode_plain_ascii_test() ->
    ?assertEqual(<<"us-west1">>, barrel_mcp_headers:encode_value(<<"us-west1">>)).

encode_integer_test() ->
    ?assertEqual(<<"42">>, barrel_mcp_headers:encode_value(42)),
    ?assertEqual(<<"-7">>, barrel_mcp_headers:encode_value(-7)).

encode_boolean_test() ->
    ?assertEqual(<<"true">>, barrel_mcp_headers:encode_value(true)),
    ?assertEqual(<<"false">>, barrel_mcp_headers:encode_value(false)).

%% Every vector from the spec's encoding table.
encode_spec_vectors_test() ->
    Vectors = [
        {<<"us-west1">>, <<"us-west1">>},
        {<<"Hello, 世界"/utf8>>, <<"=?base64?SGVsbG8sIOS4lueVjA==?=">>},
        {<<" padded ">>, <<"=?base64?IHBhZGRlZCA=?=">>},
        {<<"line1\nline2">>, <<"=?base64?bGluZTEKbGluZTI=?=">>},
        {<<"=?base64?literal?=">>, <<"=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=">>}
    ],
    lists:foreach(
        fun({Input, Expected}) ->
            ?assertEqual(Expected, barrel_mcp_headers:encode_value(Input))
        end,
        Vectors
    ).

%% Whatever we encode, we must be able to decode back.
encode_decode_round_trip_test() ->
    Values = [
        <<"plain">>,
        <<"Hello, 世界"/utf8>>,
        <<" padded ">>,
        <<"line1\nline2">>,
        <<"=?base64?literal?=">>,
        <<"tab\there">>,
        <<>>,
        <<0, 1, 2, 255>>
    ],
    lists:foreach(
        fun(V) ->
            Encoded = barrel_mcp_headers:encode_value(V),
            ?assertEqual({ok, V}, barrel_mcp_headers:decode_value(Encoded))
        end,
        Values
    ).

is_safe_value_test() ->
    ?assert(barrel_mcp_headers:is_safe_value(<<"plain">>)),
    ?assert(barrel_mcp_headers:is_safe_value(<<"with space inside">>)),
    ?assert(barrel_mcp_headers:is_safe_value(<<>>)),
    ?assertNot(barrel_mcp_headers:is_safe_value(<<" leading">>)),
    ?assertNot(barrel_mcp_headers:is_safe_value(<<"trailing ">>)),
    ?assertNot(barrel_mcp_headers:is_safe_value(<<"tab\ttrailing\t">>)),
    ?assertNot(barrel_mcp_headers:is_safe_value(<<"nl\n">>)),
    ?assertNot(barrel_mcp_headers:is_safe_value(<<"cr\r">>)),
    ?assertNot(barrel_mcp_headers:is_safe_value(<<"héllo"/utf8>>)),
    %% Looks like the sentinel, so it must not travel as itself.
    ?assertNot(barrel_mcp_headers:is_safe_value(<<"=?base64?x?=">>)).

decode_rejects_bad_base64_test() ->
    ?assertEqual(
        {error, invalid_encoding},
        barrel_mcp_headers:decode_value(<<"=?base64?!!!not!!!?=">>)
    ).

%% A header value carrying a raw newline is a request-splitting
%% attempt, not something to decode leniently.
decode_rejects_control_characters_test() ->
    ?assertEqual(
        {error, invalid_encoding},
        barrel_mcp_headers:decode_value(<<"evil\r\nX-Injected: 1">>)
    ).

%% A prefix without the suffix is not a sentinel.
decode_partial_sentinel_is_literal_test() ->
    ?assertEqual({ok, <<"=?base64?abc">>}, barrel_mcp_headers:decode_value(<<"=?base64?abc">>)).

%%====================================================================
%% Standard headers
%%====================================================================

standard_tools_call_test() ->
    Headers = barrel_mcp_headers:standard(<<"tools/call">>, #{<<"name">> => <<"get_weather">>}),
    ?assertEqual(<<"tools/call">>, proplists:get_value(<<"mcp-method">>, Headers)),
    ?assertEqual(<<"get_weather">>, proplists:get_value(<<"mcp-name">>, Headers)).

standard_resources_read_uses_uri_test() ->
    Headers = barrel_mcp_headers:standard(
        <<"resources/read">>,
        #{<<"uri">> => <<"file:///projects/app/config.json">>}
    ),
    ?assertEqual(
        <<"file:///projects/app/config.json">>,
        proplists:get_value(<<"mcp-name">>, Headers)
    ).

%% Tool and prompt names are only SHOULD-constrained to header-safe
%% characters, so an awkward one still has to travel.
standard_encodes_awkward_name_test() ->
    Headers = barrel_mcp_headers:standard(
        <<"prompts/get">>,
        #{<<"name">> => <<"résumé"/utf8>>}
    ),
    Encoded = proplists:get_value(<<"mcp-name">>, Headers),
    ?assertEqual({ok, <<"résumé"/utf8>>}, barrel_mcp_headers:decode_value(Encoded)).

standard_other_method_has_no_name_test() ->
    Headers = barrel_mcp_headers:standard(<<"tools/list">>, #{}),
    ?assertEqual([{<<"mcp-method">>, <<"tools/list">>}], Headers).

%%====================================================================
%% Parameter headers
%%====================================================================

bindings() ->
    {ok, B} = barrel_mcp_headers:scan_header_params(#{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"region">> => #{<<"type">> => <<"string">>, <<"x-mcp-header">> => <<"Region">>},
            <<"query">> => #{<<"type">> => <<"string">>}
        }
    }),
    B.

param_headers_test() ->
    Headers = barrel_mcp_headers:param_headers(
        #{<<"region">> => <<"us-west1">>, <<"query">> => <<"SELECT 1">>},
        bindings()
    ),
    ?assertEqual([{<<"mcp-param-region">>, <<"us-west1">>}], Headers).

%% Absent and null both mean "omit the header", not "send it empty".
param_headers_omit_absent_test() ->
    ?assertEqual([], barrel_mcp_headers:param_headers(#{}, bindings())),
    ?assertEqual(
        [],
        barrel_mcp_headers:param_headers(#{<<"region">> => null}, bindings())
    ).

param_headers_nested_path_test() ->
    {ok, Bindings} = barrel_mcp_headers:scan_header_params(#{
        <<"properties">> => #{
            <<"outer">> => #{
                <<"type">> => <<"object">>,
                <<"properties">> => #{
                    <<"inner">> => #{
                        <<"type">> => <<"integer">>,
                        <<"x-mcp-header">> => <<"Inner">>
                    }
                }
            }
        }
    }),
    ?assertEqual([{<<"Inner">>, [<<"outer">>, <<"inner">>]}], Bindings),
    ?assertEqual(
        [{<<"mcp-param-inner">>, <<"7">>}],
        barrel_mcp_headers:param_headers(#{<<"outer">> => #{<<"inner">> => 7}}, Bindings)
    ).

%%====================================================================
%% Schema annotation validity
%%====================================================================

scan_plain_schema_test() ->
    ?assertEqual(
        {ok, []},
        barrel_mcp_headers:scan_header_params(#{
            <<"type">> => <<"object">>,
            <<"properties">> => #{<<"a">> => #{<<"type">> => <<"string">>}}
        })
    ).

scan_rejects_empty_name_test() ->
    ?assertMatch(
        {error, {invalid_x_mcp_header, <<>>}},
        scan_with(#{<<"type">> => <<"string">>, <<"x-mcp-header">> => <<>>})
    ).

scan_rejects_non_tchar_name_test() ->
    lists:foreach(
        fun(Name) ->
            ?assertMatch(
                {error, {invalid_x_mcp_header, _}},
                scan_with(#{<<"type">> => <<"string">>, <<"x-mcp-header">> => Name})
            )
        end,
        [<<"has space">>, <<"has\r\nnewline">>, <<"has:colon">>, <<"héader"/utf8>>]
    ).

scan_rejects_number_type_test() ->
    ?assertMatch(
        {error, {x_mcp_header_on_non_primitive, <<"N">>}},
        scan_with(#{<<"type">> => <<"number">>, <<"x-mcp-header">> => <<"N">>})
    ).

scan_rejects_object_and_array_test() ->
    ?assertMatch(
        {error, {x_mcp_header_on_non_primitive, _}},
        scan_with(#{<<"type">> => <<"object">>, <<"x-mcp-header">> => <<"O">>})
    ),
    ?assertMatch(
        {error, {x_mcp_header_on_non_primitive, _}},
        scan_with(#{<<"type">> => <<"array">>, <<"x-mcp-header">> => <<"A">>})
    ).

scan_rejects_annotation_beside_a_ref_test() ->
    ?assertMatch(
        {error, {x_mcp_header_on_ref, <<"R">>}},
        scan_with(#{<<"$ref">> => <<"#/$defs/thing">>, <<"x-mcp-header">> => <<"R">>})
    ).

scan_rejects_case_insensitive_duplicate_test() ->
    ?assertMatch(
        {error, {duplicate_x_mcp_header, <<"region">>}},
        barrel_mcp_headers:scan_header_params(#{
            <<"properties">> => #{
                <<"a">> => #{<<"type">> => <<"string">>, <<"x-mcp-header">> => <<"Region">>},
                <<"b">> => #{<<"type">> => <<"string">>, <<"x-mcp-header">> => <<"REGION">>}
            }
        })
    ).

%% Nothing behind a keyword with no single instance path may carry an
%% annotation.
scan_rejects_unreachable_annotation_test() ->
    Annotated = #{<<"type">> => <<"string">>, <<"x-mcp-header">> => <<"X">>},
    Cases = [
        #{<<"items">> => Annotated},
        #{<<"oneOf">> => [Annotated]},
        #{<<"anyOf">> => [Annotated]},
        #{<<"allOf">> => [#{<<"properties">> => #{<<"a">> => Annotated}}]},
        #{<<"not">> => Annotated},
        #{<<"if">> => Annotated},
        #{<<"$defs">> => #{<<"d">> => Annotated}},
        #{
            <<"properties">> => #{
                <<"list">> => #{
                    <<"type">> => <<"array">>,
                    <<"items">> => #{<<"properties">> => #{<<"deep">> => Annotated}}
                }
            }
        }
    ],
    lists:foreach(
        fun(Schema) ->
            ?assertEqual(
                {error, x_mcp_header_not_statically_reachable},
                barrel_mcp_headers:scan_header_params(Schema)
            )
        end,
        Cases
    ).

scan_with(PropertySchema) ->
    barrel_mcp_headers:scan_header_params(#{
        <<"type">> => <<"object">>,
        <<"properties">> => #{<<"p">> => PropertySchema}
    }).

%%====================================================================
%% Validation
%%====================================================================

validate(Headers, Method, Params) ->
    barrel_mcp_headers:validate(Headers, Method, Params, []).

validate_ok_test() ->
    Params = #{<<"name">> => <<"echo">>},
    Headers = barrel_mcp_headers:standard(<<"tools/call">>, Params),
    ?assertEqual(ok, validate(Headers, <<"tools/call">>, Params)).

validate_missing_method_header_test() ->
    ?assertMatch(
        {error, <<"Header mismatch: Mcp-Method header is required">>},
        validate([], <<"tools/list">>, #{})
    ).

validate_method_mismatch_test() ->
    ?assertMatch(
        {error, _},
        validate([{<<"mcp-method">>, <<"tools/list">>}], <<"tools/call">>, #{
            <<"name">> => <<"x">>
        })
    ).

validate_name_mismatch_test() ->
    Headers = [{<<"mcp-method">>, <<"tools/call">>}, {<<"mcp-name">>, <<"foo">>}],
    ?assertMatch(
        {error, _},
        validate(Headers, <<"tools/call">>, #{<<"name">> => <<"bar">>})
    ).

validate_missing_name_header_test() ->
    ?assertMatch(
        {error, <<"Header mismatch: Mcp-Name header is required">>},
        validate([{<<"mcp-method">>, <<"tools/call">>}], <<"tools/call">>, #{
            <<"name">> => <<"x">>
        })
    ).

validate_decodes_before_comparing_test() ->
    Name = <<"世界"/utf8>>,
    Headers = [
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, barrel_mcp_headers:encode_value(Name)}
    ],
    ?assertEqual(ok, validate(Headers, <<"tools/call">>, #{<<"name">> => Name})).

validate_header_case_insensitive_test() ->
    Headers = [{<<"MCP-Method">>, <<"tools/call">>}, {<<"Mcp-Name">>, <<"echo">>}],
    ?assertEqual(ok, validate(Headers, <<"tools/call">>, #{<<"name">> => <<"echo">>})).

%% Header names are case-insensitive; values are not.
validate_value_case_sensitive_test() ->
    Headers = [{<<"mcp-method">>, <<"tools/call">>}, {<<"mcp-name">>, <<"ECHO">>}],
    ?assertMatch(
        {error, _},
        validate(Headers, <<"tools/call">>, #{<<"name">> => <<"echo">>})
    ).

validate_rejects_injected_header_value_test() ->
    Headers = [
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, <<"echo\r\nX-Injected: 1">>}
    ],
    ?assertMatch(
        {error, _},
        validate(Headers, <<"tools/call">>, #{<<"name">> => <<"echo\r\nX-Injected: 1">>})
    ).

%%====================================================================
%% Validation of x-mcp-header parameters
%%====================================================================

validate_param_ok_test() ->
    Params = #{
        <<"name">> => <<"execute_sql">>,
        <<"arguments">> => #{<<"region">> => <<"us-west1">>}
    },
    Headers =
        barrel_mcp_headers:standard(<<"tools/call">>, Params) ++
            barrel_mcp_headers:param_headers(
                maps:get(<<"arguments">>, Params), bindings()
            ),
    ?assertEqual(
        ok,
        barrel_mcp_headers:validate(Headers, <<"tools/call">>, Params, bindings())
    ).

validate_param_missing_header_test() ->
    Params = #{
        <<"name">> => <<"execute_sql">>,
        <<"arguments">> => #{<<"region">> => <<"us-west1">>}
    },
    Headers = barrel_mcp_headers:standard(<<"tools/call">>, Params),
    ?assertMatch(
        {error, <<"Header mismatch: Mcp-Param-Region header is required">>},
        barrel_mcp_headers:validate(Headers, <<"tools/call">>, Params, bindings())
    ).

validate_param_absent_on_both_sides_test() ->
    Params = #{<<"name">> => <<"execute_sql">>, <<"arguments">> => #{}},
    Headers = barrel_mcp_headers:standard(<<"tools/call">>, Params),
    ?assertEqual(
        ok,
        barrel_mcp_headers:validate(Headers, <<"tools/call">>, Params, bindings())
    ).

%% A header with nothing behind it in the body is as much a mismatch as
%% a wrong value: an intermediary may have routed on it.
validate_param_header_without_body_value_test() ->
    Params = #{<<"name">> => <<"execute_sql">>, <<"arguments">> => #{}},
    Headers =
        barrel_mcp_headers:standard(<<"tools/call">>, Params) ++
            [{<<"mcp-param-region">>, <<"us-west1">>}],
    ?assertMatch(
        {error, _},
        barrel_mcp_headers:validate(Headers, <<"tools/call">>, Params, bindings())
    ).

%% 42 and 42.0 are the same number, so they agree.
validate_param_numeric_comparison_test() ->
    {ok, Bindings} = barrel_mcp_headers:scan_header_params(#{
        <<"properties">> => #{
            <<"n">> => #{<<"type">> => <<"integer">>, <<"x-mcp-header">> => <<"N">>}
        }
    }),
    Params = #{<<"name">> => <<"t">>, <<"arguments">> => #{<<"n">> => 42.0}},
    Headers = [
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, <<"t">>},
        {<<"mcp-param-n">>, <<"42">>}
    ],
    ?assertEqual(
        ok,
        barrel_mcp_headers:validate(Headers, <<"tools/call">>, Params, Bindings)
    ).

validate_param_boolean_test() ->
    {ok, Bindings} = barrel_mcp_headers:scan_header_params(#{
        <<"properties">> => #{
            <<"flag">> => #{<<"type">> => <<"boolean">>, <<"x-mcp-header">> => <<"Flag">>}
        }
    }),
    Params = #{<<"name">> => <<"t">>, <<"arguments">> => #{<<"flag">> => true}},
    Headers = [
        {<<"mcp-method">>, <<"tools/call">>},
        {<<"mcp-name">>, <<"t">>},
        {<<"mcp-param-flag">>, <<"true">>}
    ],
    ?assertEqual(
        ok,
        barrel_mcp_headers:validate(Headers, <<"tools/call">>, Params, Bindings)
    ).

%%====================================================================
%% Registration
%%====================================================================

%% An invalid annotation must fail registration, not surface on some
%% later call when a client happens to use the tool.
registration_rejects_invalid_annotation_test() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    Bad = #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"n">> => #{<<"type">> => <<"number">>, <<"x-mcp-header">> => <<"N">>}
        }
    },
    ?assertMatch(
        {error, {invalid_input_schema, {x_mcp_header_on_non_primitive, <<"N">>}}},
        barrel_mcp_registry:reg(tool, <<"bad_hdr">>, ?MODULE, dummy_tool, #{
            input_schema => Bad
        })
    ),
    ?assertEqual(error, barrel_mcp_registry:find(tool, <<"bad_hdr">>)).

registration_stores_bindings_test() ->
    application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    Schema = #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"region">> => #{<<"type">> => <<"string">>, <<"x-mcp-header">> => <<"Region">>}
        }
    },
    ok = barrel_mcp_registry:reg(tool, <<"good_hdr">>, ?MODULE, dummy_tool, #{
        input_schema => Schema
    }),
    {ok, Handler} = barrel_mcp_registry:find(tool, <<"good_hdr">>),
    ?assertEqual([{<<"Region">>, [<<"region">>]}], maps:get(header_params, Handler)),
    barrel_mcp_registry:unreg(tool, <<"good_hdr">>).

%% Past the JSON safe range the two ends do not agree on the value, so
%% there is nothing a mirrored header could prove.
param_header_skips_unsafe_integers_test() ->
    Bindings = [{<<"N">>, [<<"n">>]}],
    Safe = 9007199254740991,
    ?assertEqual(
        [{<<"mcp-param-n">>, <<"9007199254740991">>}],
        barrel_mcp_headers:param_headers(#{<<"n">> => Safe}, Bindings)
    ),
    ?assertEqual([], barrel_mcp_headers:param_headers(#{<<"n">> => Safe + 1}, Bindings)),
    ?assertEqual([], barrel_mcp_headers:param_headers(#{<<"n">> => -Safe - 1}, Bindings)).
