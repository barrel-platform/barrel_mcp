%%%-------------------------------------------------------------------
%%% @doc OAuth 2.1 + PKCE authorization for `barrel_mcp_client'.
%%%
%%% Implements the MCP authorization flow described in
%%% <a href="https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization">
%%% the spec</a> and the underlying RFCs:
%%%
%%% <ul>
%%%   <li>RFC 9728: Protected Resource Metadata (PRM)</li>
%%%   <li>RFC 8414: Authorization Server Metadata</li>
%%%   <li>RFC 7636: PKCE (S256)</li>
%%%   <li>RFC 8707: `resource' indicator on auth + token requests</li>
%%%   <li>RFC 9207: issuer identification on the authorization response</li>
%%%   <li>RFC 6749 / OAuth 2.1: authorization-code + refresh_token grants</li>
%%%   <li>draft-ietf-oauth-client-id-metadata-document-00: an HTTPS
%%%       URL as the `client_id'</li>
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
%%% == The redirect step ==
%%%
%%% Sending a person to the authorization URL and getting the callback
%%% back is the host's: a browser, a paste, a local listener. The host
%%% gives it as the `authorize' fun below, and the handle runs the rest
%%% from a 401: discovery, registration, PKCE, validation, exchange,
%%% refresh, step-up. A host that obtained tokens by other means gives
%%% them as `access_token' instead and the handle only refreshes.
%%%
%%% == Config shape ==
%%%
%%% ```
%%% {oauth, #{
%%%   redirect_uri   := binary(),       %% the flow's registered redirect
%%%   authorize      := fun((Url) -> {ok, CallbackUrl} | {error, _}),
%%%   client_id      => binary(),       %% pre-registered; else CIMD or DCR
%%%   client_secret  => binary(),
%%%   client_id_metadata_url => binary(),
%%%   client_metadata => map(),         %% the DCR document
%%%   token_endpoint_auth_method => client_secret_basic | client_secret_post | none,
%%%   scopes         => [binary()],
%%%   resource       => binary(),
%%%   store          => {module(), term()}, %% barrel_mcp_client_auth_store
%%%   allow_insecure_oauth => boolean()
%%% }}
%%% '''
%%%
%%% or, with tokens in hand:
%%%
%%% ```
%%% {oauth, #{
%%%   access_token   := binary(),       %% required
%%%   refresh_token  => binary(),       %% optional; enables refresh
%%%   token_endpoint => binary(),       %% required if refresh_token set
%%%   client_id      => binary(),       %% required if refresh_token set
%%%   client_secret  => binary(),       %% optional confidential client
%%%   resource       => binary(),       %% RFC 8707 canonical id
%%%   scopes         => [binary()],     %% optional
%%%   allow_insecure_oauth => boolean() %% see below
%%% }}
%%% '''
%%%
%%% == HTTPS ==
%%%
%%% Every authorization-server URL, configured or discovered, must be
%%% `https' (MCP authorization security considerations, "Communication
%%% Security"). `allow_insecure_oauth => true' lifts that for a
%%% plaintext test server. It is noncompliant and never a production
%%% setting.
%%%
%%% == Sections, in file order ==
%%%
%%% <ul>
%%%   <li>Behaviour callbacks: `init/1', `headers/1', `refresh/2',
%%%       `challenge/2', `settled/1', `request_headers/3'.</li>
%%%   <li>Discovery: `WWW-Authenticate' parsing, PRM, AS metadata,
%%%       the HTTPS policy `secure_url/2'.</li>
%%%   <li>PKCE, authorization URL, token endpoint.</li>
%%%   <li>Choosing a registration mechanism, Client ID Metadata
%%%       Documents, binding a client to an authorization server.</li>
%%%   <li>The authorization-code flow driven from a challenge:
%%%       `prm_flow', `ensure_client', `run_authorization',
%%%       `exchange', `step_up'; the non-interactive grants and DPoP
%%%       proofs sit with it.</li>
%%%   <li>HTTP helpers and encoders.</li>
%%% </ul>
%%%
%%% == The handle record ==
%%%
%%% `#h{}' is the whole state. The fields that steer behaviour:
%%% `mode' (which grant), `phase' (`flow' runs the authorization-code
%%% flow from a 401, `token' only refreshes what the host supplied),
%%% `tea_method' (how the client authenticates at the token
%%% endpoint, persisted with the client), `want_refresh' (ask for
%%% `offline_access' when the AS lists it), `insecure' (the plaintext
%%% policy), `dpop' (proof key and the AS and RS nonces),
%%% `token_type' (`dpop' switches the `Authorization' scheme). `prm',
%%% `as_metadata' and `client' are the discovered documents;
%%% `requested_scope' and `granted_scope' drive step-up on 403.
%%%
%%% == Processes ==
%%%
%%% The handle is a value; the transport calls it. `challenge/2' does
%%% network I/O and may block on the host's `authorize' fun, which is
%%% why `barrel_mcp_client_http' runs it in a worker.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth_oauth).

-behaviour(barrel_mcp_client_auth).

%% Behaviour callbacks
-export([init/1, header/1, refresh/2, challenge/2, settled/1, request_headers/3]).

%% Public discovery + PKCE + token helpers (host-side).
-export([
    parse_www_authenticate/1,
    discover_protected_resource/1,
    discover_protected_resource/2,
    discover_authorization_server/1,
    discover_authorization_server/2,
    secure_url/2,
    gen_code_verifier/0,
    code_challenge/1,
    build_authorization_url/2,
    exchange_code/2,
    refresh_token/2,
    client_credentials/2,
    token_exchange/2,
    jwt_bearer/2,
    register_client/2,
    register_client/3,
    validate_callback/2,
    registration_strategy/2,
    client_id_metadata_document/1,
    is_client_id_metadata_url/1,
    check_issuer_binding/2
]).

-export_type([config/0, handle/0]).

-type config() ::
    #{
        access_token := binary(),
        refresh_token => binary(),
        token_endpoint => binary(),
        client_id => binary(),
        client_secret => binary(),
        resource => binary(),
        scopes => [binary()],
        allow_insecure_oauth => boolean()
    }
    | client_credentials_config()
    | enterprise_managed_config().

-type client_credentials_config() :: #{
    grant_type := client_credentials,
    token_endpoint := binary(),
    client_id := binary(),
    client_secret => binary(),
    client_assertion => binary(),
    resource => binary(),
    scopes => [binary()],
    allow_insecure_oauth => boolean()
}.

-type enterprise_managed_config() :: #{
    grant_type := enterprise_managed,
    %% IdP token endpoint (RFC 8693 token-exchange).
    idp_token_endpoint := binary(),
    %% Authorization server token endpoint (RFC 7523 jwt-bearer).
    as_token_endpoint := binary(),
    client_id := binary(),
    client_secret => binary(),
    client_assertion => binary(),
    %% IdP-issued ID Token or SAML assertion the host obtained
    %% out of band (browser flow, SSO).
    subject_token := binary(),
    %% Spec URN: `id_token' or `saml2'.
    subject_token_type := binary(),
    %% AS issuer URL: the `aud' the IdP signs into the ID-JAG.
    audience := binary(),
    %% MCP server's RFC 9728 resource identifier.
    resource := binary(),
    scopes => [binary()],
    allow_insecure_oauth => boolean()
}.

-record(h, {
    %% `allow_insecure_oauth' from the config; threaded into every
    %% token request the handle makes.
    insecure = false :: boolean(),
    access_token :: binary() | undefined,
    refresh_token :: binary() | undefined,
    token_endpoint :: binary() | undefined,
    client_id :: binary() | undefined,
    client_secret :: binary() | undefined,
    client_assertion :: binary() | undefined,
    resource :: binary() | undefined,
    scopes :: [binary()] | undefined,
    mode = auth_code :: auth_code | client_credentials | enterprise_managed | jwt_bearer,
    %% What the non-interactive grants present.
    assertion :: binary() | undefined,
    private_key :: {barrel_mcp_jwt:key(), binary()} | undefined,
    %% RFC 9449: the proof key and the nonces the servers asked for.
    dpop ::
        undefined
        | #{key := term(), as_nonce := binary() | undefined, rs_nonce := binary() | undefined},
    token_type = bearer :: bearer | dpop,
    %% `flow': this handle runs the authorization-code flow itself from
    %% a 401. `token': the host obtained the tokens and we only refresh.
    phase = token :: token | flow,
    redirect_uri :: binary() | undefined,
    authorize :: fun((binary()) -> {ok, binary()} | {error, term()}) | undefined,
    client_metadata :: map() | undefined,
    client_id_metadata_url :: binary() | undefined,
    tea_method :: client_secret_basic | client_secret_post | none | undefined,
    store :: barrel_mcp_client_auth_store:store(),
    want_refresh = true :: boolean(),
    server_url :: binary() | undefined,
    prm :: map() | undefined,
    as_metadata :: map() | undefined,
    %% The client identity in use and the issuer it is bound to.
    client :: map() | undefined,
    requested_scope :: [binary()] | undefined,
    granted_scope :: [binary()] | undefined,
    %% Enterprise-managed-only state (RFC 8693 + RFC 7523 chain).
    idp_token_endpoint :: binary() | undefined,
    subject_token :: binary() | undefined,
    subject_token_type :: binary() | undefined,
    audience :: binary() | undefined
}).

-type handle() :: #h{}.

%%====================================================================
%% Behaviour callbacks
%%====================================================================

init(Cfg) when is_map(Cfg) ->
    Insecure = insecure_opt(Cfg),
    Opts = #{allow_insecure_oauth => Insecure},
    case secure_urls(configured_endpoints(Cfg), Opts) of
        ok ->
            case init_mode(Cfg, Insecure) of
                {ok, H} -> with_credentials(H, Cfg);
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end;
init(_) ->
    {error, missing_access_token}.

