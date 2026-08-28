%%%-------------------------------------------------------------------
%%% @doc URL-mode elicitation: what a server may send, and who may
%%% complete it.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_elicitation_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-import(barrel_mcp_test_helpers, [wait_until/2]).

wait_until(Fun) -> wait_until(Fun, 2000).

-define(HTTPS, <<"https://mcp.example.com/ui/set_api_key">>).

setup() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    application:stop(barrel_mcp),
    ok.

elicitation_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"form mode names its mode and carries the schema", fun form_shape/0},
        {"a legacy URL elicitation is registered under an id", fun legacy_mints_id/0},
        {"a modern one is not: the era has no elicitationId", fun modern_has_no_id/0},
        {"only the owning principal can complete one", fun completion_is_owned/0},
        {"and only once", fun completion_is_terminal/0},
        {"plain http is refused unless development says otherwise", fun http_refused/0},
        {"so is any scheme that is not http(s)", fun other_schemes_refused/0},
        {"and credentials in the url", fun userinfo_refused/0},
        {"a dead session takes its elicitations with it", fun session_cleanup/0},
        {"one principal cannot fill the table", fun admission_bound/0}
    ]}.

form_shape() ->
    Schema = #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{<<"name">> => #{<<"type">> => <<"string">>}}
    },
    Params = barrel_mcp_elicitation:form(<<"Your name?">>, Schema),
    ?assertEqual(<<"form">>, maps:get(<<"mode">>, Params)),
    ?assertEqual(<<"Your name?">>, maps:get(<<"message">>, Params)),
    ?assertEqual(Schema, maps:get(<<"requestedSchema">>, Params)),
    ?assertNot(maps:is_key(<<"url">>, Params)).

legacy_mints_id() ->
    {ok, Params} = barrel_mcp_elicitation:url(<<"Connect">>, ?HTTPS, legacy_ctx(<<"ada">>)),
    ?assertEqual(<<"url">>, maps:get(<<"mode">>, Params)),
    ?assertEqual(?HTTPS, maps:get(<<"url">>, Params)),
    Id = maps:get(<<"elicitationId">>, Params),
    ?assert(is_binary(Id)),
    %% Registered against the principal, and the host is what was kept.
    {ok, Entry} = barrel_mcp_elicitation:lookup(Id, <<"ada">>),
    ?assertEqual(<<"mcp.example.com">>, maps:get(host, Entry)),
    ?assertEqual(false, maps:get(completed, Entry)).

modern_has_no_id() ->
    {ok, Params} = barrel_mcp_elicitation:url(<<"Connect">>, ?HTTPS, modern_ctx(<<"ada">>)),
    ?assertEqual(<<"url">>, maps:get(<<"mode">>, Params)),
    ?assertNot(maps:is_key(<<"elicitationId">>, Params)).

completion_is_owned() ->
    {ok, Params} = barrel_mcp_elicitation:url(<<"Connect">>, ?HTTPS, legacy_ctx(<<"ada">>)),
    Id = maps:get(<<"elicitationId">>, Params),
    %% Another principal is told the same thing as someone naming an id
    %% that does not exist, so the table cannot be probed.
    ?assertEqual({error, not_found}, barrel_mcp_elicitation:complete(Id, <<"eve">>)),
    ?assertEqual({error, not_found}, barrel_mcp_elicitation:lookup(Id, <<"eve">>)),
    ?assertEqual(ok, barrel_mcp_elicitation:complete(Id, <<"ada">>)).

completion_is_terminal() ->
    {ok, Params} = barrel_mcp_elicitation:url(<<"Connect">>, ?HTTPS, legacy_ctx(<<"grace">>)),
    Id = maps:get(<<"elicitationId">>, Params),
    ?assertEqual(ok, barrel_mcp_elicitation:complete(Id, <<"grace">>)),
    ?assertEqual(
        {error, already_complete},
        barrel_mcp_elicitation:complete(Id, <<"grace">>)
    ).

http_refused() ->
    Plain = <<"http://mcp.example.com/ui">>,
    ?assertEqual(
        {error, insecure_url},
        barrel_mcp_elicitation:url(<<"Connect">>, Plain, legacy_ctx(<<"ada">>))
    ),
    application:set_env(barrel_mcp, allow_insecure_elicitation_url, true),
    try
        ?assertMatch(
            {ok, _},
            barrel_mcp_elicitation:url(<<"Connect">>, Plain, legacy_ctx(<<"ada">>))
        )
    after
        application:unset_env(barrel_mcp, allow_insecure_elicitation_url)
    end.

