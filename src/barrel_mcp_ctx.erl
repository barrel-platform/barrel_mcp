%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Per-request context.
%%%
%%% MCP 2026-07-28 made the protocol stateless: a request carries its
%%% own protocol version, client capabilities and identity in `_meta'
%%% instead of inheriting them from an `initialize' handshake. This
%%% module builds one context per request from the decoded JSON-RPC
%%% envelope and answers questions about it, so nothing else in the
%%% library has to reach into `_meta' by hand.
%%%
%%% Every request belongs to one of two eras:
%%%
%%% <ul>
%%%   <li>`modern': `params._meta' carries
%%%       `io.modelcontextprotocol/protocolVersion'. Stateless, no
%%%       session.</li>
%%%   <li>`legacy': everything else, including every `initialize'.
%%%       Version and capabilities live on the session and are supplied
%%%       by the transport through `Extra'.</li>
%%% </ul>
%%%
%%% Building a context never fails, so a malformed request still yields
%%% something the caller can inspect. Use {@link validate/1} to check
%%% that a modern request carries the `_meta' fields the spec requires.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_ctx).

-include("barrel_mcp.hrl").

-export([
    from_request/1,
    from_request/2,
    validate/1,
    validate_version/1,
    era/1,
    is_modern/1,
    protocol_version/1,
    client_info/1,
    client_capabilities/1,
    supports/2,
    supports_extension/2,
    elicitation_modes/1,
    log_level/1,
    input_responses/1,
    input_response/2,
    request_state/1,
    session_id/1,
    auth_info/1,
    principal/1,
    streaming/1,
    meta/1
]).

-type era() :: modern | legacy.

%% The transport supplies what it knows out of band: the session id,
%% the authenticated principal, whether it can hold a response stream
%% open, and (legacy only) the version and capabilities recorded on the
%% session at `initialize'.
-type extra() :: #{
    session_id => binary() | undefined,
    auth_info => term(),
    streaming => boolean(),
    protocol_version => binary() | undefined,
    client_capabilities => map(),
    %% The revision the transport itself declares for this request, from
    %% `MCP-Protocol-Version'. Used only to decide the era.
    transport_version => binary() | undefined
}.

-type ctx() :: #{
    era := era(),
    protocol_version := binary() | undefined,
    client_info := map() | undefined,
    client_capabilities := map(),
    log_level := binary() | undefined,
    input_responses := map(),
    request_state := binary() | undefined,
    session_id := binary() | undefined,
    auth_info := term(),
    streaming := boolean(),
    meta := map()
}.

-export_type([ctx/0, era/0, extra/0]).

%%====================================================================
%% Construction
%%====================================================================