%% `private_key' (PEM and algorithm) for private_key_jwt, `dpop' for
%% RFC 9449 sender-constrained tokens.
with_credentials(H, Cfg) ->
    try
        Key =
            case maps:get(private_key, Cfg, undefined) of
                undefined -> undefined;
                {Pem, Alg} when is_binary(Pem) -> {barrel_mcp_jwt:decode_pem(Pem), Alg};
                {_, _} = Given -> Given
            end,
        Dpop =
            case maps:get(dpop, Cfg, false) of
                true ->
                    #{
                        key => barrel_mcp_jwt:generate_key(),
                        as_nonce => undefined,
                        rs_nonce => undefined
                    };
                _ ->
                    undefined
            end,
        {ok, H#h{private_key = Key, dpop = Dpop}}
    catch
        _:Reason -> {error, {invalid_private_key, Reason}}
    end.

%% The endpoints a config names directly, bypassing discovery.
configured_endpoints(Cfg) ->
    [
        Url
     || Key <- [token_endpoint, idp_token_endpoint, as_token_endpoint],
        Url <- [maps:get(Key, Cfg, undefined)],
        is_binary(Url)
    ].

%% Authorization-code flow driven from a 401: the host supplies the
%% redirect step and gets the tokens back through the handle.
init_mode(#{redirect_uri := Redirect, authorize := Authorize} = Cfg, Insecure) when
    is_binary(Redirect), is_function(Authorize, 1)
->
    H0 = #h{
        insecure = Insecure,
        mode = auth_code,
        phase = flow,
        redirect_uri = Redirect,
        authorize = Authorize,
        client_metadata = maps:get(client_metadata, Cfg, undefined),
        client_id_metadata_url = maps:get(client_id_metadata_url, Cfg, undefined),
        tea_method = maps:get(token_endpoint_auth_method, Cfg, undefined),
        store = maps:get(store, Cfg, undefined),
        want_refresh = maps:get(want_refresh_token, Cfg, true),
        resource = maps:get(resource, Cfg, undefined),
        scopes = maps:get(scopes, Cfg, undefined),
        requested_scope = maps:get(scopes, Cfg, undefined)
    },
    {ok, load_store(set_client(H0, preregistered(Cfg)))};
init_mode(#{access_token := AT} = Cfg, Insecure) when is_binary(AT), AT =/= <<>> ->
    {ok, #h{
        insecure = Insecure,
        access_token = AT,
        refresh_token = maps:get(refresh_token, Cfg, undefined),
        token_endpoint = maps:get(token_endpoint, Cfg, undefined),
        client_id = maps:get(client_id, Cfg, undefined),
        client_secret = maps:get(client_secret, Cfg, undefined),
        resource = maps:get(resource, Cfg, undefined),
        scopes = maps:get(scopes, Cfg, undefined)
    }};
%% Client-credentials grant: fetch the token eagerly so init either
%% returns a usable handle or fails up front.
init_mode(
    #{
        grant_type := client_credentials,
        token_endpoint := TE,
        client_id := CI
    } = Cfg,
    Insecure
) when
    is_binary(TE), TE =/= <<>>, is_binary(CI), CI =/= <<>>
->
    H0 = #h{
        insecure = Insecure,
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
%% No token endpoint yet: it is discovered from the first 401, the way
%% the authorization-code flow discovers its authorization server.
init_mode(#{grant_type := client_credentials, client_id := CI} = Cfg, Insecure) when
    is_binary(CI), CI =/= <<>>
->
    {ok, #h{
        insecure = Insecure,
        mode = client_credentials,
        phase = flow,
        client_id = CI,
        client_secret = maps:get(client_secret, Cfg, undefined),
        client_assertion = maps:get(client_assertion, Cfg, undefined),
        resource = maps:get(resource, Cfg, undefined),
        scopes = maps:get(scopes, Cfg, undefined)
    }};
