%%%-------------------------------------------------------------------
%%% @doc The engine's embedding contract, the way livery uses it: a
%%% config built from `init_auth/1' and `inject_resource_metadata_url/2',
%%% then `handle/6' with a responder. Also pins that a refusing auth
%%% provider fails at start, for the embedder and for both listeners.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_http_engine_embed_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PORT, 19297).

embed_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 30, [
            {"a config built like livery's answers a request", fun test_embedded_request/0},
            {"a refusing provider fails init_auth", fun test_init_auth_refuses/0},
            {"start_http_stream fails cleanly on a refusing provider",
                fun test_stream_listener_refuses/0},
            {"start_http fails cleanly on a refusing provider", fun test_http_listener_refuses/0}
        ]}}.

setup() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok.

cleanup(_) ->
    ok.

test_embedded_request() ->
    {ok, Auth0} = barrel_mcp_http_engine:init_auth(#{}),
    Meta = barrel_mcp_http_engine:normalize_resource_metadata(undefined),
    Auth = barrel_mcp_http_engine:inject_resource_metadata_url(Auth0, Meta),
    Config = #{
        mode => stream,
        auth_config => Auth,
        session_enabled => false,
        allowed_origins => any,
        allow_missing_origin => true,
        sse_buffer_size => 256,
        resource_metadata => Meta
    },
    Self = self(),
    Responder = #{
        reply => fun(Status, Headers, Body) ->
            Self ! {reply, Status, Headers, iolist_to_binary(Body)},
            ok
        end,
        stream_start => fun(Status, Headers) ->
            Self ! {stream_start, Status, Headers},
            ok
        end,
        stream_chunk => fun(Chunk) ->
            Self ! {stream_chunk, iolist_to_binary(Chunk)},
            ok
        end,
        stream_end => fun() ->
            Self ! stream_end,
            ok
        end
    },
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json, text/event-stream">>}
    ],
    ok = barrel_mcp_http_engine:handle(
        <<"POST">>,
        <<"/mcp">>,
        Headers,
        barrel_mcp_test_helpers:init_body(),
        Responder,
        Config
    ),
    receive
        {reply, 200, _, Body} ->
            #{<<"result">> := #{<<"protocolVersion">> := _}} = json:decode(Body)
    after 5000 ->
        error(no_reply)
    end.

test_init_auth_refuses() ->
    ?assertEqual(
        {error, {auth_provider, barrel_mcp_auth_bearer, {missing_option, audience}}},
        barrel_mcp_http_engine:init_auth(#{
            provider => barrel_mcp_auth_bearer,
            provider_opts => #{secret => <<"s">>}
        })
    ).

test_stream_listener_refuses() ->
    ?assertMatch(
        {error, {auth_provider, barrel_mcp_auth_bearer, _}},
        barrel_mcp:start_http_stream(#{
            port => ?PORT,
            auth => #{provider => barrel_mcp_auth_bearer, provider_opts => #{secret => <<"s">>}}
        })
    ),
    ?assertEqual({error, econnrefused}, gen_tcp:connect({127, 0, 0, 1}, ?PORT, [], 500)).

test_http_listener_refuses() ->
    ?assertMatch(
        {error, {auth_provider, barrel_mcp_auth_bearer, _}},
        barrel_mcp:start_http(#{
            port => ?PORT,
            auth => #{provider => barrel_mcp_auth_bearer, provider_opts => #{secret => <<"s">>}}
        })
    ),
    ?assertEqual({error, econnrefused}, gen_tcp:connect({127, 0, 0, 1}, ?PORT, [], 500)).
