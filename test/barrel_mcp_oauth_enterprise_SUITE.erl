%%%-------------------------------------------------------------------
%%% @doc End-to-end suite for the Enterprise-Managed Authorization
%%% grant.
%%%
%%% Stands up:
%%%
%%% - a tiny cowboy mock that plays both the IdP token-exchange
%%%   endpoint and the AS jwt-bearer endpoint;
%%% - a real `barrel_mcp_http_stream' MCP server with bearer auth
%%%   guarded by a custom verifier that only accepts the access
%%%   token the mock AS hands out.
%%%
%%% Then connects a `barrel_mcp_client' with
%%% `auth => {oauth_enterprise, Config}', exercises `list_tools'
%%% and `call_tool' against the protected server, and asserts the
%%% chain (RFC 8693 token-exchange -> RFC 7523 jwt-bearer ->
%%% Authorization: Bearer ...) actually unlocks the MCP protocol.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_oauth_enterprise_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([ema_chain_unlocks_protected_server/1,
         expired_subject_token_blocks_init/1]).

%% Cowboy callback for the IdP/AS mock.
-export([init/2]).

%% MCP server tool fixture.
-export([echo_tool/1]).

-define(AS_PORT, 22701).
-define(MCP_PORT, 22702).
-define(AS_LISTENER, ?MODULE).
-define(ACCESS_TOKEN, <<"ema-access-token-issued-by-mock-as">>).

all() ->
    [ema_chain_unlocks_protected_server,
     expired_subject_token_blocks_init].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    %% cowboy is a test-only dependency now (mock authorization
    %% server); barrel_mcp no longer starts it.
    {ok, _} = application:ensure_all_started(cowboy),
    ok = barrel_mcp_registry:wait_for_ready(),

    %% Cowboy mock implementing both IdP and AS token endpoints.
    Dispatch = cowboy_router:compile([{'_', [
        {"/idp/token", ?MODULE, idp_token},
        {"/as/token",  ?MODULE, as_token}
    ]}]),
    {ok, _} = cowboy:start_clear(?AS_LISTENER, [{port, ?AS_PORT}],
                                  #{env => #{dispatch => Dispatch}}),

    %% Register a tool the test will call against the MCP server.
    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo">>,
        input_schema => #{<<"type">> => <<"object">>,
                           <<"required">> => [<<"text">>]}
    }),

    %% MCP server with bearer auth gated by a custom verifier
    %% that only accepts the access token our mock AS issues.
    Verifier = fun(Token) ->
        case Token =:= ?ACCESS_TOKEN of
            true  -> {ok, #{<<"sub">> => <<"interop-user">>}};
            false -> {error, invalid_token}
        end
    end,
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => ?MCP_PORT,
        session_enabled => true,
        auth => #{provider => barrel_mcp_auth_bearer,
                   provider_opts => #{verifier => Verifier}}
    }),
    Config.

end_per_suite(_Config) ->
    try barrel_mcp:stop_http_stream() catch _:_ -> ok end,
    try cowboy:stop_listener(?AS_LISTENER) catch _:_ -> ok end,
    try barrel_mcp_registry:unreg(tool, <<"echo">>) catch _:_ -> ok end,
    application:stop(barrel_mcp),
    ok.

%%====================================================================
%% Cases
%%====================================================================

ema_chain_unlocks_protected_server(_Config) ->
    %% Build the connect spec. `subject_token' is the IdP-issued ID
    %% Token the host obtained out of band; here we hand it to the
    %% library as opaque bytes.
    AsBase = list_to_binary(io_lib:format("http://127.0.0.1:~B",
                                           [?AS_PORT])),
    McpUrl = list_to_binary(io_lib:format("http://127.0.0.1:~B/mcp",
                                           [?MCP_PORT])),
    Spec = #{
        transport => {http, McpUrl},
        auth => {oauth_enterprise, #{
            idp_token_endpoint => <<AsBase/binary, "/idp/token">>,
            as_token_endpoint  => <<AsBase/binary, "/as/token">>,
            client_id          => <<"client-1">>,
            client_secret      => <<"top-secret">>,
            subject_token      => <<"oidc-id-token">>,
            subject_token_type =>
                <<"urn:ietf:params:oauth:token-type:id_token">>,
            audience           => AsBase,
            resource           => McpUrl
        }}
    },
    {ok, Pid} = barrel_mcp_client:start(Spec),
    ok = wait_ready(Pid, 50),

    {ok, Tools} = barrel_mcp_client:list_tools(Pid),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"echo">>, Names)),

    {ok, R} = barrel_mcp_client:call_tool(Pid, <<"echo">>,
                                          #{<<"text">> => <<"hi">>}),
    [#{<<"text">> := <<"hi">>} | _] = maps:get(<<"content">>, R),

    barrel_mcp_client:close(Pid),
    ok.

expired_subject_token_blocks_init(_Config) ->
    %% A subject_token the mock IdP refuses (returns invalid_grant)
    %% must surface as `subject_token_expired' from `init/1' so the
    %% host knows to re-acquire from the IdP.
    AsBase = list_to_binary(io_lib:format("http://127.0.0.1:~B",
                                           [?AS_PORT])),
    McpUrl = list_to_binary(io_lib:format("http://127.0.0.1:~B/mcp",
                                           [?MCP_PORT])),
    Spec = #{
        transport => {http, McpUrl},
        auth => {oauth_enterprise, #{
            idp_token_endpoint => <<AsBase/binary, "/idp/token">>,
            as_token_endpoint  => <<AsBase/binary, "/as/token">>,
            client_id          => <<"client-1">>,
            client_secret      => <<"top-secret">>,
            subject_token      => <<"expired-id-token">>,
            subject_token_type =>
                <<"urn:ietf:params:oauth:token-type:id_token">>,
            audience           => AsBase,
            resource           => McpUrl
        }}
    },
    %% `start/1' returns asynchronously — the gen_statem accepts
    %% the spec, then fails during the connecting state when the
    %% auth handle init walks the EMA chain. Monitor the pid and
    %% wait for the EXIT.
    {ok, Pid} = barrel_mcp_client:start(Spec),
    Ref = erlang:monitor(process, Pid),
    receive
        {'DOWN', Ref, process, Pid, Reason} ->
            ?assertEqual(subject_token_expired,
                         normalise_reason(Reason))
    after 5000 ->
        ct:fail("client did not stop on subject_token_expired")
    end,
    ok.

%%====================================================================
%% Tool fixture
%%====================================================================

echo_tool(#{<<"text">> := T}) -> T.

%%====================================================================
%% Cowboy IdP + AS mock
%%====================================================================

init(Req0, idp_token) ->
    {ok, Body, Req} = cowboy_req:read_urlencoded_body(Req0),
    Form = maps:from_list(Body),
    case maps:get(<<"subject_token">>, Form, undefined) of
        <<"expired-id-token">> ->
            R = cowboy_req:reply(400,
                #{<<"content-type">> => <<"application/json">>},
                json_encode(#{<<"error">> => <<"invalid_grant">>}), Req),
            {ok, R, idp_token};
        _ ->
            R = cowboy_req:reply(200,
                #{<<"content-type">> => <<"application/json">>},
                json_encode(#{<<"access_token">> => <<"id-jag.signed.jwt">>,
                              <<"issued_token_type">> =>
                                  <<"urn:ietf:params:oauth:token-type:id-jag">>,
                              <<"token_type">> => <<"Bearer">>}), Req),
            {ok, R, idp_token}
    end;
init(Req0, as_token) ->
    {ok, Body, Req} = cowboy_req:read_urlencoded_body(Req0),
    Form = maps:from_list(Body),
    <<"urn:ietf:params:oauth:grant-type:jwt-bearer">> =
        maps:get(<<"grant_type">>, Form),
    <<"id-jag.signed.jwt">> = maps:get(<<"assertion">>, Form),
    R = cowboy_req:reply(200,
        #{<<"content-type">> => <<"application/json">>},
        json_encode(#{<<"access_token">> => ?ACCESS_TOKEN,
                      <<"token_type">> => <<"Bearer">>,
                      <<"expires_in">> => 3600}), Req),
    {ok, R, as_token}.

json_encode(M) -> iolist_to_binary(json:encode(M)).

%%====================================================================
%% Helpers
%%====================================================================

wait_ready(_Pid, 0) -> {error, not_ready};
wait_ready(Pid, N) ->
    case (try barrel_mcp_client:server_capabilities(Pid) catch _:_ -> error end) of
        {ok, _} -> ok;
        _ ->
            timer:sleep(100),
            wait_ready(Pid, N - 1)
    end.

%% `barrel_mcp_client:start/1' wraps init failures; pull out the
%% inner reason for assertion clarity.
normalise_reason({shutdown, R}) -> normalise_reason(R);
normalise_reason({error, R}) -> normalise_reason(R);
normalise_reason({transport_failed, R}) -> normalise_reason(R);
normalise_reason(R) -> R.
