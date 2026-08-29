%%%-------------------------------------------------------------------
%%% @doc The client the official conformance runner drives.
%%%
%%% The runner starts this node once per scenario with the server URL
%%% as the only plain argument and the scenario name, a JSON context
%%% and the protocol version in the environment. Nothing here knows a
%%% scenario by name beyond picking the auth configuration: the client
%%% connects, exercises everything the server lists, and exits. The
%%% runner judges the wire.
%%%
%%% Exit 0 when the client got through; 1, with the reason on stderr,
%%% when it refused or failed, which is what scenarios that expect a
%%% refusal want to see.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_conformance_client).

-behaviour(barrel_mcp_client_handler).

-export([main/0]).
-export([init/1, handle_request/3, handle_notification/3]).

-define(TIMEOUT, 20000).

main() ->
    try run() of
        ok -> halt(0)
    catch
        Class:Reason:Stack ->
            io:format(standard_error, "conformance client failed: ~p:~p~n~p~n", [
                Class, Reason, Stack
            ]),
            halt(1)
    end.

run() ->
    [Url0 | _] = init:get_plain_arguments(),
    Url = list_to_binary(Url0),
    Scenario = env("MCP_CONFORMANCE_SCENARIO", ""),
    Context = json:decode(unicode:characters_to_binary(env("MCP_CONFORMANCE_CONTEXT", "{}"))),
    Version =
        case env("MCP_CONFORMANCE_PROTOCOL_VERSION", undefined) of
            undefined -> auto;
            V -> list_to_binary(V)
        end,
    {ok, _} = application:ensure_all_started(barrel_mcp),
    Spec = #{
        transport => {http, Url},
        protocol_version => Version,
        client_info => #{name => <<"barrel_mcp-conformance">>, version => <<"3.0.1">>},
        capabilities => #{
            roots => #{listChanged => true},
            sampling => #{},
            elicitation => #{}
        },
        handler => {?MODULE, []},
        auth => auth(Scenario, Context, Url),
        init_timeout => ?TIMEOUT
    },
    case barrel_mcp_client:start(Spec) of
        {ok, Pid} ->
            try
                ok = barrel_mcp_test_helpers:wait_ready(Pid, 1200),
                exercise(Pid, Scenario)
            after
                barrel_mcp_client:close(Pid)
            end;
        {error, Reason} ->
            error({start_failed, Reason})
    end.

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        Value -> Value
    end.

%%====================================================================
%% Authorization
%%====================================================================

%% The auth scenarios' servers are plaintext localhost, hence the
%% noncompliant flag; the redirect step fetches the authorization URL
%% without following the redirect and hands back its Location.
auth(Scenario, Context, Url) ->
    case string:find(Scenario, "auth") of
        nomatch -> none;
        _ -> grant(Scenario, Context, Url)
    end.

%% The scenario context says which grant it exercises: an IdP token
%% endpoint means enterprise-managed authorization, a signed workload
%% JWT means jwt-bearer, a private key means client credentials with
%% private_key_jwt, a bare secret without a redirect flow means client
%% credentials with a secret, and the rest is the authorization-code
%% flow. Endpoints are never in the context: every grant discovers
%% them from the 401.
grant(Scenario, #{<<"idp_token_endpoint">> := Idp, <<"idp_id_token">> := IdToken} = Context, _Url) ->
    _ = Scenario,
    {oauth_enterprise, #{
        client_id => maps:get(<<"client_id">>, Context),
        client_secret => maps:get(<<"client_secret">>, Context, undefined),
        idp_token_endpoint => Idp,
        subject_token => IdToken,
        subject_token_type => <<"urn:ietf:params:oauth:token-type:id_token">>,
        allow_insecure_oauth => true
    }};
grant(_Scenario, #{<<"valid_jwt">> := Assertion} = Context, _Url) ->
    {oauth_jwt_bearer, #{
        client_id => maps:get(<<"client_id">>, Context),
        assertion => Assertion,
        allow_insecure_oauth => true
    }};
