%%%-------------------------------------------------------------------
%%% @doc End-to-end suite for Dynamic Client Registration.
%%%
%%% Stands up:
%%%
%%% - a tiny mock (on the project's own `h1' server) that plays both
%%%   an RFC 7591 registration endpoint and an OAuth 2.0 token
%%%   endpoint;
%%% - a real `barrel_mcp_http_stream' MCP server with bearer auth
%%%   guarded by a custom verifier that only accepts the token
%%%   the mock AS issues to a freshly registered client.
%%%
%%% Then drives the full flow:
%%%
%%%   1. `register_client/2' to obtain a `client_id' /
%%%      `client_secret';
%%%   2. `barrel_mcp_client:start/1' with
%%%      `auth => {oauth_client_credentials, ...}' using the
%%%      registered credentials;
%%%   3. `list_tools' / `call_tool' against the protected MCP
%%%      server.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_oauth_dcr_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-import(barrel_mcp_test_helpers, [wait_ready/2]).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    dcr_then_client_credentials_unlocks_server/1,
    registration_error_surfaces/1,
    registration_names_an_application_type/1
]).

-export([echo_tool/1]).

-define(AS_PORT, 22751).
-define(MCP_PORT, 22752).
-define(AS_LISTENER, ?MODULE).
-define(ACCESS_TOKEN, <<"dcr-cc-access-token">>).

all() ->
    [
        dcr_then_client_credentials_unlocks_server,
        registration_error_surfaces,
        registration_names_an_application_type
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(barrel_mcp),
    {ok, _} = application:ensure_all_started(hackney),
    ok = barrel_mcp_registry:wait_for_ready(),

    {ok, _} = barrel_mcp_test_http:start(
        ?AS_LISTENER,
        ?AS_PORT,
        fun handle/1
    ),

    ok = barrel_mcp_registry:reg(tool, <<"echo">>, ?MODULE, echo_tool, #{
        description => <<"Echo">>,
        input_schema => #{
            <<"type">> => <<"object">>,
            <<"required">> => [<<"text">>]
        }
    }),

    Verifier = fun(Token) ->
        case Token =:= ?ACCESS_TOKEN of
            true -> {ok, #{<<"sub">> => <<"dcr-client">>}};
            false -> {error, invalid_token}
        end
    end,
    {ok, _} = barrel_mcp:start_http_stream(#{
        port => ?MCP_PORT,
        session_enabled => true,
        auth => #{
            provider => barrel_mcp_auth_bearer,
            provider_opts => #{verifier => Verifier}
        }
    }),
    Config.

end_per_suite(_Config) ->
    try
        barrel_mcp:stop_http_stream()
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_test_http:stop(?AS_LISTENER)
    catch
        _:_ -> ok
    end,
    try
        barrel_mcp_registry:unreg(tool, <<"echo">>)
    catch
        _:_ -> ok
    end,
    application:stop(barrel_mcp),
    ok.

%%====================================================================
%% Cases
%%====================================================================