other_schemes_refused() ->
    lists:foreach(
        fun(Url) ->
            ?assertMatch(
                {error, _},
                barrel_mcp_elicitation:url(<<"Go">>, Url, legacy_ctx(<<"ada">>))
            )
        end,
        [
            <<"javascript:alert(1)">>,
            <<"file:///etc/passwd">>,
            <<"data:text/html,hi">>,
            <<"/relative/path">>
        ]
    ).

userinfo_refused() ->
    ?assertEqual(
        {error, url_has_credentials},
        barrel_mcp_elicitation:url(
            <<"Go">>, <<"https://user:pw@mcp.example.com/ui">>, legacy_ctx(<<"ada">>)
        )
    ).

session_cleanup() ->
    Ctx = legacy_ctx(<<"linus">>, <<"sess-doomed">>),
    {ok, Params} = barrel_mcp_elicitation:url(<<"Connect">>, ?HTTPS, Ctx),
    Id = maps:get(<<"elicitationId">>, Params),
    ?assertMatch({ok, _}, barrel_mcp_elicitation:lookup(Id, <<"linus">>)),
    ok = barrel_mcp_elicitation:forget_session(<<"sess-doomed">>),
    wait_until(
        fun() -> barrel_mcp_elicitation:lookup(Id, <<"linus">>) =:= {error, not_found} end
    ),
    ?assertEqual({error, not_found}, barrel_mcp_elicitation:lookup(Id, <<"linus">>)).

admission_bound() ->
    application:set_env(barrel_mcp, max_elicitations_per_principal, 2),
    try
        Ctx = legacy_ctx(<<"noisy">>),
        ?assertMatch({ok, _}, barrel_mcp_elicitation:url(<<"a">>, ?HTTPS, Ctx)),
        ?assertMatch({ok, _}, barrel_mcp_elicitation:url(<<"b">>, ?HTTPS, Ctx)),
        ?assertEqual(
            {error, too_many_elicitations},
            barrel_mcp_elicitation:url(<<"c">>, ?HTTPS, Ctx)
        )
    after
        application:unset_env(barrel_mcp, max_elicitations_per_principal)
    end.

%%====================================================================
%% Mode gating
%%====================================================================

modes_test_() ->
    [
        {"an empty elicitation object means form only", fun() ->
            ?assertEqual([<<"form">>], modes(#{<<"elicitation">> => #{}}))
        end},
        {"so does no elicitation at all", fun() ->
            ?assertEqual([<<"form">>], modes(#{}))
        end},
        {"declared modes are read as declared", fun() ->
            ?assertEqual(
                [<<"form">>, <<"url">>],
                modes(#{<<"elicitation">> => #{<<"form">> => #{}, <<"url">> => #{}}})
            ),
            ?assertEqual(
                [<<"url">>],
                modes(#{<<"elicitation">> => #{<<"url">> => #{}}})
            )
        end}
    ].

modes(Caps) ->
    barrel_mcp_ctx:elicitation_modes(modern_ctx_with(Caps)).

%%====================================================================
%% Helpers
%%====================================================================

legacy_ctx(Principal) ->
    legacy_ctx(Principal, <<"sess-1">>).

legacy_ctx(Principal, SessionId) ->
    barrel_mcp_ctx:from_request(
        #{<<"method">> => <<"tools/call">>, <<"params">> => #{}},
        #{
            session_id => SessionId,
            auth_info => #{principal => Principal},
            protocol_version => <<"2025-11-25">>
        }
    ).

modern_ctx(Principal) ->
    barrel_mcp_ctx:from_request(
        #{
            <<"method">> => <<"tools/call">>,
            <<"params">> => #{
                <<"_meta">> => #{
                    ?MCP_META_PROTOCOL_VERSION => <<"2026-07-28">>,
                    ?MCP_META_CLIENT_CAPABILITIES => #{}
                }
            }
        },
        #{auth_info => #{principal => Principal}}
    ).

modern_ctx_with(Caps) ->
    barrel_mcp_ctx:from_request(
        #{
            <<"method">> => <<"tools/call">>,
            <<"params">> => #{
                <<"_meta">> => #{
                    ?MCP_META_PROTOCOL_VERSION => <<"2026-07-28">>,
                    ?MCP_META_CLIENT_CAPABILITIES => Caps
                }
            }
        },
        #{}
    ).