grant(_Scenario, #{<<"private_key_pem">> := Pem} = Context, _Url) ->
    {oauth_client_credentials, #{
        client_id => maps:get(<<"client_id">>, Context),
        private_key => {Pem, maps:get(<<"signing_algorithm">>, Context, <<"ES256">>)},
        allow_insecure_oauth => true
    }};
grant(Scenario, #{<<"client_secret">> := Secret} = Context, _Url) when
    Scenario =:= "auth/client-credentials-basic"
->
    {oauth_client_credentials, #{
        client_id => maps:get(<<"client_id">>, Context),
        client_secret => Secret,
        allow_insecure_oauth => true
    }};
grant(Scenario, Context, Url) ->
    oauth(Scenario, Context, Url).

oauth(Scenario, Context, _Url) ->
    Base = #{
        redirect_uri => <<"http://127.0.0.1:9797/callback">>,
        authorize => fun headless_authorize/1,
        client_metadata => #{
            <<"client_name">> => <<"barrel_mcp conformance client">>,
            <<"grant_types">> => [<<"authorization_code">>, <<"refresh_token">>],
            <<"response_types">> => [<<"code">>],
            <<"token_endpoint_auth_method">> => <<"none">>
        },
        allow_insecure_oauth => true
    },
    WithClient =
        case Context of
            #{<<"client_id">> := Id} ->
                Base#{
                    client_id => Id,
                    client_secret => maps:get(<<"client_secret">>, Context, undefined),
                    token_endpoint_auth_method => client_secret_basic
                };
            _ ->
                Base
        end,
    WithCimd =
        case Context of
            #{<<"client_metadata_url">> := Cimd} -> WithClient#{client_id_metadata_url => Cimd};
            _ -> WithClient
        end,
    WithDpop =
        case string:find(Scenario, "dpop") of
            nomatch -> WithCimd;
            _ -> WithCimd#{dpop => true}
        end,
    {oauth, maps:filter(fun(_, V) -> V =/= undefined end, WithDpop)}.

headless_authorize(Url) ->
    case hackney:request(get, Url, [], <<>>, [with_body, {follow_redirect, false}]) of
        {ok, Status, Headers, _Body} when Status >= 300, Status < 400 ->
            case [V || {K, V} <- Headers, string:lowercase(K) =:= <<"location">>] of
                [Location | _] -> {ok, Location};
                [] -> {error, {no_location, Status}}
            end;
        {ok, Status, _Headers, _Body} ->
            {error, {authorization_endpoint, Status}};
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% What the client does once connected
%%====================================================================

exercise(Pid, Scenario) ->
    Tools =
        case barrel_mcp_client:list_tools(Pid) of
            {ok, T} -> T;
            {error, _} -> []
        end,
    _ = [call_tool(Pid, Tool, Tools) || Tool <- Tools],
    _ =
        case barrel_mcp_client:list_resources(Pid) of
            {ok, Resources} ->
                [
                    barrel_mcp_client:read_resource(Pid, maps:get(<<"uri">>, R))
                 || R <- Resources, is_binary(maps:get(<<"uri">>, R, undefined))
                ];
            _ ->
                []
        end,
    _ =
        case barrel_mcp_client:list_prompts(Pid) of
            {ok, Prompts} ->
                [
                    barrel_mcp_client:get_prompt(Pid, maps:get(<<"name">>, P), prompt_args(P))
                 || P <- Prompts
                ];
            _ ->
                []
        end,
    scenario_extras(Pid, Scenario),
    ok.

