%%%-------------------------------------------------------------------
%%% @doc Vectors for the MRTR request state.
%%%
%%% This blob travels through the client, so every case here is really
%%% the same question: can something the client changed be made to pass
%%% verification. The answer has to be no for all of them.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_request_state_tests).

-include_lib("eunit/include/eunit.hrl").

-define(KEY, <<"a fixed test key, 32 bytes long!">>).

%%====================================================================
%% Fixture
%%====================================================================

request_state_test_() ->
    {setup, fun setup/0, fun cleanup/1, [
        {"Round trip returns the term", fun round_trip/0},
        {"Any term survives", fun arbitrary_terms/0},
        {"A tampered byte is rejected", fun tampered/0},
        {"A truncated blob is rejected", fun truncated/0},
        {"Garbage is rejected", fun garbage/0},
        {"An oversized blob is rejected without decoding", fun oversized/0},
        {"An expired blob is rejected", fun expired/0},
        {"Another principal is rejected", fun other_principal/0},
        {"Another method is rejected", fun other_method/0},
        {"Changed parameters are rejected", fun changed_params/0},
        {"A rotated key is rejected", fun rotated_key/0},
        {"Retry fields do not affect the digest", fun retry_fields_ignored/0},
        {"Parameter key order does not matter", fun key_order/0},
        {"An absent principal still binds", fun undefined_principal/0}
    ]}.

setup() ->
    Prev = application:get_env(barrel_mcp, request_state_key),
    application:set_env(barrel_mcp, request_state_key, ?KEY),
    Prev.

cleanup(Prev) ->
    case Prev of
        {ok, V} -> application:set_env(barrel_mcp, request_state_key, V);
        undefined -> application:unset_env(barrel_mcp, request_state_key)
    end,
    application:unset_env(barrel_mcp, request_state_ttl_ms),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

principal() -> #{<<"sub">> => <<"user-1">>}.

params() ->
    #{
        <<"name">> => <<"deploy">>,
        <<"arguments">> => #{<<"env">> => <<"prod">>, <<"replicas">> => 3}
    }.

bind() -> bind(principal(), <<"tools/call">>, params()).

bind(Principal, Method, Params) ->
    barrel_mcp_request_state:binding(Principal, Method, Params).

seal(Term) -> barrel_mcp_request_state:seal(Term, bind()).

%%====================================================================
%% Round trip
%%====================================================================