init_mode(#{grant_type := client_credentials}, _Insecure) ->
    {error, missing_client_id};
init_mode(#{grant_type := jwt_bearer, client_id := CI, assertion := Assertion} = Cfg, Insecure) when
    is_binary(CI), CI =/= <<>>, is_binary(Assertion), Assertion =/= <<>>
->
    {ok, #h{
        insecure = Insecure,
        mode = jwt_bearer,
        phase = flow,
        client_id = CI,
        assertion = Assertion,
        token_endpoint = maps:get(token_endpoint, Cfg, undefined),
        resource = maps:get(resource, Cfg, undefined),
        scopes = maps:get(scopes, Cfg, undefined)
    }};
init_mode(#{grant_type := jwt_bearer}, _Insecure) ->
    {error, missing_client_id_or_assertion};
%% Enterprise-managed authorization (MCP `ext-auth' EMA):
%% RFC 8693 token-exchange at the IdP -> ID-JAG, then RFC 7523
%% jwt-bearer at the AS -> short-lived MCP access token.
init_mode(
    #{
        grant_type := enterprise_managed,
        idp_token_endpoint := IDP,
        as_token_endpoint := AsTokenEndpoint,
        client_id := CI,
        subject_token := ST,
        subject_token_type := STT,
        audience := Aud,
        resource := Res
    } = Cfg,
    Insecure
) when
    is_binary(IDP),
    IDP =/= <<>>,
    is_binary(AsTokenEndpoint),
    AsTokenEndpoint =/= <<>>,
    is_binary(CI),
    CI =/= <<>>,
    is_binary(ST),
    ST =/= <<>>,
    is_binary(STT),
    STT =/= <<>>,
    is_binary(Aud),
    Aud =/= <<>>,
    is_binary(Res),
    Res =/= <<>>
->
    H0 = #h{
        token_endpoint = AsTokenEndpoint,
        client_id = CI,
        client_secret = maps:get(client_secret, Cfg, undefined),
        client_assertion = maps:get(client_assertion, Cfg, undefined),
        resource = Res,
        scopes = maps:get(scopes, Cfg, undefined),
        mode = enterprise_managed,
        insecure = Insecure,
        idp_token_endpoint = IDP,
        subject_token = ST,
        subject_token_type = STT,
        audience = Aud
    },
    case acquire_via_ema(H0) of
        {ok, H1} -> {ok, H1};
        {error, _} = Err -> Err
    end;
%% The authorization server, its issuer (the ID-JAG audience) and the
%% resource are discovered from the first 401.
init_mode(
    #{
        grant_type := enterprise_managed,
        idp_token_endpoint := IDP,
        client_id := CI,
        subject_token := ST,
        subject_token_type := STT
    } = Cfg,
    Insecure
) when
    is_binary(IDP),
    IDP =/= <<>>,
    is_binary(CI),
    CI =/= <<>>,
    is_binary(ST),
    ST =/= <<>>,
    is_binary(STT)
->
    {ok, #h{
        insecure = Insecure,
        mode = enterprise_managed,
        phase = flow,
        client_id = CI,
        client_secret = maps:get(client_secret, Cfg, undefined),
        client_assertion = maps:get(client_assertion, Cfg, undefined),
        idp_token_endpoint = IDP,
        subject_token = ST,
        subject_token_type = STT,
        audience = maps:get(audience, Cfg, undefined),
        resource = maps:get(resource, Cfg, undefined),
        scopes = maps:get(scopes, Cfg, undefined)
    }};
init_mode(#{grant_type := enterprise_managed}, _Insecure) ->
    {error, missing_endpoints_or_subject_token};
init_mode(_, _Insecure) ->
    {error, missing_access_token}.

header(#h{access_token = undefined}) ->
    none;
header(#h{access_token = AT, token_type = dpop}) ->
    {ok, <<"DPoP ", AT/binary>>};
header(#h{access_token = AT}) ->
    {ok, <<"Bearer ", AT/binary>>}.

%% @doc RFC 9449 4: a proof per request, bound to the method and URL,
%% carrying the token's hash and the nonce the resource server asked
%% for. Nothing without a DPoP key or before a token exists.
-spec request_headers(handle(), binary(), binary()) -> {[{binary(), binary()}], handle()}.
request_headers(
    #h{dpop = #{key := Key, rs_nonce := Nonce}, access_token = AT} = H, Method, Url
) when
    is_binary(AT)
->
    {[{<<"dpop">>, dpop_proof(Key, Method, Url, Nonce, AT)}], H};
request_headers(H, _Method, _Url) ->
    {[], H}.

%% Client-credentials mode: re-acquire via the grant on every 401.
%% No refresh_token involved.
refresh(#h{mode = client_credentials} = H, _Www) ->
    acquire_via_client_credentials(H);
refresh(#h{mode = enterprise_managed} = H, _Www) ->
    acquire_via_ema(H);
refresh(#h{mode = jwt_bearer} = H, _Www) ->
    acquire_via_jwt_bearer(H);
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
parse_www_authenticate(undefined) ->
    undefined;
parse_www_authenticate(Header) when is_binary(Header) ->
    case
        re:run(
            Header,
            <<"resource_metadata=\"?([^\",;]+)\"?">>,
            [{capture, all_but_first, binary}]
        )
    of
        {match, [Url]} -> Url;
        nomatch -> undefined
    end.

%% @doc Fetch and parse the Protected Resource Metadata document.
-spec discover_protected_resource(binary()) ->
    {ok, map()} | {error, term()}.
discover_protected_resource(Url) ->
    discover_protected_resource(Url, #{}).

%% @doc {@link discover_protected_resource/1} with options
%% (`allow_insecure_oauth').
-spec discover_protected_resource(binary(), map()) ->
    {ok, map()} | {error, term()}.
discover_protected_resource(Url, Opts) ->
    case http_get_json(Url, Opts) of
        {ok,
            #{
                <<"resource">> := _,
                <<"authorization_servers">> := Servers
            } = Doc} when is_list(Servers) ->
            {ok, Doc};
        {ok, Other} ->
            {error, {invalid_prm, Other}};
        Err ->
            Err
    end.

%% @doc Fetch and validate the Authorization Server Metadata for an
%% issuer URL, trying the well-known locations in the order the MCP
%% specification requires (authorization-server-discovery, "Authorization
%% Server Metadata Discovery").
-spec discover_authorization_server(binary()) ->
    {ok, map()} | {error, term()}.
discover_authorization_server(Issuer) ->
    discover_authorization_server(Issuer, #{}).

%% @doc {@link discover_authorization_server/1} with options
%% (`allow_insecure_oauth').
%%
%% A URL that cannot be fetched or does not hold a metadata document
%% falls through to the next one. The first document found is final:
%% its `issuer' must equal `Issuer', it must advertise `S256' PKCE, and
%% its endpoints must be `https'. A document failing those is an
%% error, not a reason to try the next URL: the specification says it
%% must not be used, and a later URL cannot make it safe.
-spec discover_authorization_server(binary(), map()) ->
    {ok, map()} | {error, term()}.
discover_authorization_server(Issuer, Opts) ->
    case secure_url(Issuer, Opts) of
        ok -> try_discovery_urls(discovery_urls(Issuer), Issuer, Opts, undefined);
        {error, _} = Err -> Err
    end.

try_discovery_urls([], _Issuer, _Opts, LastErr) ->
    {error, {as_metadata_not_found, LastErr}};
try_discovery_urls([Url | Rest], Issuer, Opts, _LastErr) ->
    case http_get_json(Url, Opts) of
        {ok,
            #{
                <<"issuer">> := _,
                <<"authorization_endpoint">> := _,
                <<"token_endpoint">> := _
            } = Doc} ->
            validate_as(Doc, Issuer, Opts);
        {ok, Other} ->
            try_discovery_urls(Rest, Issuer, Opts, {invalid_as_metadata, Other});
        {error, Reason} ->
            try_discovery_urls(Rest, Issuer, Opts, Reason)
    end.

%% RFC 8414 3.1 path insertion first, then the OpenID variants; an
%% issuer without a path has only the two root documents.
discovery_urls(Issuer) ->
    #{scheme := Scheme, host := Host} = Parsed = uri_string:parse(Issuer),
    Port =
        case maps:get(port, Parsed, undefined) of
            undefined -> <<>>;
            P -> <<":", (integer_to_binary(P))/binary>>
        end,
    Origin = <<Scheme/binary, "://", Host/binary, Port/binary>>,
    case string:trim(maps:get(path, Parsed, <<>>), trailing, "/") of
        <<>> ->
            [
                <<Origin/binary, "/.well-known/oauth-authorization-server">>,
                <<Origin/binary, "/.well-known/openid-configuration">>
            ];
        Path ->
            [
                <<Origin/binary, "/.well-known/oauth-authorization-server", Path/binary>>,
                <<Origin/binary, "/.well-known/openid-configuration", Path/binary>>,
                <<Origin/binary, Path/binary, "/.well-known/openid-configuration">>
            ]
    end.

validate_as(#{<<"issuer">> := Got} = Doc, Issuer, Opts) ->
    case Got =:= Issuer of
        false ->
            {error, {issuer_mismatch, Got, Issuer}};
        true ->
            case pkce_supported(Doc) of
                ok -> secure_urls(as_endpoints(Doc), Opts, Doc);
                {error, _} = Err -> Err
            end
    end.

%% security-considerations, "Proof Key for Code Exchange": absent means
%% no PKCE and the client must refuse.
pkce_supported(Doc) ->
    case maps:get(<<"code_challenge_methods_supported">>, Doc, undefined) of
        undefined ->
            {error, no_pkce};
        Methods when is_list(Methods) ->
            case lists:member(<<"S256">>, Methods) of
                true -> ok;
                false -> {error, {no_s256, Methods}}
            end;
        Other ->
            {error, {no_s256, Other}}
    end.

as_endpoints(Doc) ->
    [
        Url
     || Key <- [
            <<"authorization_endpoint">>,
            <<"token_endpoint">>,
            <<"registration_endpoint">>
        ],
        Url <- [maps:get(Key, Doc, undefined)],
        is_binary(Url)
    ].

secure_urls(Urls, Opts, Doc) ->
    case secure_urls(Urls, Opts) of
        ok -> {ok, Doc};
        {error, _} = Err -> Err
    end.

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

%% @doc Check an authorization response before redeeming its code.
%%
%% `Params' is the query the authorization server sent back to the
%% redirect URI. `Expected' carries the `state' this client generated,
%% the `issuer' it recorded when it discovered the authorization
%% server, and optionally that server's `as_metadata' document.
%%
%% `state' must match, which is what ties the response to the request
%% this client started. `iss' is then checked per RFC 9207, which
%% exists because a client talking to several authorization servers
%% can otherwise be handed a code minted by one of them at another's
%% endpoint and cannot tell:
%%
%% <ul>
%%   <li>present, and the server's
%%       `authorization_response_iss_parameter_supported' is `true':
%%       compared</li>
%%   <li>present, and the server says nothing or `false': compared</li>
%%   <li>absent, and the server advertises it: rejected</li>
%%   <li>absent, and the server says nothing or `false': accepted</li>
%% </ul>
%%
%% A present `iss' is compared whatever the metadata says, to
%% accommodate servers that emit it before advertising it. An absent
%% one is only fatal when the server said it would send one, which
%% makes its absence a signal rather than an omission.
%%
%% The comparison is exact. RFC 3986 normalisation (case folding,
%% default-port elision, trailing slash, percent-encoding) must not be
%% applied first, since each of those turns two distinct issuers into
%% one.
%%
%% Call this for error responses too: on mismatch the `error',
%% `error_description' and `error_uri' the response carries are not
%% yours to act on or show, because you cannot tell who wrote them.
-spec validate_callback(map(), map()) -> ok | {error, term()}.
validate_callback(Params, Expected) when is_map(Params), is_map(Expected) ->
    case check_state(Params, Expected) of
        ok -> check_issuer(Params, Expected);
        {error, _} = Err -> Err
    end.

check_state(Params, Expected) ->
    case {param(<<"state">>, Params), maps:get(state, Expected, undefined)} of
        {_, undefined} -> {error, no_expected_state};
        {Same, Same} -> ok;
        {Got, Want} -> {error, {state_mismatch, Got, Want}}
    end.

check_issuer(Params, Expected) ->
    case {param(<<"iss">>, Params), iss_promised(Expected)} of
        {undefined, true} -> {error, missing_iss};
        {undefined, _} -> ok;
        {Issuer, _} -> compare_issuer(Issuer, Expected)
    end.

compare_issuer(Issuer, Expected) ->
    case maps:get(issuer, Expected, undefined) of
        undefined -> {error, no_expected_issuer};
        Issuer -> ok;
        Want -> {error, {issuer_mismatch, Issuer, Want}}
    end.

%% Whether the authorization server's own metadata says it sends `iss'.
%% Only a literal `true' promises anything; anything else, including
%% metadata we were not given, leaves absence tolerated.
iss_promised(#{as_metadata := Md}) when is_map(Md) ->
    maps:get(<<"authorization_response_iss_parameter_supported">>, Md, false);
iss_promised(_Expected) ->
    false.

%% Callback parameters reach us as whatever the host parsed them into.
param(Key, Params) ->
    case maps:get(Key, Params, undefined) of
        undefined -> maps:get(binary_to_atom(Key, utf8), Params, undefined);
        Value -> Value
    end.

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
    http_post_form(
        TokenEndpoint,
        Body1,
        maps:get(client_secret, Params, undefined),
        maps:get(client_id, Params, undefined),
        Params
    ).

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
    http_post_form(
        TokenEndpoint,
        Body1,
        maps:get(client_secret, Params, undefined),
        maps:get(client_id, Params, undefined),
        Params
    ).

%% @doc Acquire an access token via the OAuth 2.1 client_credentials
%% grant, for unattended / machine-to-machine flows where there is
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
    post_token_request(TokenEndpoint, Body0, optional_scope_and_resource(Params), Params).

%% @doc RFC 8693 OAuth 2.0 Token Exchange. Used by the MCP
%% `ext-auth' Enterprise-Managed Authorization extension to
%% exchange an IdP-issued ID Token (or SAML assertion) for an
%% Identity Assertion JWT Authorization Grant (the "ID-JAG"),
%% scoped to a specific MCP server resource.
%%
%% Returns `{ok, IdJag}' where `IdJag' is the binary token
%% extracted from the response's `access_token' field, or an
%% error describing the failure. A 4xx with `invalid_grant'
%% surfaces the typed `{error, subject_token_expired}' (the
%% RFC 8693 error semantic for an expired or revoked subject
%% token).
-spec token_exchange(binary(), map()) ->
    {ok, binary()} | {error, term()}.
token_exchange(TokenEndpoint, Params) ->
    Body0 = #{
        <<"grant_type">> =>
            <<"urn:ietf:params:oauth:grant-type:token-exchange">>,
        <<"client_id">> => required(client_id, Params),
        <<"requested_token_type">> =>
            <<"urn:ietf:params:oauth:token-type:id-jag">>,
        <<"subject_token">> => required(subject_token, Params),
        <<"subject_token_type">> =>
            required(subject_token_type, Params),
        <<"audience">> => required(audience, Params),
        <<"resource">> => required(resource, Params)
    },
    %% No optional fold: RFC 8693 carries `resource' and `audience' as
    %% required parameters, already above, and `scope' is not part of an
    %% ID-JAG request.
    case post_token_request(TokenEndpoint, Body0, #{}, Params) of
        {ok, #{<<"access_token">> := IdJag}} ->
            {ok, IdJag};
        {ok, R} ->
            {error, {missing_id_jag, R}};
        {error, {http_error, Status, Body}} when Status >= 400, Status < 500 ->
            case is_invalid_grant(Body) of
                true -> {error, subject_token_expired};
                false -> {error, {http_error, Status, Body}}
            end;
        {error, _} = Err ->
            Err
    end.

%% @doc RFC 7523 JWT Bearer access-token request. The second
%% step of the EMA chain: present the ID-JAG to the MCP server's
%% authorization-server token endpoint and receive a short-lived
%% access token.
-spec jwt_bearer(binary(), map()) ->
    {ok, map()} | {error, term()}.
jwt_bearer(TokenEndpoint, Params) ->
    Body0 = #{
        <<"grant_type">> =>
            <<"urn:ietf:params:oauth:grant-type:jwt-bearer">>,
        <<"client_id">> => required(client_id, Params),
        <<"assertion">> => required(assertion, Params)
    },
    post_token_request(TokenEndpoint, Body0, optional_scope_and_resource(Params), Params).

%% @doc Dynamic Client Registration ([RFC 7591][rfc7591]).
%%
%% Deprecated by MCP `2026-07-28' in favour of Client ID Metadata
%% Documents, and kept for authorization servers that do not support
%% them. It is the only registration mechanism that mints a credential
%% you then have to store and bind to an issuer. Let
%% {@link registration_strategy/2} choose rather than reaching for this
%% directly; see {@link client_id_metadata_document/1}.
%%
%% Posts the supplied client metadata to the AS's
%% `registration_endpoint' and returns the AS's response unchanged:
%% typically including
%% `client_id', optionally `client_secret',
%% `client_id_issued_at', `client_secret_expires_at', plus any
%% client-metadata echo the AS chose to include.
%%
%% Hosts that receive a fresh `client_id' (and `client_secret', if
%% issued) feed it into a subsequent `{oauth, ...}',
%% `{oauth_client_credentials, ...}', or `{oauth_enterprise, ...}'
%% connect spec. This stays a standalone exchanger; auto-wiring
%% would require persisting credentials, which is host policy.
%%
%% [rfc7591]: https://datatracker.ietf.org/doc/html/rfc7591
-spec register_client(
    RegistrationEndpoint :: binary(),
    Metadata :: map()
) ->
    {ok, ClientInfo :: map()} | {error, term()}.
register_client(RegistrationEndpoint, Metadata) ->
    register_client(RegistrationEndpoint, Metadata, #{}).

%% @doc Variant of {@link register_client/2} that accepts an
%% options map. Currently the only option is
%% `initial_access_token' (RFC 7591 section 3): an opaque bearer
%% token issued out of band by the AS to gate registration. When
%% present, the call adds `Authorization: Bearer <token>'.
-spec register_client(
    RegistrationEndpoint :: binary(),
    Metadata :: map(),
    Opts :: #{
        initial_access_token => binary(),
        _ => _
    }
) ->
    {ok, ClientInfo :: map()} | {error, term()}.
register_client(RegistrationEndpoint, Metadata0, Opts) when
    is_map(Metadata0), is_map(Opts)
->
    case secure_url(RegistrationEndpoint, Opts) of
        ok -> do_register_client(RegistrationEndpoint, Metadata0, Opts);
        {error, _} = Err -> Err
    end.

do_register_client(RegistrationEndpoint, Metadata0, Opts) ->
    Metadata = with_application_type(Metadata0),
    Base = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json">>}
    ],
    Headers =
        case maps:get(initial_access_token, Opts, undefined) of
            undefined ->
                Base;
            Token when is_binary(Token) ->
                [
                    {<<"authorization">>, <<"Bearer ", Token/binary>>}
                    | Base
                ]
        end,
    Body = iolist_to_binary(json:encode(Metadata)),
    case
        hackney:request(
            post,
            RegistrationEndpoint,
            Headers,
            Body,
            [with_body]
        )
    of
        {ok, Status, _Hdrs, Resp} when
            Status >= 200, Status < 300
        ->
            try
                {ok, json:decode(Resp)}
            catch
                _:_ -> {error, {invalid_json, Resp}}
            end;
        {ok, Status, _Hdrs, Resp} ->
            {error, {http_error, Status, Resp}};
        {error, _} = Err ->
            Err
    end.

%% An OIDC authorization server that also does dynamic registration
%% applies redirect-URI rules by `application_type', and omitting it
%% defaults to `web', which rejects the loopback URIs a local client
%% needs. Non-OIDC servers ignore the field, so naming it always is
%% safe and saves a registration that fails for a reason the error
%% rarely explains.
with_application_type(Metadata) ->
    case maps:is_key(<<"application_type">>, Metadata) of
        true -> Metadata;
        false -> Metadata#{<<"application_type">> => infer_application_type(Metadata)}
    end.

%% A client redirecting to loopback or a private scheme is native by
%% definition; only one reachable at a remote https URL is a web app.
infer_application_type(Metadata) ->
    case maps:get(<<"redirect_uris">>, Metadata, []) of
        Uris when is_list(Uris), Uris =/= [] ->
            case lists:all(fun is_web_redirect/1, Uris) of
                true -> <<"web">>;
                false -> <<"native">>
            end;
        _ ->
            <<"native">>
    end.

is_web_redirect(<<"https://localhost", _/binary>>) -> false;
is_web_redirect(<<"https://127.0.0.1", _/binary>>) -> false;
is_web_redirect(<<"https://", _/binary>>) -> true;
is_web_redirect(_Other) -> false.

%%====================================================================
%% Choosing a registration mechanism
%%====================================================================

%% @doc Decide how to obtain a `client_id' for an authorization server.
%%
%% `AsMetadata' is the document from {@link
%% discover_authorization_server/1}. `Opts' says what this client
%% already has:
%%
%% ```
%% #{client_id              => binary(),   %% pre-registered
%%   client_id_metadata_url => binary()}   %% a CIMD document you host
%% '''
%%
%% The order is the specification's, and the reasons are worth
%% keeping in mind when overriding it:
%%
%% <ol>
%%   <li>`{pre_registered, ClientId}' when you already have one. It
%%       names a relationship that exists; nothing discovered can
%%       improve on that.</li>
%%   <li>`{client_id_metadata_document, Url}' when the server
%%       advertises `client_id_metadata_document_supported' and you
%%       host a document. The `client_id' is the URL itself, so there
%%       is no credential to store and none to go stale.</li>
%%   <li>`{dynamic_registration, Endpoint}' when the server offers
%%       one. Deprecated, kept for servers without CIMD, and the only
%%       branch that mints a credential you then have to keep.</li>
%%   <li>`prompt_user' when none of the above applies: the client
%%       cannot invent an identity, so a person has to supply one.</li>
%% </ol>
-spec registration_strategy(map(), map()) ->
    {pre_registered, binary()}
    | {client_id_metadata_document, binary()}
    | {dynamic_registration, binary()}
    | prompt_user.
registration_strategy(AsMetadata, Opts) when is_map(AsMetadata), is_map(Opts) ->
    Cimd = maps:get(client_id_metadata_url, Opts, undefined),
    case maps:get(client_id, Opts, undefined) of
        ClientId when is_binary(ClientId), ClientId =/= <<>> ->
            {pre_registered, ClientId};
        _ when is_binary(Cimd), Cimd =/= <<>> ->
            case maps:get(<<"client_id_metadata_document_supported">>, AsMetadata, false) of
                true -> {client_id_metadata_document, Cimd};
                _ -> fallback_strategy(AsMetadata)
            end;
        _ ->
            fallback_strategy(AsMetadata)
    end.

fallback_strategy(AsMetadata) ->
    case maps:get(<<"registration_endpoint">>, AsMetadata, undefined) of
        Endpoint when is_binary(Endpoint), Endpoint =/= <<>> ->
            {dynamic_registration, Endpoint};
        _ ->
            prompt_user
    end.

%%====================================================================
%% Client ID Metadata Documents
%%====================================================================

%% @doc Build the metadata document a client serves at its own
%% `client_id' URL.
%%
%% With CIMD the `client_id' is an HTTPS URL, and the authorization
%% server fetches this document from it at authorization time. That
%% removes the registration round trip, and with it the credential a
%% client would otherwise have to store per authorization server: the
%% same URL works everywhere, because whoever needs the metadata goes
%% and reads it.
%%
%% `Metadata' is binary-keyed, like {@link register_client/2}, and
%% must carry `client_id', `client_name' and `redirect_uris'. The
%% `client_id' must be the exact URL you serve the document from,
%% https, with a path: servers compare the two and reject a document
%% that names a different identity than the one they fetched.
%%
%% `grant_types', `response_types' and `token_endpoint_auth_method'
%% default to the public-client-with-PKCE shape. Set them yourself for
%% anything else, including `refresh_token' in `grant_types' if you
%% want refresh tokens.
-spec client_id_metadata_document(map()) -> {ok, map()} | {error, term()}.
client_id_metadata_document(Metadata) when is_map(Metadata) ->
    case validate_cimd(Metadata) of
        ok ->
            {ok, maps:merge(cimd_defaults(), Metadata)};
        {error, _} = Err ->
            Err
    end.

cimd_defaults() ->
    #{
        <<"grant_types">> => [<<"authorization_code">>],
        <<"response_types">> => [<<"code">>],
        <<"token_endpoint_auth_method">> => <<"none">>
    }.

validate_cimd(Metadata) ->
    case maps:get(<<"client_id">>, Metadata, undefined) of
        ClientId when is_binary(ClientId) ->
            case is_client_id_metadata_url(ClientId) of
                true -> validate_cimd_rest(Metadata);
                false -> {error, {invalid_client_id, ClientId}}
            end;
        _ ->
            {error, {missing, <<"client_id">>}}
    end.

validate_cimd_rest(Metadata) ->
    case maps:get(<<"client_name">>, Metadata, undefined) of
        Name when is_binary(Name), Name =/= <<>> ->
            validate_cimd_redirects(Metadata);
        _ ->
            {error, {missing, <<"client_name">>}}
    end.

validate_cimd_redirects(Metadata) ->
    case maps:get(<<"redirect_uris">>, Metadata, undefined) of
        Uris when is_list(Uris), Uris =/= [] ->
            case lists:all(fun(U) -> is_binary(U) andalso U =/= <<>> end, Uris) of
                true -> ok;
                false -> {error, {invalid, <<"redirect_uris">>}}
            end;
        _ ->
            {error, {missing, <<"redirect_uris">>}}
    end.

%% @doc Whether a `client_id' is a Client ID Metadata Document URL.
%%
%% Https with a path. The path is what the draft requires and what
%% keeps a bare origin from being read as an identity.
-spec is_client_id_metadata_url(term()) -> boolean().
is_client_id_metadata_url(<<"https://", Rest/binary>>) when Rest =/= <<>> ->
    case binary:split(Rest, <<"/">>) of
        [Authority, Path] -> Authority =/= <<>> andalso Path =/= <<>>;
        [_Authority] -> false
    end;
is_client_id_metadata_url(_Other) ->
    false.

%%====================================================================
%% Authorization server binding
%%====================================================================

%% @doc Check credentials against the authorization server about to be
%% used.
%%
%% A `client_id' from pre-registration or dynamic registration belongs
%% to the server that issued it and means nothing at another. The
%% server can change under a client without warning, since it comes
%% from the resource's metadata and that is refetched; sending the old
%% credentials to the new one leaks a client identity to a party that
%% was never given it, and fails in a way that reads like a bad token.
%%
%% `Credentials' is whatever you persisted, and must record the
%% `issuer' it was obtained from, binary- or atom-keyed. `Issuer' is
%% the one from the metadata you are about to use.
%%
%% A CIMD `client_id' passes against any issuer: it is a URL the
%% server resolves itself, so it is not bound to one and needs no
%% re-registration when the server changes.
-spec check_issuer_binding(map(), binary()) -> ok | {error, term()}.
check_issuer_binding(Credentials, Issuer) when is_map(Credentials), is_binary(Issuer) ->
    case cred(client_id, Credentials) of
        ClientId when is_binary(ClientId) ->
            case is_client_id_metadata_url(ClientId) of
                true -> ok;
                false -> compare_binding(Credentials, Issuer)
            end;
        _ ->
            compare_binding(Credentials, Issuer)
    end.

compare_binding(Credentials, Issuer) ->
    case cred(issuer, Credentials) of
        undefined -> {error, unbound_credentials};
        Issuer -> ok;
        Other -> {error, {issuer_changed, Other, Issuer}}
    end.

cred(Key, Credentials) ->
    case maps:get(Key, Credentials, undefined) of
        undefined -> maps:get(atom_to_binary(Key, utf8), Credentials, undefined);
        Value -> Value
    end.

%%====================================================================
%% Internal: refresh wired through the behaviour
%%====================================================================

do_refresh(
    #h{
        refresh_token = RT,
        token_endpoint = TE,
        client_id = CI,
        client_secret = CS,
        resource = Res,
        scopes = Scopes,
        insecure = Insecure
    } = H
) ->
    Params = drop_undefined(#{
        refresh_token => RT,
        client_id => CI,
        client_secret => CS,
        resource => Res,
        scopes => Scopes,
        token_endpoint_auth_method => refresh_tea(H),
        allow_insecure_oauth => Insecure,
        dpop => dpop_opt(H)
    }),
    refresh_token(TE, Params).

refresh_tea(#h{client = Client} = H) when is_map(Client) -> tea_method(H);
refresh_tea(_H) -> undefined.

%% Fetch / re-fetch a token via the client_credentials grant and
%% fold the response into the handle.
acquire_via_client_credentials(
    #h{
        token_endpoint = TE,
        client_id = CI,
        client_secret = CS,
        client_assertion = CA,
        resource = Res,
        scopes = Scopes,
        insecure = Insecure
    } = H
) ->
    _ = CA,
    Params = drop_undefined(#{
        client_id => CI,
        client_secret => CS,
        client_assertion => client_assertion(H),
        resource => Res,
        scopes => Scopes,
        allow_insecure_oauth => Insecure,
        dpop => dpop_opt(H)
    }),
    case client_credentials(TE, Params) of
        {ok, R} -> {ok, apply_token_response(H, R)};
        {error, _} = Err -> Err
    end.

%% Walk the EMA chain: token-exchange at the IdP, then
%% jwt-bearer at the AS, fold the resulting access token into
%% the handle. Surfaces `subject_token_expired' on the typed
%% RFC 6749 `invalid_grant' error so hosts can re-acquire from
%% the IdP without parsing JSON themselves.
acquire_via_ema(
    #h{
        idp_token_endpoint = IDP,
        token_endpoint = AsTokenEndpoint,
        client_id = CI,
        client_secret = CS,
        client_assertion = CA,
        subject_token = ST,
        subject_token_type = STT,
        audience = Aud,
        resource = Res,
        scopes = Scopes,
        insecure = Insecure
    } = H
) ->
    Step1 = drop_undefined(#{
        client_id => CI,
        client_secret => CS,
        client_assertion => CA,
        subject_token => ST,
        subject_token_type => STT,
        audience => Aud,
        resource => Res,
        allow_insecure_oauth => Insecure,
        dpop => dpop_opt(H)
    }),
    case token_exchange(IDP, Step1) of
        {ok, IdJag} ->
            Step2 = drop_undefined(#{
                client_id => CI,
                client_secret => CS,
                client_assertion => CA,
                assertion => IdJag,
                resource => Res,
                scopes => Scopes,
                allow_insecure_oauth => Insecure,
                dpop => dpop_opt(H)
            }),
            case jwt_bearer(AsTokenEndpoint, Step2) of
                {ok, R} -> {ok, apply_token_response(H, R)};
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

%% RFC 6749 token-error parsing: a 4xx body MAY be JSON with
%% `{"error": "invalid_grant"}'. Used by `token_exchange/2' to
%% surface the typed `subject_token_expired' value.
is_invalid_grant(Body) when is_binary(Body) ->
    try json:decode(Body) of
        #{<<"error">> := <<"invalid_grant">>} -> true;
        _ -> false
    catch
        _:_ -> false
    end;
is_invalid_grant(_) ->
    false.

apply_token_response(#h{} = H, #{<<"access_token">> := AT} = R) ->
    Granted =
        case maps:get(<<"scope">>, R, undefined) of
            S when is_binary(S) -> binary:split(S, <<" ">>, [global, trim_all]);
            _ -> H#h.requested_scope
        end,
    TokenType =
        case string:lowercase(maps:get(<<"token_type">>, R, <<"bearer">>)) of
            <<"dpop">> -> dpop;
            _ -> bearer
        end,
    Dpop =
        case {H#h.dpop, maps:get(<<"dpop_nonce">>, R, undefined)} of
            {#{} = D, Nonce} when is_binary(Nonce) -> D#{as_nonce => Nonce};
            {D, _} -> D
        end,
    H#h{
        access_token = AT,
        refresh_token = maps:get(<<"refresh_token">>, R, H#h.refresh_token),
        granted_scope = Granted,
        token_type = TokenType,
        dpop = Dpop
    };
apply_token_response(H, _) ->
    H.

%%====================================================================
%% The authorization-code flow, driven from a challenge
%%====================================================================

%% @doc Answer a 401 or a 403 `insufficient_scope' with a handle that
%% holds a usable token, running discovery, registration, the host's
%% redirect step and the code exchange as the challenge requires.
-spec challenge(handle(), barrel_mcp_client_auth:challenge()) ->
    {ok, handle()} | {error, term()}.
%% RFC 9449 9: the resource server wants a nonce in the proof. Not a
%% token problem; remember it and let the transport reissue.
challenge(
    #h{dpop = #{} = Dpop} = H, #{www_authenticate := Www, dpop_nonce := Nonce} = Challenge
) when
    is_binary(Www), is_binary(Nonce)
->
    case binary:match(Www, <<"use_dpop_nonce">>) of
        nomatch -> challenge_grant(H, Challenge);
        _ -> {ok, H#h{dpop = Dpop#{rs_nonce => Nonce}}}
    end;
challenge(H, Challenge) ->
    challenge_grant(H, Challenge).

challenge_grant(#h{mode = client_credentials} = H, Challenge) ->
    with_token_endpoint(H, Challenge, fun acquire_via_client_credentials/1);
challenge_grant(#h{mode = enterprise_managed} = H, Challenge) ->
    with_token_endpoint(H, Challenge, fun acquire_via_ema/1);
challenge_grant(#h{mode = jwt_bearer} = H, Challenge) ->
    with_token_endpoint(H, Challenge, fun acquire_via_jwt_bearer/1);
challenge_grant(#h{phase = token} = H, Challenge) ->
    refresh(H, maps:get(www_authenticate, Challenge, undefined));
challenge_grant(#h{phase = flow} = H, #{status := 403} = Challenge) ->
    step_up(H, Challenge);
challenge_grant(#h{phase = flow} = H, #{status := 401, server_url := ServerUrl} = Challenge) ->
    H1 = H#h{server_url = ServerUrl},
    case auth_era(maps:get(protocol_version, Challenge, undefined)) of
        none -> {error, unauthorized};
        legacy -> legacy_flow(H1, Challenge);
        prm -> prm_flow(H1, Challenge)
    end.

%% A non-interactive grant with its token endpoint in hand just
%% acquires; one without discovers it from the challenge first: the
%% protected resource, its authorization server, and with them the
%% resource indicator, the ID-JAG audience and the scope.
with_token_endpoint(#h{token_endpoint = TE} = H, _Challenge, Acquire) when is_binary(TE) ->
    Acquire(H);
with_token_endpoint(H, #{server_url := ServerUrl} = Challenge, Acquire) ->
    Www = maps:get(www_authenticate, Challenge, undefined),
    H1 = H#h{server_url = ServerUrl},
    Opts = opts(H1),
    case discover_prm(prm_urls(Www, ServerUrl), Opts, undefined) of
        {ok, #{<<"resource">> := Resource, <<"authorization_servers">> := [Issuer | _]} = Prm} ->
            case discover_authorization_server(Issuer, Opts) of
                {ok, AsMd} ->
                    H2 = H1#h{
                        prm = Prm,
                        as_metadata = AsMd,
                        token_endpoint = maps:get(<<"token_endpoint">>, AsMd),
                        resource = default_to(H1#h.resource, Resource),
                        audience = default_to(H1#h.audience, Issuer),
                        scopes = default_to(H1#h.scopes, select_scope(Www, Prm, AsMd, H1))
                    },
                    Acquire(H2);
                {error, _} = Err ->
                    Err
            end;
        {ok, Prm} ->
            {error, {invalid_prm, Prm}};
        {error, _} = Err ->
            Err
    end.

default_to(undefined, Value) -> Value;
default_to(Given, _Value) -> Given.

acquire_via_jwt_bearer(#h{token_endpoint = TE, client_id = CI, assertion = A} = H) ->
    Params = drop_undefined(#{
        client_id => CI,
        assertion => A,
        resource => H#h.resource,
        scopes => H#h.scopes,
        allow_insecure_oauth => H#h.insecure,
        dpop => dpop_opt(H)
    }),
    case jwt_bearer(TE, Params) of
        {ok, R} -> {ok, apply_token_response(H, R)};
        {error, _} = Err -> Err
    end.

%% RFC 7523 2.2 / RFC 7521: a private_key_jwt assertion, minted fresh
%% for each request. Its audience is the authorization server itself
%% (the issuer) when discovery told us, else the token endpoint.
client_assertion(#h{client_assertion = Given}) when is_binary(Given) ->
    Given;
client_assertion(#h{private_key = {Key, Alg}, client_id = CI, token_endpoint = TE} = H) ->
    Now = erlang:system_time(second),
    Aud =
        case H#h.as_metadata of
            #{<<"issuer">> := Issuer} when is_binary(Issuer) -> Issuer;
            _ -> TE
        end,
    barrel_mcp_jwt:sign(
        #{
            <<"iss">> => CI,
            <<"sub">> => CI,
            <<"aud">> => Aud,
            <<"jti">> => barrel_mcp_jwt:b64url(crypto:strong_rand_bytes(16)),
            <<"iat">> => Now,
            <<"exp">> => Now + 300
        },
        Key,
        Alg
    );
client_assertion(_H) ->
    undefined.

dpop_opt(#h{dpop = #{key := Key, as_nonce := Nonce}}) -> {Key, Nonce};
dpop_opt(_H) -> undefined.

%% RFC 9449 4.2: the proof JWT. `htu' is the URL without query or
%% fragment; `ath' binds the proof to the access token it accompanies.
dpop_proof(Key, Method, Url, Nonce, AccessToken) ->
    Parsed = uri_string:parse(Url),
    Htu = uri_string:recompose(maps:without([query, fragment], Parsed)),
    Claims0 = #{
        <<"jti">> => barrel_mcp_jwt:b64url(crypto:strong_rand_bytes(16)),
        <<"htm">> => Method,
        <<"htu">> => Htu,
        <<"iat">> => erlang:system_time(second)
    },
    Claims1 =
        case Nonce of
            undefined -> Claims0;
            _ -> Claims0#{<<"nonce">> => Nonce}
        end,
    Claims =
        case AccessToken of
            undefined -> Claims1;
            _ -> Claims1#{<<"ath">> => barrel_mcp_jwt:b64url(crypto:hash(sha256, AccessToken))}
        end,
    barrel_mcp_jwt:sign(
        #{<<"typ">> => <<"dpop+jwt">>, <<"jwk">> => barrel_mcp_jwt:jwk(Key)},
        Claims,
        Key,
        <<"ES256">>
    ).

%% @doc The transport reports an accepted request. Nothing to reset:
%% the retry budget lives with the request, not here.
-spec settled(handle()) -> handle().
settled(H) ->
    H.

%% 2025-03-26 put the authorization server at the MCP server's origin;
%% 2025-06-18 introduced Protected Resource Metadata; 2024-11-05 has no
%% authorization at all. No negotiated version yet means the modern
%% flow: that is what a stateless 2026 server answers before any
%% request succeeds.
auth_era(undefined) -> prm;
auth_era(<<"2024-11-05">>) -> none;
auth_era(<<"2025-03-26">>) -> legacy;
auth_era(_Version) -> prm.

%%-- Protected Resource Metadata era ----------------------------------

prm_flow(H, #{www_authenticate := Www}) ->
    Opts = opts(H),
    case discover_prm(prm_urls(Www, H#h.server_url), Opts, undefined) of
        {ok, #{<<"resource">> := Resource, <<"authorization_servers">> := [Issuer | _]} = Prm} ->
            case resource_allowed(H#h.server_url, Resource) of
                false ->
                    {error, {resource_mismatch, Resource, H#h.server_url}};
                true ->
                    H1 = rebind(H#h{prm = Prm}, Issuer),
                    case H1#h.refresh_token of
                        undefined -> authorize_at(H1, Issuer, Www, true);
                        _ -> refresh_or_authorize(H1, Issuer, Www)
                    end
            end;
        {ok, Prm} ->
            {error, {invalid_prm, Prm}};
        {error, _} = Err ->
            Err
    end.

%% The header names the document (RFC 9728 5.1); without it, the
%% path-based well-known for the server URL, then the root one.
prm_urls(Www, ServerUrl) ->
    #{origin := Origin, path := Path} = split_url(ServerUrl),
    FromHeader =
        case parse_www_authenticate(Www) of
            undefined -> [];
            Url -> [Url]
        end,
    Guessed =
        case Path of
            P when P =:= <<>>; P =:= <<"/">> ->
                [<<Origin/binary, "/.well-known/oauth-protected-resource">>];
            P ->
                [
                    <<Origin/binary, "/.well-known/oauth-protected-resource", P/binary>>,
                    <<Origin/binary, "/.well-known/oauth-protected-resource">>
                ]
        end,
    lists:uniq(FromHeader ++ Guessed).

%% Any URL that yields no document moves to the next one, the way the
%% reference client does (mcp/client/auth/oauth2.py, protected resource
%% response handling).
discover_prm([], _Opts, Last) ->
    {error, {no_prm, Last}};
discover_prm([Url | Rest], Opts, _Last) ->
    case discover_protected_resource(Url, Opts) of
        {ok, _} = Ok -> Ok;
        {error, Reason} -> discover_prm(Rest, Opts, Reason)
    end.

%% RFC 8707: the PRM's resource must cover the server URL, same origin
%% and a path the server URL lives under.
resource_allowed(ServerUrl, Resource) when is_binary(Resource) ->
    #{origin := O1, path := P1} = split_url(ServerUrl),
    #{origin := O2, path := P2} = split_url(Resource),
    O1 =:= O2 andalso path_under(P1, P2);
resource_allowed(_ServerUrl, _Resource) ->
    false.

path_under(Server, Resource) ->
    S = trim_slash(Server),
    R = trim_slash(Resource),
    R =:= <<>> orelse S =:= R orelse
        binary:longest_common_prefix([S, <<R/binary, "/">>]) =:= byte_size(R) + 1.

trim_slash(P) ->
    string:trim(P, trailing, "/").

%% Scheme, lowercased host and effective port as one binary, plus the
%% path. Fragments are dropped (RFC 8707 canonical form).
split_url(Url) ->
    Parsed = uri_string:parse(Url),
    Scheme = string:lowercase(maps:get(scheme, Parsed, <<"https">>)),
    Host = string:lowercase(maps:get(host, Parsed, <<>>)),
    Default =
        case Scheme of
            <<"https">> -> 443;
            _ -> 80
        end,
    Port = maps:get(port, Parsed, Default),
    Origin =
        case Port =:= Default of
            true -> <<Scheme/binary, "://", Host/binary>>;
            false -> <<Scheme/binary, "://", Host/binary, ":", (integer_to_binary(Port))/binary>>
        end,
    #{origin => Origin, path => maps:get(path, Parsed, <<>>)}.

%% A stored client is only good at the issuer it was minted for. A new
%% issuer means a new registration and no reuse of the old tokens.
rebind(#h{client = undefined} = H, _Issuer) ->
    H;
rebind(#h{client = Client} = H, Issuer) ->
    case check_issuer_binding(Client, Issuer) of
        ok ->
            H;
        {error, unbound_credentials} ->
            set_client(H, Client#{issuer => Issuer});
        {error, {issuer_changed, _, _}} ->
            _ = barrel_mcp_client_auth_store:delete(H#h.store, client),
            _ = barrel_mcp_client_auth_store:delete(H#h.store, tokens),
            (set_client(H, undefined))#h{
                access_token = undefined,
                refresh_token = undefined,
                granted_scope = undefined,
                as_metadata = undefined,
                token_endpoint = undefined
            }
    end.

refresh_or_authorize(H, Issuer, Www) ->
    case do_refresh(H) of
        {ok, Resp} -> {ok, store_tokens(apply_token_response(H, Resp))};
        {error, _} -> authorize_at(H#h{refresh_token = undefined}, Issuer, Www, true)
    end.

authorize_at(H, Issuer, Www, WithResource) ->
    case discover_authorization_server(Issuer, opts(H)) of
        {ok, AsMd} ->
            H1 = H#h{as_metadata = AsMd, token_endpoint = maps:get(<<"token_endpoint">>, AsMd)},
            Scope = select_scope(Www, H1#h.prm, AsMd, H1),
            case ensure_client(H1#h{requested_scope = Scope}, AsMd, Issuer) of
                {ok, H2} -> run_authorization(H2, WithResource);
                {error, _} = Err -> Err
            end;
        {error, _} = Err ->
            Err
    end.

%% authorization/index.mdx "Scope Selection Strategy": the challenge's
%% scope, else the PRM's scopes_supported, else omit. The config's
%% scopes stand in when neither names any. `offline_access' is added
%% only when the authorization server lists it (SEP-2207).
select_scope(Www, Prm, AsMd, H) ->
    Base =
        case www_param(<<"scope">>, Www) of
            undefined ->
                case Prm of
                    #{<<"scopes_supported">> := L} when is_list(L), L =/= [] -> L;
                    _ -> H#h.scopes
                end;
            Scope ->
                binary:split(Scope, <<" ">>, [global, trim_all])
        end,
    with_offline_access(Base, AsMd, H).

with_offline_access(undefined, _As, _H) ->
    undefined;
with_offline_access(Scope, AsMd, #h{want_refresh = true}) ->
    Supported = maps:get(<<"scopes_supported">>, AsMd, []),
    case
        is_list(Supported) andalso lists:member(<<"offline_access">>, Supported) andalso
            not lists:member(<<"offline_access">>, Scope)
    of
        true -> Scope ++ [<<"offline_access">>];
        false -> Scope
    end;
with_offline_access(Scope, _As, _H) ->
    Scope.

ensure_client(#h{client = #{client_id := _}} = H, _As, _Issuer) ->
    {ok, H};
ensure_client(H, AsMd, Issuer) ->
    case registration_strategy(AsMd, #{client_id_metadata_url => H#h.client_id_metadata_url}) of
        {client_id_metadata_document, Url} ->
            {ok,
                store_client(
                    set_client(H, #{
                        client_id => Url, issuer => Issuer, token_endpoint_auth_method => none
                    })
                )};
        {dynamic_registration, Endpoint} ->
            Metadata = client_metadata(H),
            case register_client(Endpoint, Metadata, opts(H)) of
                {ok, Info} ->
                    Client = #{
                        client_id => maps:get(<<"client_id">>, Info),
                        client_secret => maps:get(<<"client_secret">>, Info, undefined),
                        issuer => Issuer,
                        token_endpoint_auth_method =>
                            tea_of(
                                maps:get(
                                    <<"token_endpoint_auth_method">>,
                                    Info,
                                    maps:get(<<"token_endpoint_auth_method">>, Metadata, undefined)
                                )
                            )
                    },
                    {ok, store_client(set_client(H, Client))};
                {error, _} = Err ->
                    Err
            end;
        prompt_user ->
            {error, no_registration_path};
        {pre_registered, _} ->
            {ok, H}
    end.

client_metadata(#h{client_metadata = Given} = H) when is_map(Given) ->
    Given#{<<"redirect_uris">> => [H#h.redirect_uri]};
client_metadata(H) ->
    Base = #{
        <<"client_name">> => <<"barrel_mcp">>,
        <<"redirect_uris">> => [H#h.redirect_uri],
        <<"grant_types">> => [<<"authorization_code">>, <<"refresh_token">>],
        <<"response_types">> => [<<"code">>],
        <<"token_endpoint_auth_method">> => <<"none">>
    },
    case H#h.requested_scope of
        undefined -> Base;
        Scope -> Base#{<<"scope">> => iolist_to_binary(lists:join(<<" ">>, Scope))}
    end.

tea_of(<<"client_secret_basic">>) -> client_secret_basic;
tea_of(<<"client_secret_post">>) -> client_secret_post;
tea_of(<<"none">>) -> none;
tea_of(Atom) when is_atom(Atom) -> Atom;
tea_of(_) -> undefined.

%% The method the client registered with, else the configured one,
%% else the first the server supports, else what the credential allows.
tea_method(#h{client = Client, tea_method = Configured, as_metadata = AsMd}) ->
    Registered = maps:get(token_endpoint_auth_method, Client, undefined),
    Supported =
        case AsMd of
            #{<<"token_endpoint_auth_methods_supported">> := L} when is_list(L) ->
                [M || M <- [tea_of(X) || X <- L], M =/= undefined];
            _ ->
                []
        end,
    HasSecret = is_binary(maps:get(client_secret, Client, undefined)),
    case {Registered, Configured, Supported, HasSecret} of
        {M, _, _, _} when M =/= undefined -> M;
        {_, M, _, _} when M =/= undefined -> M;
        {_, _, [M | _], _} -> M;
        {_, _, _, true} -> client_secret_basic;
        _ -> none
    end.

run_authorization(#h{as_metadata = AsMd, client = #{client_id := ClientId}} = H, WithResource) ->
    AuthEndpoint = maps:get(<<"authorization_endpoint">>, AsMd),
    Params0 = #{
        client_id => ClientId,
        redirect_uri => H#h.redirect_uri,
        scopes => H#h.requested_scope
    },
    Params =
        case WithResource of
            true -> Params0#{resource => resource_indicator(H)};
            false -> Params0
        end,
    {Url0, Verifier, State} = build_authorization_url(AuthEndpoint, drop_undefined(Params)),
    Url = with_consent_prompt(Url0, H#h.requested_scope),
    case (H#h.authorize)(Url) of
        {ok, CallbackUrl} ->
            case callback_query(CallbackUrl, AuthEndpoint, H#h.redirect_uri) of
                {ok, Query} ->
                    Expected = drop_undefined(#{
                        state => State,
                        issuer => maps:get(<<"issuer">>, AsMd, undefined),
                        as_metadata => AsMd
                    }),
                    case validate_callback(Query, Expected) of
                        ok ->
                            exchange(
                                H, maps:get(<<"code">>, Query, undefined), Verifier, WithResource
                            );
                        {error, _} = Err ->
                            Err
                    end;
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

%% RFC 8707: the resource indicator is the PRM's own `resource' when
%% there is one, else the configured one, else the server URL.
resource_indicator(#h{prm = #{<<"resource">> := R}}) when is_binary(R) -> R;
resource_indicator(#h{resource = R}) when is_binary(R) -> R;
resource_indicator(#h{server_url = Url}) -> Url.

%% OpenID Connect Core 11: `offline_access' needs `prompt=consent'.
with_consent_prompt(Url, Scope) when is_list(Scope) ->
    case lists:member(<<"offline_access">>, Scope) of
        true -> <<Url/binary, "&prompt=consent">>;
        false -> Url
    end;
with_consent_prompt(Url, _Scope) ->
    Url.

%% The host hands back the URL the authorization server redirected to.
%% It is only read when it is the registered redirect URI; a relative
%% one is resolved against the authorization endpoint first.
callback_query(CallbackUrl, AuthEndpoint, RedirectUri) ->
    case uri_string:resolve(CallbackUrl, AuthEndpoint) of
        Resolved when is_binary(Resolved) ->
            Got = uri_string:parse(Resolved),
            Want = uri_string:parse(RedirectUri),
            case same_location(Got, Want) of
                true -> {ok, query_map(maps:get(query, Got, <<>>))};
                false -> {error, {callback_mismatch, Resolved}}
            end;
        _ ->
            {error, {callback_mismatch, CallbackUrl}}
    end.

same_location(#{scheme := _} = A, #{scheme := _} = B) ->
    #{origin := O1} = split_url(uri_string:recompose(maps:with([scheme, host, port, path], A))),
    #{origin := O2} = split_url(uri_string:recompose(maps:with([scheme, host, port, path], B))),
    O1 =:= O2 andalso
        maps:get(path, A, <<"/">>) =:= maps:get(path, B, <<"/">>);
same_location(_, _) ->
    false.

query_map(Query) ->
    case uri_string:dissect_query(Query) of
        Pairs when is_list(Pairs) ->
            maps:from_list([{K, V} || {K, V} <- Pairs, is_binary(V)]);
        _ ->
            #{}
    end.

exchange(_H, undefined, _Verifier, _WithResource) ->
    {error, no_authorization_code};
exchange(#h{client = Client} = H, Code, Verifier, WithResource) ->
    Params0 = #{
        code => Code,
        code_verifier => Verifier,
        client_id => maps:get(client_id, Client),
        client_secret => maps:get(client_secret, Client, undefined),
        redirect_uri => H#h.redirect_uri,
        token_endpoint_auth_method => tea_method(H),
        allow_insecure_oauth => H#h.insecure,
        dpop => dpop_opt(H)
    },
    Params =
        case WithResource of
            true -> Params0#{resource => resource_indicator(H)};
            false -> Params0
        end,
    case exchange_code(H#h.token_endpoint, drop_undefined(Params)) of
        {ok, Resp} -> {ok, store_tokens(apply_token_response(H, Resp))};
        {error, _} = Err -> Err
    end.

%%-- 403 insufficient_scope: step up ------------------------------------

%% SEP-2350: request the union of what was requested, what was granted
%% and what the challenge names; no rediscovery.
step_up(#h{as_metadata = AsMd, client = Client} = H, Challenge) when
    is_map(AsMd), is_map(Client)
->
    Www = maps:get(www_authenticate, Challenge, undefined),
    Challenged =
        case www_param(<<"scope">>, Www) of
            undefined -> [];
            S -> binary:split(S, <<" ">>, [global, trim_all])
        end,
    Union = lists:uniq(
        default_list(H#h.requested_scope) ++ default_list(H#h.granted_scope) ++ Challenged
    ),
    Scope =
        case Union of
            [] -> undefined;
            _ -> Union
        end,
    run_authorization(H#h{requested_scope = Scope}, auth_era(undefined) =:= prm);
step_up(H, Challenge) ->
    challenge(H, Challenge#{status => 401}).

default_list(undefined) -> [];
default_list(L) -> L.

%%-- 2025-03-26: metadata at the server's origin, fixed fallbacks ------

%% authorization.mdx (2025-03-26) 2.3: the authorization base URL is the
%% server URL without its path; metadata lives at the well-known path
%% there, and `/authorize', `/token', `/register' serve when it does
%% not. PKCE is still used; that revision does not require it to be
%% advertised.
legacy_flow(H, _Challenge) ->
    #{origin := Base} = split_url(H#h.server_url),
    Opts = opts(H),
    case secure_url(Base, Opts) of
        {error, _} = Err ->
            Err;
        ok ->
            AsMd =
                case
                    http_get_json(<<Base/binary, "/.well-known/oauth-authorization-server">>, Opts)
                of
                    {ok, #{<<"authorization_endpoint">> := _, <<"token_endpoint">> := _} = Doc} ->
                        Doc#{<<"issuer">> => maps:get(<<"issuer">>, Doc, Base)};
                    _ ->
                        #{
                            <<"issuer">> => Base,
                            <<"authorization_endpoint">> => <<Base/binary, "/authorize">>,
                            <<"token_endpoint">> => <<Base/binary, "/token">>,
                            <<"registration_endpoint">> => <<Base/binary, "/register">>
                        }
                end,
            case secure_urls(as_endpoints(AsMd), Opts) of
                {error, _} = Err ->
                    Err;
                ok ->
                    H1 = H#h{
                        as_metadata = AsMd,
                        token_endpoint = maps:get(<<"token_endpoint">>, AsMd),
                        requested_scope = H#h.scopes
                    },
                    case ensure_client(rebind(H1, Base), AsMd, Base) of
                        {ok, H2} -> run_authorization(H2, false);
                        {error, _} = Err -> Err
                    end
            end
    end.

%%-- Handle plumbing ----------------------------------------------------

opts(#h{insecure = Insecure}) ->
    #{allow_insecure_oauth => Insecure}.

%% `client_id'/`client_secret' are mirrored into the record fields the
%% refresh path reads.
set_client(H, undefined) ->
    H#h{client = undefined, client_id = undefined, client_secret = undefined};
set_client(H, Client) ->
    H#h{
        client = Client,
        client_id = maps:get(client_id, Client, undefined),
        client_secret = maps:get(client_secret, Client, undefined)
    }.

preregistered(Cfg) ->
    case maps:get(client_id, Cfg, undefined) of
        ClientId when is_binary(ClientId), ClientId =/= <<>> ->
            #{
                client_id => ClientId,
                client_secret => maps:get(client_secret, Cfg, undefined),
                issuer => undefined,
                token_endpoint_auth_method => maps:get(token_endpoint_auth_method, Cfg, undefined)
            };
        _ ->
            undefined
    end.

load_store(#h{store = Store} = H) ->
    H1 =
        case barrel_mcp_client_auth_store:get(Store, client, undefined) of
            undefined -> H;
            Client -> set_client(H, Client)
        end,
    case barrel_mcp_client_auth_store:get(Store, tokens, undefined) of
        undefined ->
            H1;
        Tokens ->
            H1#h{
                access_token = maps:get(access_token, Tokens, undefined),
                refresh_token = maps:get(refresh_token, Tokens, undefined),
                token_endpoint = maps:get(token_endpoint, Tokens, H1#h.token_endpoint),
                granted_scope = maps:get(scope, Tokens, undefined)
            }
    end.

store_client(#h{store = Store, client = Client} = H) ->
    _ = barrel_mcp_client_auth_store:put(Store, client, Client),
    H.

store_tokens(#h{store = Store} = H) ->
    _ = barrel_mcp_client_auth_store:put(Store, tokens, #{
        access_token => H#h.access_token,
        refresh_token => H#h.refresh_token,
        token_endpoint => H#h.token_endpoint,
        scope => H#h.granted_scope
    }),
    H.

%% One parameter of an RFC 6750 challenge, quoted or bare.
www_param(_Name, undefined) ->
    undefined;
www_param(Name, Www) ->
    case re:run(Www, <<Name/binary, "=\"?([^\",]+)\"?">>, [{capture, all_but_first, binary}]) of
        {match, [V]} -> V;
        nomatch -> undefined
    end.

%%====================================================================
%% HTTP helpers
%%====================================================================

%% @doc The HTTPS policy every authorization-server URL passes through:
%% configured, discovered, or the discovery URL itself. Only
%% `allow_insecure_oauth => true' in `Opts' lifts it.
-spec secure_url(binary(), map()) -> ok | {error, {insecure_url, binary()}}.
secure_url(Url, Opts) when is_binary(Url) ->
    case insecure_opt(Opts) of
        true ->
            ok;
        false ->
            case uri_string:parse(Url) of
                #{scheme := <<"https">>} -> ok;
                _ -> {error, {insecure_url, Url}}
            end
    end;
secure_url(Url, _Opts) ->
    {error, {insecure_url, Url}}.

%% Only the literal `true' opts out; anything else is the default.
insecure_opt(Map) ->
    case maps:get(allow_insecure_oauth, Map, false) of
        true -> true;
        _ -> false
    end.

secure_urls([], _Opts) ->
    ok;
secure_urls([Url | Rest], Opts) ->
    case secure_url(Url, Opts) of
        ok -> secure_urls(Rest, Opts);
        {error, _} = Err -> Err
    end.

http_get_json(Url, Opts) ->
    case secure_url(Url, Opts) of
        ok -> do_http_get_json(Url);
        {error, _} = Err -> Err
    end.

do_http_get_json(Url) ->
    %% Discovery endpoints (RFC 9728 / RFC 8414) are typically served
    %% directly under the same origin as the resource. Following
    %% arbitrary cross-origin redirects from an untrusted server
    %% turns these helpers into an SSRF primitive, so we don't.
    case
        hackney:request(
            get,
            Url,
            [{<<"accept">>, <<"application/json">>}],
            <<>>,
            [with_body, {follow_redirect, false}]
        )
    of
        {ok, 200, _Hdrs, Body} ->
            try
                {ok, json:decode(Body)}
            catch
                _:_ -> {error, {invalid_json, Body}}
            end;
        {ok, Status, _Hdrs, _Body} ->
            {error, {http_error, Status}};
        {error, _} = Err ->
            Err
    end.

%% `token_endpoint_auth_method' in `Opts' picks how the secret travels:
%% HTTP Basic (default when there is one), the body, or not at all.
http_post_form(Url, Form, ClientSecret, ClientId, Opts) ->
    case secure_url(Url, Opts) of
        ok ->
            Dpop = maps:get(dpop, Opts, undefined),
            case maps:get(token_endpoint_auth_method, Opts, undefined) of
                client_secret_post ->
                    do_post_form(Url, Form, undefined, ClientId, Dpop);
                none ->
                    do_post_form(
                        Url, maps:remove(<<"client_secret">>, Form), undefined, ClientId, Dpop
                    );
                _ ->
                    do_post_form(
                        Url, maps:remove(<<"client_secret">>, Form), ClientSecret, ClientId, Dpop
                    )
            end;
        {error, _} = Err ->
            Err
    end.

do_post_form(Url, Form, ClientSecret, ClientId, Dpop) when
    is_binary(ClientId),
    ClientId =/= <<>>,
    is_binary(ClientSecret),
    ClientSecret =/= <<>>
->
    %% Confidential client uses HTTP Basic auth and omits client_id
    %% from body per OAuth 2.1.
    Form1 = maps:remove(<<"client_id">>, Form),
    Auth = base64:encode(<<ClientId/binary, ":", ClientSecret/binary>>),
    Headers = [
        {<<"authorization">>, <<"Basic ", Auth/binary>>},
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"accept">>, <<"application/json">>}
    ],
    post_form(Url, Headers, Form1, Dpop, first);
do_post_form(Url, Form, _, _, Dpop) ->
    Headers = [
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"accept">>, <<"application/json">>}
    ],
    post_form(Url, Headers, Form, Dpop, first).

%% With a DPoP key the request carries a proof; a `use_dpop_nonce'
%% answer (RFC 9449 8) is retried once with the nonce the server named,
%% and that nonce rides back on the token response as `dpop_nonce' for
%% the handle to keep.
post_form(Url, Headers, Form, Dpop, Attempt) ->
    Hs =
        case Dpop of
            undefined ->
                Headers;
            {Key, Nonce} ->
                [{<<"dpop">>, dpop_proof(Key, <<"POST">>, Url, Nonce, undefined)} | Headers]
        end,
    Body = urlencode(Form),
    case hackney:request(post, Url, Hs, Body, [with_body]) of
        {ok, 200, _Hdrs, RB} ->
            try json:decode(RB) of
                Map when is_map(Map) ->
                    case Dpop of
                        {_, N} when is_binary(N) -> {ok, Map#{<<"dpop_nonce">> => N}};
                        _ -> {ok, Map}
                    end;
                Other ->
                    {ok, Other}
            catch
                _:_ -> {error, {invalid_json, RB}}
            end;
        {ok, 400, Hdrs, RB} when Dpop =/= undefined, Attempt =:= first ->
            case dpop_nonce_challenge(RB, Hdrs) of
                {ok, NewNonce} ->
                    {Key1, _} = Dpop,
                    post_form(Url, Headers, Form, {Key1, NewNonce}, second);
                error ->
                    {error, {http_error, 400, RB}}
            end;
        {ok, Status, _Hdrs, RB} ->
            {error, {http_error, Status, RB}};
        {error, _} = Err ->
            Err
    end.

dpop_nonce_challenge(Body, Headers) ->
    Nonce = [V || {K, V} <- Headers, string:lowercase(K) =:= <<"dpop-nonce">>],
    case {binary:match(Body, <<"use_dpop_nonce">>), Nonce} of
        {{_, _}, [N | _]} -> {ok, N};
        _ -> error
    end.

%%====================================================================
%% Encoders
%%====================================================================

urlencode(Map) when is_map(Map) ->
    Pairs = lists:map(
        fun({K, V}) -> [pct(K), $=, pct(value(V))] end,
        maps:to_list(Map)
    ),
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
            <<"/">>,
            <<"_">>,
            [global]
        ),
        <<"=">>,
        <<>>,
        [global]
    ).

%% The three grants that accept `private_key_jwt' instead of a secret.
%% `exchange_code/2' and `refresh_token/2' are not among them: they pass
%% their secret unconditionally, and routing them here would give them
%% assertion semantics they never had.
post_token_request(Endpoint, Body0, Optional, Params) ->
    Body = maps:fold(fun add_optional/3, with_assertion(Body0, Params), Optional),
    http_post_form(
        Endpoint,
        Body,
        client_secret(Params),
        maps:get(client_id, Params, undefined),
        Params
    ).

with_assertion(Body, Params) ->
    case maps:get(client_assertion, Params, undefined) of
        undefined ->
            Body;
        JWT when is_binary(JWT) ->
            Body#{
                <<"client_assertion_type">> =>
                    <<"urn:ietf:params:oauth:client-assertion-type:jwt-bearer">>,
                <<"client_assertion">> => JWT
            }
    end.

%% `private_key_jwt' must not also add HTTP Basic (RFC 7523).
client_secret(Params) ->
    case maps:get(client_assertion, Params, undefined) of
        undefined -> maps:get(client_secret, Params, undefined);
        _ -> undefined
    end.

optional_scope_and_resource(Params) ->
    #{
        scope => maps:get(scopes, Params, undefined),
        resource => maps:get(resource, Params, undefined)
    }.

required(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error -> error({missing, Key})
    end.

add_optional(_K, undefined, Acc) -> Acc;
add_optional(K, V, Acc) -> Acc#{atom_to_binary(K, utf8) => V}.

drop_undefined(Map) ->
    maps:filter(fun(_, V) -> V =/= undefined end, Map).
