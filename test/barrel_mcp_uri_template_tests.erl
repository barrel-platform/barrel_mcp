-module(barrel_mcp_uri_template_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% match/2
%%====================================================================

match_simple_var_test() ->
    ?assertEqual(
        {ok, #{<<"path">> => <<"etc/hosts">>}},
        barrel_mcp_uri_template:match(
            <<"file:///etc/hosts">>,
            <<"file:///{path}">>
        )
    ).

match_multiple_vars_test() ->
    ?assertEqual(
        {ok, #{
            <<"kind">> => <<"users">>,
            <<"id">> => <<"42">>
        }},
        barrel_mcp_uri_template:match(
            <<"https://api/v1/users/42">>,
            <<"https://api/v1/{kind}/{id}">>
        )
    ).

match_literal_only_test() ->
    ?assertEqual(
        {ok, #{}},
        barrel_mcp_uri_template:match(
            <<"file:///fixed">>,
            <<"file:///fixed">>
        )
    ).

match_with_trailing_literal_test() ->
    ?assertEqual(
        {ok, #{<<"name">> => <<"hello">>}},
        barrel_mcp_uri_template:match(
            <<"greet:hello/world">>,
            <<"greet:{name}/world">>
        )
    ).

match_no_match_different_prefix_test() ->
    ?assertEqual(
        nomatch,
        barrel_mcp_uri_template:match(
            <<"http:///foo">>,
            <<"file:///{path}">>
        )
    ).

match_no_match_template_too_long_test() ->
    ?assertEqual(
        nomatch,
        barrel_mcp_uri_template:match(
            <<"file:///">>,
            <<"file:///{path}">>
        )
    ).

match_empty_var_value_rejected_test() ->
    %% Trailing variable cannot be empty.
    ?assertEqual(
        nomatch,
        barrel_mcp_uri_template:match(
            <<"file:///">>,
            <<"file:///{path}">>
        )
    ).

match_two_vars_with_separator_test() ->
    ?assertEqual(
        {ok, #{
            <<"kind">> => <<"users">>,
            <<"id">> => <<"42">>
        }},
        barrel_mcp_uri_template:match(
            <<"x:users/42">>,
            <<"x:{kind}/{id}">>
        )
    ).

%%====================================================================
%% expand/2
%%====================================================================

expand_simple_test() ->
    ?assertEqual(
        {ok, <<"file:///etc/hosts">>},
        barrel_mcp_uri_template:expand(
            <<"file:///{path}">>,
            #{<<"path">> => <<"etc/hosts">>}
        )
    ).

expand_multiple_vars_test() ->
    ?assertEqual(
        {ok, <<"https://api/v1/users/42">>},
        barrel_mcp_uri_template:expand(
            <<"https://api/v1/{kind}/{id}">>,
            #{
                <<"kind">> => <<"users">>,
                <<"id">> => <<"42">>
            }
        )
    ).

expand_missing_var_test() ->
    ?assertEqual(
        {error, {missing_var, <<"path">>}},
        barrel_mcp_uri_template:expand(
            <<"file:///{path}">>, #{}
        )
    ).

expand_match_round_trip_test() ->
    Tpl = <<"https://api/v1/{kind}/{id}/details">>,
    Uri = <<"https://api/v1/users/42/details">>,
    {ok, Vars} = barrel_mcp_uri_template:match(Uri, Tpl),
    ?assertEqual(
        {ok, Uri},
        barrel_mcp_uri_template:expand(Tpl, Vars)
    ).

%%====================================================================
%% Malformed templates fall back to nomatch
%%====================================================================

match_malformed_template_test() ->
    ?assertEqual(
        nomatch,
        barrel_mcp_uri_template:match(
            <<"file:///foo">>,
            <<"file:///{">>
        )
    ).