round_trip() ->
    Blob = seal(#{step => confirm, env => <<"prod">>}),
    ?assert(is_binary(Blob)),
    ?assertEqual(
        {ok, #{step => confirm, env => <<"prod">>}},
        barrel_mcp_request_state:unseal(Blob, bind())
    ).

%% The state is any Erlang term the handler chose; nothing constrains
%% its shape.
arbitrary_terms() ->
    Terms = [
        undefined,
        42,
        <<"a binary">>,
        {tuple, [with, <<"mixed">>, 1.5]},
        #{nested => #{deeply => [1, 2, 3]}},
        []
    ],
    lists:foreach(
        fun(T) ->
            ?assertEqual({ok, T}, barrel_mcp_request_state:unseal(seal(T), bind()))
        end,
        Terms
    ).

%%====================================================================
%% Integrity
%%====================================================================

%% Flip one byte anywhere in the blob and it must not verify. Walking
%% the whole blob covers the MAC, the version and the payload.
tampered() ->
    Blob = seal(#{step => confirm}),
    lists:foreach(
        fun(I) ->
            ?assertEqual(
                {error, invalid},
                barrel_mcp_request_state:unseal(flip(Blob, I), bind())
            )
        end,
        lists:seq(0, byte_size(Blob) - 1)
    ).

flip(Blob, I) ->
    <<Head:I/binary, C, Tail/binary>> = Blob,
    %% Stay inside the base64 alphabet so this exercises verification
    %% rather than the decoder.
    New =
        case C of
            $A -> $B;
            _ -> $A
        end,
    <<Head/binary, New, Tail/binary>>.

truncated() ->
    Blob = seal(#{step => confirm}),
    Half = binary:part(Blob, 0, byte_size(Blob) div 2),
    ?assertEqual({error, invalid}, barrel_mcp_request_state:unseal(Half, bind())),
    ?assertEqual({error, invalid}, barrel_mcp_request_state:unseal(<<>>, bind())).

garbage() ->
    Cases = [
        <<"not base64 at all!!!">>,
        <<"////">>,
        <<0, 1, 2, 3>>,
        <<"short">>
    ],
    lists:foreach(
        fun(B) ->
            ?assertEqual({error, invalid}, barrel_mcp_request_state:unseal(B, bind()))
        end,
        Cases
    ).

%% A megabyte of base64 is not something we produced; it must be
%% refused before anything tries to decode it.
oversized() ->
    Big = binary:copy(<<"A">>, 1024 * 1024),
    ?assertEqual({error, invalid}, barrel_mcp_request_state:unseal(Big, bind())).

%%====================================================================
%% Replay bounds
%%====================================================================

expired() ->
    application:set_env(barrel_mcp, request_state_ttl_ms, 0),
    Blob = seal(#{step => confirm}),
    application:unset_env(barrel_mcp, request_state_ttl_ms),
    timer:sleep(5),
    ?assertEqual({error, expired}, barrel_mcp_request_state:unseal(Blob, bind())).

other_principal() ->
    Blob = seal(#{step => confirm}),
    Other = bind(#{<<"sub">> => <<"user-2">>}, <<"tools/call">>, params()),
    ?assertEqual(
        {error, principal_mismatch},
        barrel_mcp_request_state:unseal(Blob, Other)
    ).

other_method() ->
    Blob = seal(#{step => confirm}),
    Other = bind(principal(), <<"prompts/get">>, params()),
    ?assertEqual(
        {error, request_mismatch},
        barrel_mcp_request_state:unseal(Blob, Other)
    ).

%% The point of binding the parameters: state issued for a prod deploy
%% must not authorise a different one.
changed_params() ->
    Blob = seal(#{step => confirm}),
    Tampered = #{
        <<"name">> => <<"deploy">>,
        <<"arguments">> => #{<<"env">> => <<"staging">>, <<"replicas">> => 3}
    },
    ?assertEqual(
        {error, request_mismatch},
        barrel_mcp_request_state:unseal(Blob, bind(principal(), <<"tools/call">>, Tampered))
    ).

rotated_key() ->
    Blob = seal(#{step => confirm}),
    application:set_env(barrel_mcp, request_state_key, <<"a different key, also 32 bytes.!">>),
    try
        ?assertEqual({error, invalid}, barrel_mcp_request_state:unseal(Blob, bind()))
    after
        application:set_env(barrel_mcp, request_state_key, ?KEY)
    end.

%%====================================================================
%% What a legitimate retry looks like
%%====================================================================

%% The retry adds inputResponses and echoes requestState, and carries
%% its own _meta. None of that may change the digest, or no retry could
%% ever verify.
retry_fields_ignored() ->
    Blob = seal(#{step => confirm}),
    Retry = maps:merge(params(), #{
        <<"inputResponses">> => #{
            <<"confirm">> => #{<<"action">> => <<"accept">>}
        },
        <<"requestState">> => Blob,
        <<"_meta">> => #{<<"progressToken">> => <<"a-different-token">>}
    }),
    ?assertEqual(
        {ok, #{step => confirm}},
        barrel_mcp_request_state:unseal(Blob, bind(principal(), <<"tools/call">>, Retry))
    ).

%% Maps have no serialisation order, so the same arguments built in a
%% different order must digest the same.
key_order() ->
    A = #{
        <<"name">> => <<"deploy">>,
        <<"arguments">> => #{<<"env">> => <<"prod">>, <<"replicas">> => 3}
    },
    B = #{
        <<"arguments">> => #{<<"replicas">> => 3, <<"env">> => <<"prod">>},
        <<"name">> => <<"deploy">>
    },
    Blob = barrel_mcp_request_state:seal(
        #{step => confirm},
        bind(principal(), <<"tools/call">>, A)
    ),
    ?assertEqual(
        {ok, #{step => confirm}},
        barrel_mcp_request_state:unseal(Blob, bind(principal(), <<"tools/call">>, B))
    ).

%% With no auth provider the principal is `undefined'. That still has
%% to bind, or an authenticated caller's state would verify for an
%% anonymous one.
undefined_principal() ->
    Blob = barrel_mcp_request_state:seal(
        #{step => confirm},
        bind(undefined, <<"tools/call">>, params())
    ),
    ?assertEqual(
        {ok, #{step => confirm}},
        barrel_mcp_request_state:unseal(Blob, bind(undefined, <<"tools/call">>, params()))
    ),
    ?assertEqual(
        {error, principal_mismatch},
        barrel_mcp_request_state:unseal(Blob, bind())
    ).
