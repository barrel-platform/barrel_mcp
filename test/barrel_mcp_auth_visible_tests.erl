%%%-------------------------------------------------------------------
%%% @doc The auth provider's `visible/4': one endpoint, each caller
%%% listing only the entries its provider lets it see. Driven through
%%% `barrel_mcp_http_engine:handle/6' the way an embedder serves it.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_auth_visible_tests).

-include_lib("eunit/include/eunit.hrl").
-include("barrel_mcp.hrl").

-export([echo/1, read/1, prompt/1]).

-define(MODERN, <<"2026-07-28">>).
-define(PROVIDER, barrel_mcp_visible_provider).

auth_visible_test_() ->
    {setup, fun setup/0, fun cleanup/1,
        {timeout, 60, [
            {"a provider without visible/4 lists everything", fun no_callback/0},
            {"hidden entries are absent from every listing", fun hidden_everywhere/0},
            {"two callers on one endpoint list different sets", fun two_callers/0},
            {"filtered pages keep their cursors", fun pages_stay_valid/0},
            {"a hidden tool is still called", fun hidden_still_callable/0},
            {"a raising visible/4 hides only that entry", fun raising_callback/0},
            {"the custom provider forwards visible/4", fun custom_forwards/0},
            {"the custom provider without visible/4 lists everything", fun custom_without/0},
            {"the simple transport filters", fun simple_transport/0},
            {"a legacy session filters", fun legacy_session/0},
            {"a legacy batch filters", fun legacy_batch/0},
            {"a modern request filters", fun modern_request/0}
        ]}}.

setup() ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    ok = barrel_mcp_registry:wait_for_ready(),
    ok = barrel_mcp_http_engine:ensure_session_manager(),
    lists:foreach(
        fun(Name) ->
            ok = barrel_mcp:reg_tool(Name, ?MODULE, echo, #{description => <<"test">>})
        end,
        tool_names() ++ [<<"av_boom">>]
    ),
    lists:foreach(
        fun(<<"av_", N/binary>> = Name) ->
            ok = barrel_mcp:reg_resource(Name, ?MODULE, read, #{
                name => Name, uri => <<"av://r/", N/binary>>
            }),
            ok = barrel_mcp:reg_resource_template(Name, ?MODULE, read, #{
                name => Name, uri_template => <<"av://t/", N/binary, "/{x}">>
            }),
            ok = barrel_mcp:reg_prompt(Name, ?MODULE, prompt, #{description => <<"test">>})
        end,
        small_names()
    ),
    ok.

cleanup(_) ->
    lists:foreach(
        fun(N) -> barrel_mcp_registry:unreg(tool, N) end,
        tool_names() ++ [<<"av_boom">>]
    ),
    lists:foreach(
        fun(N) ->
            barrel_mcp_registry:unreg(resource, N),
            barrel_mcp_registry:unreg(resource_template, N),
            barrel_mcp_registry:unreg(prompt, N)
        end,
        small_names()
    ),
    ok.

echo(_Args) -> <<"ran">>.
read(_Args) -> <<"data">>.
prompt(_Args) -> #{<<"messages">> => []}.

tool_names() -> names(120).
small_names() -> names(4).

names(Count) ->
    [iolist_to_binary(io_lib:format("av_~3..0b", [I])) || I <- lists:seq(0, Count - 1)].

side(Parity, Names) ->
    [N || <<"av_", I/binary>> = N <- Names, binary_to_integer(I) rem 2 =:= Parity].

%%====================================================================
%% Cases
%%====================================================================

no_callback() ->
    Config = config(#{}),
    ?assertEqual(tool_names() ++ [<<"av_boom">>], list_tools(Config, <<"a">>)),
    [
        ?assertEqual(small_names(), list(Config, <<"a">>, Method))
     || Method <- small_methods()
    ].

hidden_everywhere() ->
    Config = provider_config(),
    ?assertEqual(side(0, tool_names()), list_tools(Config, <<"a">>)),
    [
        ?assertEqual(side(0, small_names()), list(Config, <<"a">>, Method))
     || Method <- small_methods()
    ].

two_callers() ->
    Config = provider_config(),
    A = list_tools(Config, <<"a">>),
    B = list_tools(Config, <<"b">>),
    ?assertEqual(side(0, tool_names()), A),
    ?assertEqual(side(1, tool_names()), B),
    ?assertEqual(tool_names(), lists:sort(A ++ B)).

pages_stay_valid() ->
    Pages = list_pages(provider_config(), <<"b">>, <<"tools/list">>, undefined, []),
    ?assert(length(Pages) >= 2),
    Listed = lists:append(Pages),
    ?assertEqual(60, length(Listed)),
    ?assertEqual(length(Listed), length(lists:usort(Listed))),
    ?assertEqual(side(1, tool_names()), lists:sort(Listed)).

hidden_still_callable() ->
    Config = provider_config(),
    ?assertNot(lists:member(<<"av_001">>, list_tools(Config, <<"a">>))),
    ?assertEqual(<<"ran">>, call_text(Config, <<"a">>, <<"av_001">>)).

raising_callback() ->
    Config = provider_config(),
    ?assertEqual(tool_names(), list_tools(Config, <<"all">>)).

custom_forwards() ->
    Config = custom_config(barrel_mcp_visible_custom),
    ?assertEqual(side(1, tool_names()), list_tools(Config, <<"b">>)),
    ?assertEqual(side(1, small_names()), list(Config, <<"b">>, <<"prompts/list">>)).

custom_without() ->
    Config = custom_config(test_auth_module),
    ?assertEqual(tool_names() ++ [<<"av_boom">>], list_tools(Config, <<"valid-token">>)).

simple_transport() ->
    Config = (provider_config())#{mode => simple},
    ?assertEqual(side(0, tool_names()), list_tools(Config, <<"a">>)),
    ?assertEqual(<<"ran">>, call_text(Config, <<"a">>, <<"av_001">>)).

legacy_session() ->
    Config = (provider_config())#{session_enabled => true},
    Extra = session(Config, ?MCP_LATEST_LEGACY_VERSION),
    Page = result(post(Config, request(2, <<"tools/list">>, #{}), Extra)),
    assert_first_page(Page).

%% 2025-03-26 is the revision that answers batches.
legacy_batch() ->
    Config = (provider_config())#{session_enabled => true},
    Extra = session(Config, <<"2025-03-26">>),
    Batch = iolist_to_binary(
        json:encode([barrel_mcp_test_helpers:legacy_request(2, <<"tools/list">>, #{})])
    ),
    {200, _, Body} = post(Config, Batch, Extra),
    [#{<<"result">> := Page}] = json:decode(Body),
    assert_first_page(Page).

modern_request() ->
    Config = provider_config(),
    Page = result(post_modern(Config, <<"a">>, <<"tools/list">>, #{})),
    assert_first_page(Page).

%%====================================================================
%% Helpers
%%====================================================================

%% A page for caller `a' holds only even entries.
assert_first_page(Page) ->
    Names = page_names(<<"tools">>, Page),
    ?assertNotEqual([], Names),
    ?assertEqual([], Names -- side(0, tool_names())).

