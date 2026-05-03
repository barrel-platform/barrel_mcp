%%%-------------------------------------------------------------------
%%% @doc OAuth 2.1 + PKCE authorization for `barrel_mcp_client'.
%%%
%%% Implements the MCP authorization flow described in
%%% <a href="https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization">
%%% the spec</a> and the underlying RFCs:
%%%
%%% <ul>
%%%   <li>RFC 9728 — Protected Resource Metadata (PRM)</li>
%%%   <li>RFC 8414 — Authorization Server Metadata</li>
%%%   <li>RFC 7636 — PKCE (S256)</li>
%%%   <li>RFC 8707 — `resource' indicator on auth + token requests</li>
%%%   <li>RFC 6749 / OAuth 2.1 — authorization-code + refresh_token grants</li>
%%% </ul>
%%%
%%% == What this module does ==
%%%
%%% Two responsibilities, kept separate so hosts can mix them as
%%% they need:
%%%
%%% <ol>
%%%   <li>**Discovery helpers** that hosts use during initial token
%%%       acquisition: parse `WWW-Authenticate', fetch PRM, fetch AS
%%%       metadata, build authorization URLs with PKCE, exchange the
%%%       returned code at the token endpoint.</li>
%%%   <li>**`barrel_mcp_client_auth' behaviour implementation** that
%%%       attaches the `Authorization: Bearer ...' header on every
%%%       outgoing request and refreshes the token automatically on
%%%       401 (when a `refresh_token' was supplied).</li>
%%% </ol>
%%%
%%% == What this module does NOT do ==
%%%
%%% The authorization-code redirect step requires a browser and a
%%% local listener to capture the callback — that's a host concern,
%%% not a library one. Hosts run the interactive step however suits
%%% them (open a URL, do a CLI device-code flow, paste a code), then
%%% pass the resulting tokens back via the `{oauth, Config}' tuple.
%%% The library handles refresh from there.
%%%
%%% == Config shape ==
%%%
%%% ```
%%% {oauth, #{
%%%   access_token   := binary(),       %% required
%%%   refresh_token  => binary(),       %% optional; enables refresh
%%%   token_endpoint => binary(),       %% required if refresh_token set
%%%   client_id      => binary(),       %% required if refresh_token set
%%%   client_secret  => binary(),       %% optional confidential client
%%%   resource       => binary(),       %% RFC 8707 canonical id
%%%   scopes         => [binary()]      %% optional
%%% }}
%%% '''
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth_oauth).

-behaviour(barrel_mcp_client_auth).

%% Behaviour callbacks
-export([init/1, header/1, refresh/2]).

%% Public discovery + PKCE + token helpers (host-side).
-export([
    parse_www_authenticate/1,
    discover_protected_resource/1,
    discover_authorization_server/1,
    gen_code_verifier/0,
    code_challenge/1,
    build_authorization_url/2,
    exchange_code/2,
    refresh_token/2,
    client_credentials/2
]).

-export_type([config/0, handle/0]).

-type config() :: #{
    access_token := binary(),
    refresh_token => binary(),
    token_endpoint => binary(),
    client_id => binary(),
    client_secret => binary(),
    resource => binary(),
    scopes => [binary()]
} | client_credentials_config().

-type client_credentials_config() :: #{
    grant_type := client_credentials,
    token_endpoint := binary(),
    client_id := binary(),
    client_secret => binary(),
    client_assertion => binary(),
    resource => binary(),
    scopes => [binary()]
}.

-record(h, {
    access_token :: binary() | undefined,
    refresh_token :: binary() | undefined,
    token_endpoint :: binary() | undefined,
    client_id :: binary() | undefined,
    client_secret :: binary() | undefined,
    client_assertion :: binary() | undefined,
    resource :: binary() | undefined,
    scopes :: [binary()] | undefined,
    mode = auth_code :: auth_code | client_credentials
}).

-type handle() :: #h{}.

%%====================================================================
%% Behaviour callbacks
%%====================================================================

init(#{access_token := AT} = Cfg) when is_binary(AT), AT =/= <<>> ->
    {ok, #h{
        access_token = AT,
        refresh_token = maps:get(refresh_token, Cfg, undefined),
        token_endpoint = maps:get(token_endpoint, Cfg, undefined),
        client_id = maps:get(client_id, Cfg, undefined),
        client_secret = maps:get(client_secret, Cfg, undefined),
        resource = maps:get(resource, Cfg, undefined),
        scopes = maps:get(scopes, Cfg, undefined)
    }};
%% Client-credentials grant — fetch the token eagerly so init either
%% returns a usable handle or fails up front.
init(#{grant_type := client_credentials,
       token_endpoint := TE,
       client_id := CI} = Cfg)
  when is_binary(TE), TE =/= <<>>, is_binary(CI), CI =/= <<>> ->
    H0 = #h{
        token_endpoint = TE,
        client_id = CI,
        client_secret = maps:get(client_secret, Cfg, undefined),
        client_assertion = maps:get(client_assertion, Cfg, undefined),
        resource = maps:get(resource, Cfg, undefined),
        scopes = maps:get(scopes, Cfg, undefined),
        mode = client_credentials
    },
    case acquire_via_client_credentials(H0) of
        {ok, H1} -> {ok, H1};
        {error, _} = Err -> Err
    end;
init(#{grant_type := client_credentials}) ->
    {error, missing_token_endpoint_or_client_id};
init(_) ->
    {error, missing_access_token}.

header(#h{access_token = undefined}) ->
    none;
header(#h{access_token = AT}) ->
    {ok, <<"Bearer ", AT/binary>>}.

%% Client-credentials mode: re-acquire via the grant on every 401.
%% No refresh_token involved.
refresh(#h{mode = client_credentials} = H, _Www) ->
    acquire_via_client_credentials(H);
refresh(#h{refresh_token = undefined}, _Www) ->
    {error, no_refresh_token};
refresh(#h{token_endpoint = undefined}, _Www) ->
    {error, no_token_endpoint};
refresh(#h{client_id = undefined}, _Www) ->
    {error, no_client_id};
refresh(#h{} = H, _Www) ->
    case do_refresh(H) of
        {ok, NewTokens} ->
            {ok, apply_token_response(H, NewTokens)};
        {error, _} = Err ->
            Err
    end.

%%====================================================================
%% Discovery
%%====================================================================

%% @doc Extract the `resource_metadata' URL from a `WWW-Authenticate'
%% header per RFC 9728. Returns `undefined' if not present.
-spec parse_www_authenticate(binary() | undefined) -> binary() | undefined.
parse_www_authenticate(undefined) -> undefined;
parse_www_authenticate(Header) when is_binary(Header) ->
    case re:run(Header,
                <<"resource_metadata=\"?([^\",;]+)\"?">>,
                [{capture, all_but_first, binary}]) of
        {match, [Url]} -> Url;
        nomatch -> undefined
    end.

%% @doc Fetch and parse the Protected Resource Metadata document.
-spec discover_protected_resource(binary()) ->
    {ok, map()} | {error, term()}.
discover_protected_resource(Url) ->
    case http_get_json(Url) of
        {ok, #{<<"resource">> := _,
               <<"authorization_servers">> := AS} = Doc} when is_list(AS) ->
            {ok, Doc};
        {ok, Other} ->
            {error, {invalid_prm, Other}};
        Err -> Err
    end.

%% @doc Fetch the Authorization Server Metadata for the given issuer
%% URL. Tries `/.well-known/oauth-authorization-server' first, then
%% falls back to `/.well-known/openid-configuration'.
-spec discover_authorization_server(binary()) ->
    {ok, map()} | {error, term()}.
discover_authorization_server(Issuer) ->
    Base = trim_trailing_slash(Issuer),
    Primary = <<Base/binary, "/.well-known/oauth-authorization-server">>,
    Fallback = <<Base/binary, "/.well-known/openid-configuration">>,
    case http_get_json(Primary) of
        {ok, _} = Ok -> validate_as(Ok);
        {error, _} ->
            case http_get_json(Fallback) of
                {ok, _} = Ok2 -> validate_as(Ok2);
                Err -> Err
            end
    end.

validate_as({ok, #{<<"authorization_endpoint">> := _,
                   <<"token_endpoint">> := _} = Doc}) ->
    {ok, Doc};
validate_as({ok, Other}) ->
    {error, {invalid_as_metadata, Other}}.

%%====================================================================
%% PKCE
%%====================================================================

%% @doc Generate a 64-byte random URL-safe code verifier (RFC 7636).
-spec gen_code_verifier() -> binary().
gen_code_verifier() ->
    base64url(crypto:strong_rand_bytes(64)).

%% @doc Derive the S256 code challenge for a verifier.
-spec code_challenge(binary()) -> binary().
code_challenge(Verifier) ->
    base64url(crypto:hash(sha256, Verifier)).

%%====================================================================
%% Authorization URL + token endpoint
%%====================================================================

%% @doc Build an authorization-code+PKCE URL for the user to visit.
%% `Params' must include `client_id' and `redirect_uri'; the function
%% handles `code_challenge'/`code_challenge_method' for you given the
%% verifier. `state' is generated automatically if not supplied.
-spec build_authorization_url(binary(), map()) -> {binary(), binary(), binary()}.
build_authorization_url(AuthEndpoint, Params) ->
    Verifier = maps:get(code_verifier, Params, gen_code_verifier()),
    State = maps:get(state, Params, base64url(crypto:strong_rand_bytes(16))),
    Q = #{
        <<"response_type">> => <<"code">>,
        <<"client_id">> => required(client_id, Params),
        <<"redirect_uri">> => required(redirect_uri, Params),
        <<"code_challenge">> => code_challenge(Verifier),
        <<"code_challenge_method">> => <<"S256">>,
        <<"state">> => State
    },
    Q1 = maps:fold(fun add_optional/3, Q, #{
        scope => maps:get(scopes, Params, undefined),
        resource => maps:get(resource, Params, undefined)
    }),
    Url = iolist_to_binary([AuthEndpoint, $?, urlencode(Q1)]),
    {Url, Verifier, State}.

%% @doc Exchange an authorization code for tokens.
-spec exchange_code(binary(), map()) ->
    {ok, map()} | {error, term()}.
exchange_code(TokenEndpoint, Params) ->
    Body = #{
        <<"grant_type">> => <<"authorization_code">>,
        <<"code">> => required(code, Params),
        <<"code_verifier">> => required(code_verifier, Params),
        <<"client_id">> => required(client_id, Params),
        <<"redirect_uri">> => required(redirect_uri, Params)
    },
    Body1 = maps:fold(fun add_optional/3, Body, #{
        client_secret => maps:get(client_secret, Params, undefined),
        resource => maps:get(resource, Params, undefined)
    }),
    http_post_form(TokenEndpoint, Body1, maps:get(client_secret, Params, undefined),
                   maps:get(client_id, Params, undefined)).

%% @doc Refresh an access token via the refresh_token grant.
-spec refresh_token(binary(), map()) ->
    {ok, map()} | {error, term()}.
refresh_token(TokenEndpoint, Params) ->
    Body = #{
        <<"grant_type">> => <<"refresh_token">>,
        <<"refresh_token">> => required(refresh_token, Params),
        <<"client_id">> => required(client_id, Params)
    },
    Body1 = maps:fold(fun add_optional/3, Body, #{
        client_secret => maps:get(client_secret, Params, undefined),
        resource => maps:get(resource, Params, undefined),
        scope => maps:get(scopes, Params, undefined)
    }),
    http_post_form(TokenEndpoint, Body1, maps:get(client_secret, Params, undefined),
                   maps:get(client_id, Params, undefined)).

%% @doc Acquire an access token via the OAuth 2.1 client_credentials
%% grant — for unattended / machine-to-machine flows where there is
%% no human in the loop. Per the MCP `ext-auth' OAuth Client
%% Credentials extension, callers may authenticate either with a
%% `client_secret' (HTTP Basic, per RFC 6749) or a `client_assertion'
%% (`private_key_jwt' per RFC 7523).
-spec client_credentials(binary(), map()) ->
    {ok, map()} | {error, term()}.
client_credentials(TokenEndpoint, Params) ->
    Body0 = #{
        <<"grant_type">> => <<"client_credentials">>,
        <<"client_id">> => required(client_id, Params)
    },
    Body1 = case maps:get(client_assertion, Params, undefined) of
                undefined -> Body0;
                JWT when is_binary(JWT) ->
                    Body0#{
                        <<"client_assertion_type">> =>
                            <<"urn:ietf:params:oauth:client-assertion-type:jwt-bearer">>,
                        <<"client_assertion">> => JWT
                    }
            end,
    Body2 = maps:fold(fun add_optional/3, Body1, #{
        scope => maps:get(scopes, Params, undefined),
        resource => maps:get(resource, Params, undefined)
    }),
    %% `private_key_jwt' must NOT add HTTP Basic — pass the secret
    %% only when there is no assertion.
    Secret = case maps:get(client_assertion, Params, undefined) of
                 undefined ->
                     maps:get(client_secret, Params, undefined);
                 _ ->
                     undefined
             end,
    http_post_form(TokenEndpoint, Body2, Secret,
                   maps:get(client_id, Params, undefined)).

%%====================================================================
%% Internal — refresh wired through the behaviour
%%====================================================================

do_refresh(#h{refresh_token = RT, token_endpoint = TE,
              client_id = CI, client_secret = CS,
              resource = Res, scopes = Scopes}) ->
    Params = drop_undefined(#{
        refresh_token => RT,
        client_id => CI,
        client_secret => CS,
        resource => Res,
        scopes => Scopes
    }),
    refresh_token(TE, Params).

%% Fetch / re-fetch a token via the client_credentials grant and
%% fold the response into the handle.
acquire_via_client_credentials(#h{token_endpoint = TE,
                                   client_id = CI,
                                   client_secret = CS,
                                   client_assertion = CA,
                                   resource = Res,
                                   scopes = Scopes} = H) ->
    Params = drop_undefined(#{
        client_id => CI,
        client_secret => CS,
        client_assertion => CA,
        resource => Res,
        scopes => Scopes
    }),
    case client_credentials(TE, Params) of
        {ok, R} -> {ok, apply_token_response(H, R)};
        {error, _} = Err -> Err
    end.

apply_token_response(#h{} = H, #{<<"access_token">> := AT} = R) ->
    H#h{access_token = AT,
        refresh_token = maps:get(<<"refresh_token">>, R, H#h.refresh_token)};
apply_token_response(H, _) -> H.

%%====================================================================
%% HTTP helpers
%%====================================================================

http_get_json(Url) ->
    case hackney:request(get, Url, [{<<"accept">>, <<"application/json">>}],
                         <<>>, [with_body, {follow_redirect, true}]) of
        {ok, 200, _Hdrs, Body} ->
            try {ok, json:decode(Body)}
            catch _:_ -> {error, {invalid_json, Body}} end;
        {ok, Status, _Hdrs, _Body} ->
            {error, {http_error, Status}};
        {error, _} = Err -> Err
    end.

http_post_form(Url, Form, ClientSecret, ClientId)
  when is_binary(ClientId), ClientId =/= <<>>,
       is_binary(ClientSecret), ClientSecret =/= <<>> ->
    %% Confidential client uses HTTP Basic auth and omits client_id
    %% from body per OAuth 2.1.
    Form1 = maps:remove(<<"client_id">>, Form),
    Auth = base64:encode(<<ClientId/binary, ":", ClientSecret/binary>>),
    Headers = [{<<"authorization">>, <<"Basic ", Auth/binary>>},
               {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
               {<<"accept">>, <<"application/json">>}],
    do_post_form(Url, Headers, Form1);
http_post_form(Url, Form, _, _) ->
    Headers = [{<<"content-type">>, <<"application/x-www-form-urlencoded">>},
               {<<"accept">>, <<"application/json">>}],
    do_post_form(Url, Headers, Form).

do_post_form(Url, Headers, Form) ->
    Body = urlencode(Form),
    case hackney:request(post, Url, Headers, Body, [with_body]) of
        {ok, 200, _Hdrs, RB} ->
            try {ok, json:decode(RB)}
            catch _:_ -> {error, {invalid_json, RB}} end;
        {ok, Status, _Hdrs, RB} ->
            {error, {http_error, Status, RB}};
        {error, _} = Err -> Err
    end.

%%====================================================================
%% Encoders
%%====================================================================

urlencode(Map) when is_map(Map) ->
    Pairs = lists:map(fun({K, V}) -> [pct(K), $=, pct(value(V))] end,
                      maps:to_list(Map)),
    iolist_to_binary(lists:join($&, Pairs)).

value(L) when is_list(L) -> iolist_to_binary(lists:join(<<" ">>, L));
value(B) when is_binary(B) -> B;
value(I) when is_integer(I) -> integer_to_binary(I);
value(A) when is_atom(A) -> atom_to_binary(A, utf8).

pct(B) when is_binary(B) -> uri_string:quote(B);
pct(B) -> uri_string:quote(value(B)).

base64url(Bin) ->
    Enc = base64:encode(Bin),
    binary:replace(
        binary:replace(
            binary:replace(Enc, <<"+">>, <<"-">>, [global]),
            <<"/">>, <<"_">>, [global]),
        <<"=">>, <<>>, [global]).

trim_trailing_slash(B) ->
    case binary:last(B) of
        $/ -> binary:part(B, 0, byte_size(B) - 1);
        _ -> B
    end.

required(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error -> error({missing, Key})
    end.

add_optional(_K, undefined, Acc) -> Acc;
add_optional(K, V, Acc) ->
    Acc#{atom_to_binary(K, utf8) => V}.

drop_undefined(Map) ->
    maps:filter(fun(_, V) -> V =/= undefined end, Map).