%% @equiv from_request(Request, #{})
-spec from_request(map()) -> ctx().
from_request(Request) ->
    from_request(Request, #{}).

%% @doc Build the context for one decoded JSON-RPC request or
%% notification. Never fails.
-spec from_request(map(), extra()) -> ctx().
from_request(Request, Extra) when is_map(Request), is_map(Extra) ->
    Method = maps:get(<<"method">>, Request, undefined),
    Params = as_map(maps:get(<<"params">>, Request, #{})),
    Meta = as_map(maps:get(<<"_meta">>, Params, #{})),
    Era = classify(Method, Meta, maps:get(transport_version, Extra, undefined)),
    #{
        era => Era,
        protocol_version => version_of(Era, Meta, Extra),
        client_info => as_map_or_undefined(
            maps:get(?MCP_META_CLIENT_INFO, Meta, undefined)
        ),
        client_capabilities => capabilities_of(Era, Meta, Extra),
        log_level => as_binary_or_undefined(
            maps:get(?MCP_META_LOG_LEVEL, Meta, undefined)
        ),
        input_responses => as_map(maps:get(<<"inputResponses">>, Params, #{})),
        request_state => as_binary_or_undefined(
            maps:get(<<"requestState">>, Params, undefined)
        ),
        session_id => maps:get(session_id, Extra, undefined),
        auth_info => maps:get(auth_info, Extra, undefined),
        streaming => as_boolean(maps:get(streaming, Extra, false)),
        meta => Meta
    }.

%% Either signal puts a request in the modern era: the `_meta' key it
%% carries, or the revision the transport declares for it. Taking only
%% the first would answer a request headed `2026-07-28' with no `_meta'
%% on the legacy path, where the version it named is not in the
%% supported list, and tell the peer we do not speak a revision we do.
%%
%% `initialize' is a legacy handshake by definition, but it does not
%% exist in a modern revision, so a transport declaring one leaves no
%% method to run.
classify(<<"initialize">>, _Meta, Transport) ->
    case is_modern_version(Transport) of
        true -> modern;
        false -> legacy
    end;
classify(_Method, Meta, Transport) ->
    case maps:is_key(?MCP_META_PROTOCOL_VERSION, Meta) orelse is_modern_version(Transport) of
        true -> modern;
        false -> legacy
    end.

is_modern_version(Version) when is_binary(Version) ->
    barrel_mcp_version:era(Version) =:= modern;
is_modern_version(_Version) ->
    false.

version_of(modern, Meta, Extra) ->
    case as_binary_or_undefined(maps:get(?MCP_META_PROTOCOL_VERSION, Meta, undefined)) of
        undefined -> as_binary_or_undefined(maps:get(transport_version, Extra, undefined));
        Version -> Version
    end;
version_of(legacy, _Meta, Extra) ->
    as_binary_or_undefined(maps:get(protocol_version, Extra, undefined)).

capabilities_of(modern, Meta, _Extra) ->
    as_map(maps:get(?MCP_META_CLIENT_CAPABILITIES, Meta, #{}));
capabilities_of(legacy, _Meta, Extra) ->
    as_map(maps:get(client_capabilities, Extra, #{})).

%%====================================================================
%% Validation
%%====================================================================

%% @doc Check the stated revision on its own, before anything is judged
%% against it. A peer naming a revision we do not speak may legitimately
%% carry a `_meta' shape we would misjudge, so the version error has to
%% win; but a version that is absent or not a string is a `_meta'
%% problem, and answering "unsupported version: undefined" names the
%% wrong one.
-spec validate_version(ctx()) ->
    ok | {error, {missing_meta, binary()}} | {error, {invalid_meta, binary()}}.
validate_version(#{era := legacy}) ->
    ok;
validate_version(#{era := modern, meta := Meta}) ->
    case maps:find(?MCP_META_PROTOCOL_VERSION, Meta) of
        error -> {error, {missing_meta, ?MCP_META_PROTOCOL_VERSION}};
        {ok, Version} when is_binary(Version) -> ok;
        {ok, _} -> {error, {invalid_meta, ?MCP_META_PROTOCOL_VERSION}}
    end.

%% @doc Check that a modern request carries the `_meta' fields the spec
%% marks required, and that the optional ones it does carry are usable.
%% A failure is malformed params and the caller must reject it with
%% `?JSONRPC_INVALID_PARAMS' (HTTP 400).
%%
%% Legacy requests carry no such requirement and always pass.
-spec validate(ctx()) ->
    ok | {error, {missing_meta, binary()}} | {error, {invalid_meta, binary()}}.
validate(#{era := legacy}) ->
    ok;
validate(#{era := modern, meta := Meta}) ->
    case maps:is_key(?MCP_META_CLIENT_CAPABILITIES, Meta) of
        false -> {error, {missing_meta, ?MCP_META_CLIENT_CAPABILITIES}};
        true -> validate_types(Meta)
    end.

%% Presence is not enough. `clientCapabilities: 42' was coerced to an
%% empty map and accepted, which reads as a client declaring nothing
%% rather than as the malformed request it is.
validate_types(Meta) ->
    Typed = [
        {?MCP_META_CLIENT_CAPABILITIES, fun is_map/1},
        {?MCP_META_CLIENT_INFO, fun is_map/1}
    ],
    Bad = [
        K
     || {K, Ok} <- Typed,
        maps:is_key(K, Meta),
        not Ok(maps:get(K, Meta))
    ],
    case Bad of
        [] -> validate_log_level(Meta);
        [Key | _] -> {error, {invalid_meta, Key}}
    end.

%% An unrecognised `io.modelcontextprotocol/logLevel' "SHOULD" be
%% rejected with -32602 (2026-07-28/server/utilities/logging.mdx:100).
%% Absent means the request opted out.
validate_log_level(Meta) ->
    case maps:find(?MCP_META_LOG_LEVEL, Meta) of
        error ->
            ok;
        {ok, Level} when is_binary(Level) ->
            case barrel_mcp_session:log_level_priority(Level) of
                error -> {error, {invalid_meta, ?MCP_META_LOG_LEVEL}};
                _ -> ok
            end;
        {ok, _} ->
            {error, {invalid_meta, ?MCP_META_LOG_LEVEL}}
    end.

%%====================================================================
%% Accessors
%%====================================================================

%% @doc Which era this request belongs to.
-spec era(ctx()) -> era().
era(#{era := Era}) -> Era.

%% @doc Whether this request uses per-request metadata (2026-07-28+).
-spec is_modern(ctx()) -> boolean().
is_modern(#{era := Era}) -> Era =:= modern.

%% @doc Protocol version for this request. `undefined' for a legacy
%% request whose session has not recorded one yet.
-spec protocol_version(ctx()) -> binary() | undefined.
protocol_version(#{protocol_version := V}) -> V.

%% @doc The client's self-reported name and version, or `undefined'.
%% Self-reported and unverified: use it for display and logging, never
%% for security decisions.
-spec client_info(ctx()) -> map() | undefined.
client_info(#{client_info := I}) -> I.

%% @doc Capabilities the client declared for this request.
-spec client_capabilities(ctx()) -> map().
client_capabilities(#{client_capabilities := C}) -> C.

%% @doc Whether the client declared a core capability, e.g.
%% `elicitation', `sampling' or `roots'. A server must not ask for
%% something the client did not declare.
-spec supports(ctx(), atom() | binary()) -> boolean().
supports(Ctx, Feature) ->
    maps:is_key(to_binary(Feature), client_capabilities(Ctx)).

%% @doc The elicitation modes this client declared. "An empty
%% capabilities object is equivalent to declaring support for `form'
%% mode only" (2026-07-28/client/elicitation.mdx:67).
-spec elicitation_modes(ctx()) -> [binary()].
elicitation_modes(Ctx) ->
    case maps:get(<<"elicitation">>, client_capabilities(Ctx), undefined) of
        Declared when is_map(Declared), map_size(Declared) > 0 ->
            [M || M <- [<<"form">>, <<"url">>], maps:is_key(M, Declared)];
        _ ->
            [<<"form">>]
    end.

%% @doc Whether the client declared an extension, by identifier
%% (e.g. `?MCP_EXT_TASKS').
-spec supports_extension(ctx(), binary()) -> boolean().
supports_extension(Ctx, Id) when is_binary(Id) ->
    Extensions = as_map(maps:get(<<"extensions">>, client_capabilities(Ctx), #{})),
    maps:is_key(Id, Extensions).

%% @doc Minimum log level the server should emit for this request, or
%% `undefined'. When it is `undefined' the server must emit no
%% `notifications/message' at all for this request.
-spec log_level(ctx()) -> binary() | undefined.
log_level(#{log_level := L}) -> L.

%% @doc Every response the client supplied on an MRTR retry, keyed by
%% the identifiers the server assigned in `inputRequests'.
-spec input_responses(ctx()) -> map().
input_responses(#{input_responses := R}) -> R.

%% @doc One MRTR response by key, raw as it arrived.
-spec input_response(ctx(), binary()) -> {ok, map()} | none.
input_response(Ctx, Key) ->
    case maps:get(Key, input_responses(Ctx), undefined) of
        V when is_map(V) -> {ok, V};
        _ -> none
    end.

%% @doc The opaque MRTR state the client echoed back, still signed.
%% Callers verify it through `barrel_mcp_request_state' rather than
%% reading it here.
-spec request_state(ctx()) -> binary() | undefined.
request_state(#{request_state := S}) -> S.

%% @doc Session this request belongs to, or `undefined'. Always
%% `undefined' for a modern request: the era has no sessions.
-spec session_id(ctx()) -> binary() | undefined.
session_id(#{session_id := S}) -> S.

%% @doc The authenticated principal, as returned by the auth provider.
-spec auth_info(ctx()) -> term().
auth_info(#{auth_info := A}) -> A.

%% @doc The stable identity behind the credential, as
%% `barrel_mcp_auth:authenticate/3' derived it.
%%
%% This is what owns a task, a sealed request state or an elicitation,
%% never the whole `auth_info()' map: that carries `exp' and `jti', so a
%% refreshed token would read as a different caller and orphan whatever
%% was started under the old one.
%%
%% `anonymous' when the request carried no credential at all.
-spec principal(ctx()) -> term().
principal(#{auth_info := A}) when is_map(A) ->
    maps:get(principal, A, anonymous);
principal(_Ctx) ->
    anonymous.

%% @doc Whether the transport can hold a response stream open.
%%
%% `false' unless the transport says otherwise, because most cannot:
%% stdio has one output channel and the plain HTTP transport answers
%% once. Only the Streamable HTTP engine sets it. A method that needs a
%% long-lived response is method-not-found without it, rather than
%% something the transport is handed and cannot serve.
-spec streaming(ctx()) -> boolean().
streaming(#{streaming := S}) -> S.

%% @doc The raw `params._meta' map, for callers that need a key this
%% module does not expose (progress tokens, trace context, extensions).
-spec meta(ctx()) -> map().
meta(#{meta := M}) -> M.

%%====================================================================
%% Internal
%%====================================================================

%% A peer can put anything on the wire, so every field is coerced
%% rather than matched: a malformed `_meta' must not crash the decode.
as_map(M) when is_map(M) -> M;
as_map(_) -> #{}.

as_map_or_undefined(M) when is_map(M) -> M;
as_map_or_undefined(_) -> undefined.

as_binary_or_undefined(B) when is_binary(B) -> B;
as_binary_or_undefined(_) -> undefined.

as_boolean(true) -> true;
as_boolean(_) -> false.

to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(B) when is_binary(B) -> B.