small_methods() ->
    [<<"resources/list">>, <<"resources/templates/list">>, <<"prompts/list">>].

provider_config() ->
    config(#{provider => ?PROVIDER}).

custom_config(Module) ->
    config(#{provider => barrel_mcp_auth_custom, provider_opts => #{module => Module}}).

config(Auth) ->
    {ok, AuthConfig} = barrel_mcp_http_engine:init_auth(Auth),
    #{
        mode => stream,
        auth_config => AuthConfig,
        session_enabled => false,
        allowed_origins => any,
        allow_missing_origin => true,
        sse_buffer_size => 256,
        resource_metadata => undefined
    }.

bearer(Token) ->
    [{<<"authorization">>, <<"Bearer ", Token/binary>>}].

session(Config, Version) ->
    {200, Hdrs, _} = post(Config, barrel_mcp_test_helpers:init_body(Version), bearer(<<"a">>)),
    Sid = header(<<"mcp-session-id">>, Hdrs),
    ?assert(is_binary(Sid)),
    [{<<"mcp-session-id">>, Sid}, {<<"mcp-protocol-version">>, Version} | bearer(<<"a">>)].

list_tools(Config, Token) ->
    list(Config, Token, <<"tools/list">>).

%% Our entries only, sorted, across every page.
list(Config, Token, Method) ->
    lists:sort(lists:append(list_pages(Config, Token, Method, undefined, []))).

list_pages(Config, Token, Method, Cursor, Acc) ->
    Params =
        case Cursor of
            undefined -> #{};
            _ -> #{<<"cursor">> => Cursor}
        end,
    Result = result(post(Config, request(1, Method, Params), bearer(Token))),
    Names = page_names(wire_key(Method), Result),
    case maps:get(<<"nextCursor">>, Result, undefined) of
        undefined -> lists:reverse([Names | Acc]);
        Next -> list_pages(Config, Token, Method, Next, [Names | Acc])
    end.

wire_key(<<"tools/list">>) -> <<"tools">>;
wire_key(<<"resources/list">>) -> <<"resources">>;
wire_key(<<"resources/templates/list">>) -> <<"resourceTemplates">>;
wire_key(<<"prompts/list">>) -> <<"prompts">>.

page_names(Key, Result) ->
    [N || #{<<"name">> := <<"av_", _/binary>> = N} <- maps:get(Key, Result)].

call_text(Config, Token, Name) ->
    Params = #{<<"name">> => Name, <<"arguments">> => #{}},
    #{<<"content">> := [#{<<"text">> := Text}]} =
        result(post(Config, request(2, <<"tools/call">>, Params), bearer(Token))),
    Text.

request(Id, Method, Params) ->
    barrel_mcp_test_helpers:request(Id, Method, Params).

post_modern(Config, Token, Method, Params) ->
    Envelope = barrel_mcp_test_helpers:modern_request(1, Method, Params),
    Hdrs =
        [{<<"mcp-protocol-version">>, ?MODERN} | bearer(Token)] ++
            barrel_mcp_headers:standard(Method, maps:get(<<"params">>, Envelope)),
    post(Config, iolist_to_binary(json:encode(Envelope)), Hdrs).

result({200, _, Body}) ->
    #{<<"result">> := Result} = json:decode(Body),
    Result.

%% Answers either as one JSON body or as an SSE stream; both come back
%% as `{Status, Headers, JsonBody}'.
post(Config, Body, Extra) ->
    Self = self(),
    Ref = make_ref(),
    Responder = #{
        reply => fun(Status, Hdrs, B) ->
            Self ! {Ref, reply, Status, Hdrs, iolist_to_binary(B)},
            ok
        end,
        stream_start => fun(Status, Hdrs) ->
            Self ! {Ref, stream_start, Status, Hdrs},
            ok
        end,
        stream_chunk => fun(Chunk) ->
            Self ! {Ref, chunk, iolist_to_binary(Chunk)},
            ok
        end,
        stream_end => fun() ->
            Self ! {Ref, stream_end},
            ok
        end
    },
    Headers =
        [
            {<<"content-type">>, <<"application/json">>},
            {<<"accept">>, <<"application/json, text/event-stream">>}
        ] ++ Extra,
    ok = barrel_mcp_http_engine:handle(<<"POST">>, <<"/mcp">>, Headers, Body, Responder, Config),
    receive
        {Ref, reply, Status, Hdrs, B} ->
            {Status, Hdrs, B};
        {Ref, stream_start, Status, Hdrs} ->
            {Status, Hdrs, collect(Ref, <<>>)}
    after 5000 ->
        error(no_reply)
    end.

collect(Ref, Acc) ->
    receive
        {Ref, chunk, C} -> collect(Ref, <<Acc/binary, C/binary>>);
        {Ref, stream_end} -> last_data(Acc)
    after 5000 ->
        error(stream_timeout)
    end.

last_data(Sse) ->
    Lines = binary:split(Sse, <<"\n">>, [global]),
    lists:last([D || <<"data: ", D/binary>> <- Lines, D =/= <<>>]).

header(Name, Hdrs) when is_map(Hdrs) -> maps:get(Name, Hdrs, undefined);
header(Name, Hdrs) -> proplists:get_value(Name, Hdrs).