dcr_then_client_credentials_unlocks_server(_Config) ->
    AsBase = list_to_binary(
        io_lib:format(
            "http://127.0.0.1:~B",
            [?AS_PORT]
        )
    ),
    McpUrl = list_to_binary(
        io_lib:format(
            "http://127.0.0.1:~B/mcp",
            [?MCP_PORT]
        )
    ),

    %% Step 1: register a client.
    {ok, Info} = barrel_mcp_client_auth_oauth:register_client(
        <<AsBase/binary, "/oauth/register">>,
        #{
            <<"client_name">> => <<"e2e-host">>,
            <<"grant_types">> => [<<"client_credentials">>],
            <<"token_endpoint_auth_method">> => <<"client_secret_basic">>
        },
        #{allow_insecure_oauth => true}
    ),
    ClientId = maps:get(<<"client_id">>, Info),
    ClientSecret = maps:get(<<"client_secret">>, Info),
    ?assert(is_binary(ClientId)),
    ?assert(is_binary(ClientSecret)),

    %% Step 2: connect to the protected MCP server using the
    %% registered credentials via the client_credentials grant.
    Spec = #{
        transport => {http, McpUrl},
        auth =>
            {oauth_client_credentials, #{
                allow_insecure_oauth => true,
                token_endpoint => <<AsBase/binary, "/oauth/token">>,
                client_id => ClientId,
                client_secret => ClientSecret,
                resource => McpUrl
            }}
    },
    {ok, Pid} = barrel_mcp_client:start(Spec),
    ok = wait_ready(Pid, 50),

    %% Step 3: exercise MCP through the bearer-protected channel.
    {ok, Tools} = barrel_mcp_client:list_tools(Pid),
    Names = [maps:get(<<"name">>, T) || T <- Tools],
    ?assert(lists:member(<<"echo">>, Names)),

    {ok, R} = barrel_mcp_client:call_tool(
        Pid,
        <<"echo">>,
        #{<<"text">> => <<"hi">>}
    ),
    [#{<<"text">> := <<"hi">>} | _] = maps:get(<<"content">>, R),

    barrel_mcp_client:close(Pid),
    ok.

registration_error_surfaces(_Config) ->
    %% A 4xx from the registration endpoint must propagate the
    %% status + body so the host can react.
    AsBase = list_to_binary(
        io_lib:format(
            "http://127.0.0.1:~B",
            [?AS_PORT]
        )
    ),
    Result = barrel_mcp_client_auth_oauth:register_client(
        <<AsBase/binary, "/oauth/register">>,
        #{<<"client_name">> => <<"reject-me">>},
        #{allow_insecure_oauth => true}
    ),
    ?assertMatch({error, {http_error, 400, _}}, Result),
    ok.

%%====================================================================
%% Tool fixture
%%====================================================================

echo_tool(#{<<"text">> := T}) -> T.

%% An OIDC server doing dynamic registration applies redirect-URI
%% rules by application_type, and omitting it defaults to web, which
%% rejects the loopback URIs a local client needs. So it is always
%% sent, inferred from the redirect URIs when the caller says nothing.
registration_names_an_application_type(_Config) ->
    AsBase = list_to_binary(io_lib:format("http://127.0.0.1:~B", [?AS_PORT])),
    Endpoint = <<AsBase/binary, "/oauth/register">>,

    {ok, _} = barrel_mcp_client_auth_oauth:register_client(
        Endpoint,
        #{
            <<"client_name">> => <<"local-cli">>,
            <<"redirect_uris">> => [<<"http://127.0.0.1:3000/callback">>]
        },
        #{allow_insecure_oauth => true}
    ),
    ?assertEqual(
        <<"native">>,
        maps:get(<<"application_type">>, persistent_term:get(dcr_last_registration))
    ),

    {ok, _} = barrel_mcp_client_auth_oauth:register_client(
        Endpoint,
        #{
            <<"client_name">> => <<"hosted">>,
            <<"redirect_uris">> => [<<"https://app.example/callback">>]
        },
        #{allow_insecure_oauth => true}
    ),
    ?assertEqual(
        <<"web">>,
        maps:get(<<"application_type">>, persistent_term:get(dcr_last_registration))
    ),

    %% An https loopback URI is still a local client.
    {ok, _} = barrel_mcp_client_auth_oauth:register_client(
        Endpoint,
        #{
            <<"client_name">> => <<"tls-loopback">>,
            <<"redirect_uris">> => [<<"https://localhost:3000/callback">>]
        },
        #{allow_insecure_oauth => true}
    ),
    ?assertEqual(
        <<"native">>,
        maps:get(<<"application_type">>, persistent_term:get(dcr_last_registration))
    ),

    %% A caller that knows better is never overridden.
    {ok, _} = barrel_mcp_client_auth_oauth:register_client(
        Endpoint,
        #{
            <<"client_name">> => <<"explicit">>,
            <<"redirect_uris">> => [<<"http://127.0.0.1:3000/callback">>],
            <<"application_type">> => <<"web">>
        },
        #{allow_insecure_oauth => true}
    ),
    ?assertEqual(
        <<"web">>,
        maps:get(<<"application_type">>, persistent_term:get(dcr_last_registration))
    ),
    ok.

%%====================================================================
%% Mock: registration + token endpoints
%%====================================================================

handle(#{path := <<"/oauth/register">>, body := Body}) ->
    Metadata = json:decode(Body),
    %% Echoed back so a test can see what the client actually sent.
    _ = persistent_term:put(dcr_last_registration, Metadata),
    case maps:get(<<"client_name">>, Metadata, <<>>) of
        <<"reject-me">> ->
            {400, json_ct(), json_encode(#{<<"error">> => <<"invalid_redirect_uri">>})};
        _ ->
            {201, json_ct(),
                json_encode(#{
                    <<"client_id">> => <<"registered-client-id">>,
                    <<"client_secret">> => <<"registered-secret">>,
                    <<"client_id_issued_at">> => 1700000000,
                    <<"client_secret_expires_at">> => 0
                })}
    end;
handle(#{path := <<"/oauth/token">>} = Req) ->
    Form = barrel_mcp_test_http:form(Req),
    <<"client_credentials">> = maps:get(<<"grant_type">>, Form),
    %% The client authenticates via HTTP Basic with the
    %% registered credentials; barrel_mcp_client_auth_oauth strips
    %% client_id from the body in that mode.
    AuthHdr = barrel_mcp_test_http:header(<<"authorization">>, Req),
    true = is_binary(AuthHdr),
    <<"Basic ", _/binary>> = AuthHdr,
    {200, json_ct(),
        json_encode(#{
            <<"access_token">> => ?ACCESS_TOKEN,
            <<"token_type">> => <<"Bearer">>,
            <<"expires_in">> => 3600
        })}.

json_ct() -> #{<<"content-type">> => <<"application/json">>}.

json_encode(M) -> iolist_to_binary(json:encode(M)).

%%====================================================================
%% Helpers
%%====================================================================
