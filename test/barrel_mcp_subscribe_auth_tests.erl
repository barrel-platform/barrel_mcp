%%%-------------------------------------------------------------------
%%% @doc `instructions' on `initialize', the subscription hook
%%% (`authorize_subscribe/3') and the `resource_metadata' hint on any
%%% provider's challenge.
%%%
%%% This module is also the auth provider under test: it refuses any URI
%%% under `memory://private/'.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_subscribe_auth_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

%% barrel_mcp_auth provider, and barrel_mcp_auth_custom module.
-export([init/1, authenticate/2, challenge/2, authorize_subscribe/3]).

-define(PRIVATE, <<"memory://private/1">>).
-define(PUBLIC, <<"memory://shared/1">>).

init(Opts) -> {ok, Opts}.

authenticate(_Token, State) -> {ok, #{subject => <<"alice">>}, State}.

challenge(_Reason, _State) -> {401, #{}, <<>>}.

authorize_subscribe(_AuthInfo, <<"memory://private/", _/binary>>, _State) -> false;
authorize_subscribe(_AuthInfo, <<"memory://boom/", _/binary>>, _State) -> error(boom);
authorize_subscribe(_AuthInfo, _Uri, _State) -> true.

%%====================================================================
%% instructions
%%====================================================================

initialize_instructions_test_() ->
    {setup, fun start/0, fun(_) -> application:unset_env(barrel_mcp, instructions) end, [
        {"Absent when not configured", fun no_instructions/0},
        {"Carried when configured", fun instructions_set/0}
    ]}.

start() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok.

no_instructions() ->
    application:unset_env(barrel_mcp, instructions),
    ?assertNot(maps:is_key(<<"instructions">>, initialize_result())).

instructions_set() ->
    application:set_env(barrel_mcp, instructions, <<"Keep your memory here.">>),
    ?assertEqual(
        <<"Keep your memory here.">>, maps:get(<<"instructions">>, initialize_result())
    ).

initialize_result() ->
    Resp = barrel_mcp_protocol:handle(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => 1,
        <<"method">> => <<"initialize">>,
        <<"params">> => #{
            <<"protocolVersion">> => ?MCP_LATEST_LEGACY_VERSION,
            <<"capabilities">> => #{},
            <<"clientInfo">> => #{<<"name">> => <<"t">>, <<"version">> => <<"0">>}
        }
    }),
    maps:get(<<"result">>, Resp).

%%====================================================================
%% Subscriptions
%%====================================================================

subscribe_test_() ->
    {setup, fun start/0, fun(_) -> ok end, [
        {"resources/subscribe refused by the hook", fun subscribe_refused/0},
        {"resources/subscribe accepted by the hook", fun subscribe_allowed/0},
        {"resources/subscribe accepted without a hook", fun subscribe_no_hook/0},
        {"A raising hook refuses", fun subscribe_hook_raises/0},
        {"listen drops refused URIs", fun listen_narrowed/0},
        {"listen keeps every URI without a hook", fun listen_no_hook/0},
        {"The custom provider forwards the hook", fun custom_forwards/0}
    ]}.

auth(Provider) ->
    #{
        auth_config => #{provider => Provider, provider_state => #{}},
        auth_info => #{subject => <<"alice">>}
    }.

subscribe(Uri, Extra) ->
    {ok, Sid} = barrel_mcp_session:create(#{}),
    barrel_mcp_protocol:handle(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 2,
            <<"method">> => <<"resources/subscribe">>,
            <<"params">> => #{<<"uri">> => Uri}
        },
        Extra#{session_id => Sid}
    ).

subscribe_refused() ->
    #{<<"error">> := Error} = subscribe(?PRIVATE, auth(?MODULE)),
    %% The same answer a missing resource gets.
    ?assertEqual(?MCP_RESOURCE_NOT_FOUND, maps:get(<<"code">>, Error)),
    ?assertEqual(<<"Resource not found">>, maps:get(<<"message">>, Error)).

subscribe_allowed() ->
    ?assertMatch(#{<<"result">> := #{}}, subscribe(?PUBLIC, auth(?MODULE))).

subscribe_no_hook() ->
    ?assertMatch(#{<<"result">> := #{}}, subscribe(?PRIVATE, auth(barrel_mcp_auth_none))),
    ?assertMatch(#{<<"result">> := #{}}, subscribe(?PRIVATE, #{})).

subscribe_hook_raises() ->
    ?assertMatch(#{<<"error">> := _}, subscribe(<<"memory://boom/1">>, auth(?MODULE))).

listen(Uris, Extra) ->
    barrel_mcp_protocol:handle(
        #{
            <<"jsonrpc">> => <<"2.0">>,
            <<"id">> => 3,
            <<"method">> => <<"subscriptions/listen">>,
            <<"params">> => #{
                <<"notifications">> => #{<<"resourceSubscriptions">> => Uris},
                <<"_meta">> => #{
                    ?MCP_META_PROTOCOL_VERSION => <<"2026-07-28">>,
                    ?MCP_META_CLIENT_CAPABILITIES => #{}
                }
            }
        },
        Extra#{streaming => true}
    ).

listen_narrowed() ->
    {subscribe, #{filter := Filter}} = listen([?PRIVATE, ?PUBLIC], auth(?MODULE)),
    ?assertEqual([?PUBLIC], maps:get(resource_subscriptions, Filter)),
    {subscribe, #{filter := Only}} = listen([?PRIVATE], auth(?MODULE)),
    ?assertNot(maps:is_key(resource_subscriptions, Only)).

listen_no_hook() ->
    {subscribe, #{filter := Filter}} = listen([?PRIVATE, ?PUBLIC], auth(barrel_mcp_auth_none)),
    ?assertEqual([?PRIVATE, ?PUBLIC], maps:get(resource_subscriptions, Filter)).

custom_forwards() ->
    {ok, State} = barrel_mcp_auth_custom:init(#{module => ?MODULE}),
    Config = #{provider => barrel_mcp_auth_custom, provider_state => State},
    Info = #{subject => <<"alice">>},
    ?assertNot(barrel_mcp_auth:authorize_subscribe(Config, ?PRIVATE, Info)),
    ?assert(barrel_mcp_auth:authorize_subscribe(Config, ?PUBLIC, Info)),
    %% A module without the callback accepts everything.
    {ok, Plain} = barrel_mcp_auth_custom:init(#{module => test_auth_module}),
    ?assert(
        barrel_mcp_auth:authorize_subscribe(
            #{provider => barrel_mcp_auth_custom, provider_state => Plain}, ?PRIVATE, Info
        )
    ).

%%====================================================================
%% resource_metadata hint
%%====================================================================

-define(META_URL, <<"https://mcp.test/.well-known/oauth-protected-resource">>).

challenge_hint_test_() ->
    [
        {"Custom provider names the metadata when configured", fun custom_hint/0},
        {"No hint without resource_metadata", fun no_hint/0},
        {"Bearer keeps a single hint", fun bearer_single_hint/0},
        {"A challenge without the header gets one", fun header_added/0}
    ].

custom_config(Extra) ->
    {ok, State} = barrel_mcp_auth_custom:init(#{module => ?MODULE}),
    #{provider => barrel_mcp_auth_custom, provider_state => maps:merge(State, Extra)}.

www_authenticate(Config) ->
    {401, Headers, _} = barrel_mcp_auth:challenge_response(Config, unauthorized),
    maps:get(<<"www-authenticate">>, Headers, undefined).

custom_hint() ->
    Value = www_authenticate(custom_config(#{resource_metadata_url => ?META_URL})),
    ?assertEqual(
        <<"Bearer realm=\"mcp\", resource_metadata=\"", ?META_URL/binary, "\"">>, Value
    ).

no_hint() ->
    ?assertEqual(<<"Bearer realm=\"mcp\"">>, www_authenticate(custom_config(#{}))).

bearer_single_hint() ->
    {ok, State} = barrel_mcp_auth_bearer:init(#{
        secret => <<"s">>, audience => <<"https://mcp.test/mcp">>
    }),
    Value = www_authenticate(#{
        provider => barrel_mcp_auth_bearer,
        provider_state => State#{resource_metadata_url => ?META_URL}
    }),
    ?assertEqual(1, length(binary:matches(Value, <<"resource_metadata=">>))).

header_added() ->
    Value = www_authenticate(#{
        provider => ?MODULE, provider_state => #{resource_metadata_url => ?META_URL}
    }),
    ?assertEqual(<<"Bearer resource_metadata=\"", ?META_URL/binary, "\"">>, Value).