%% Anything a scenario needs beyond the sweep above.
scenario_extras(_Pid, "sse-retry") ->
    %% The client holds the standalone stream from the start; the
    %% scenario closes it and watches for the reconnect after the
    %% `retry:' delay it named. Give that time to happen.
    timer:sleep(3000);
scenario_extras(_Pid, _Scenario) ->
    ok.

%% `json_schema_echo' wants the focal tool's schema back verbatim
%% (SEP-2106): the point is what the client kept of it.
call_tool(Pid, #{<<"name">> := <<"json_schema_echo">> = Name}, Tools) ->
    Focal = [T || #{<<"name">> := <<"json_schema_2020_12_tool">>} = T <- Tools],
    Args =
        case Focal of
            [#{<<"inputSchema">> := Schema} | _] -> #{<<"schema">> => Schema};
            _ -> #{}
        end,
    _ = barrel_mcp_client:call_tool(Pid, Name, Args, #{timeout => ?TIMEOUT}),
    ok;
call_tool(Pid, #{<<"name">> := Name} = Tool, _Tools) ->
    Args = arguments(maps:get(<<"inputSchema">>, Tool, #{})),
    case barrel_mcp_client:call_tool(Pid, Name, Args, #{timeout => ?TIMEOUT}) of
        {ok, _} -> ok;
        {error, _} -> ok
    end.

prompt_args(#{<<"arguments">> := Args}) when is_list(Args) ->
    maps:from_list([{maps:get(<<"name">>, A), <<"x">>} || A <- Args, is_map(A)]);
prompt_args(_) ->
    #{}.

%% Tool arguments: the required properties, filled from their types.
%% Optional ones stay out, which is what a mirrored header's absence
%% test looks for.
arguments(#{<<"properties">> := Props} = Schema) when is_map(Props) ->
    Required = maps:get(<<"required">>, Schema, []),
    maps:map(
        fun(Name, PropSchema) -> value_for(Name, PropSchema) end,
        maps:with(Required, Props)
    );
arguments(_) ->
    #{}.

%% Elicitation content: every property, defaults applied (SEP-1034).
elicitation_content(#{<<"properties">> := Props}) when is_map(Props) ->
    maps:map(fun(Name, Schema) -> value_for(Name, Schema) end, Props);
elicitation_content(_) ->
    #{}.

value_for(Name, Schema) ->
    case maps:get(<<"default">>, Schema, undefined) of
        undefined -> value_of_type(Name, Schema);
        Default -> Default
    end.

value_of_type(Name, #{<<"enum">> := [First | _]}) ->
    _ = Name,
    First;
%% A space and a non-ASCII character: a value that cannot travel as a
%% bare header token and has to be base64-wrapped (SEP-2243).
value_of_type(Name, #{<<"type">> := <<"string">>}) ->
    <<"value ", Name/binary, " \x{263A}"/utf8>>;
value_of_type(_Name, #{<<"type">> := <<"integer">>}) ->
    7;
value_of_type(_Name, #{<<"type">> := <<"number">>}) ->
    7;
value_of_type(_Name, #{<<"type">> := <<"boolean">>}) ->
    true;
value_of_type(_Name, #{<<"type">> := <<"array">>} = S) ->
    [value_for(<<"item">>, maps:get(<<"items">>, S, #{<<"type">> => <<"string">>}))];
value_of_type(_Name, #{<<"type">> := <<"object">>} = S) ->
    arguments(S);
value_of_type(Name, _Schema) ->
    <<"value-", Name/binary>>.

%%====================================================================
%% Handler: answer what the server asks
%%====================================================================

init(_Args) ->
    {ok, #{}}.

handle_request(<<"elicitation/create">>, Params, State) ->
    Schema = maps:get(<<"requestedSchema">>, Params, #{}),
    {reply, #{action => accept, content => elicitation_content(Schema)}, State};
handle_request(<<"sampling/createMessage">>, _Params, State) ->
    {reply,
        #{
            role => assistant,
            content => #{type => text, text => <<"the canned answer">>},
            model => <<"conformance-model">>
        },
        State};
handle_request(<<"roots/list">>, _Params, State) ->
    {reply, #{roots => [#{uri => <<"file:///tmp/conformance">>, name => <<"conformance">>}]},
        State};
handle_request(Method, _Params, State) ->
    {error, -32601, <<"Method not found: ", Method/binary>>, State}.

handle_notification(_Method, _Params, State) ->
    {ok, State}.
