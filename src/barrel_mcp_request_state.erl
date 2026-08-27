%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Opaque, integrity-protected request state for MRTR.
%%%
%%% Under Multi Round-Trip Requests a server that needs more input
%%% answers with an `InputRequiredResult' and finishes the request. The
%%% client then retries, echoing back a `requestState' string. That is
%%% how the server picks up where it left off without keeping anything
%%% server-side, which is what lets a retry land on a different node.
%%%
%%% The catch is that the state travels through the client, so it is
%%% attacker-controlled input by construction. The spec requires
%%% integrity protection and rejection of state that fails
%%% verification. This module seals a term into a blob authenticated
%%% with HMAC-SHA256, bound to:
%%%
%%% <ul>
%%%   <li>the authenticated principal, so one caller cannot present
%%%       another's state;</li>
%%%   <li>an expiry, so a captured blob is not useful indefinitely;</li>
%%%   <li>the originating method and its salient parameters, so state
%%%       from one call cannot be replayed onto a different one.</li>
%%% </ul>
%%%
%%% These bound the replay window and stop cross-user and cross-request
%%% reuse. They do not make a blob single-use: a server that needs
%%% that (a one-time redemption, say) has to enforce it itself.
%%%
%%% == The signing key ==
%%%
%%% From the `request_state_key' environment variable. Without one, an
%%% ephemeral key is generated per node, which is fine for a single
%%% node and wrong for a cluster: a retry landing on another node fails
%%% verification. A warning is logged once so that is not discovered in
%%% production.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_request_state).

-export([seal/2, unseal/2, binding/3]).

%% Exported for the application start-up, which seeds the ephemeral key
%% before any request can race for it.
-export([ensure_key/0]).

-define(KEY_TERM, barrel_mcp_request_state_key).
-define(VERSION, 1).
-define(DEFAULT_TTL_MS, 300000).
%% A blob is a base64 string we produced; anything of this size is not
%% one, and decoding it would only waste memory.
-define(MAX_BLOB_BYTES, 65536).

-type binding() :: #{
    principal := term(),
    method := binary(),
    params := map()
}.

-type reason() :: invalid | expired | principal_mismatch | request_mismatch.

-export_type([binding/0, reason/0]).

%%====================================================================
%% API
%%====================================================================

%% @doc Describe what a piece of state is allowed to be replayed onto.
%%
%% `Params' is the request's params as they arrived. The fields a retry
%% legitimately adds are excluded from the digest, so echoing state
%% back with `inputResponses' filled in still matches.
-spec binding(term(), binary(), map()) -> binding().
binding(Principal, Method, Params) ->
    #{principal => Principal, method => Method, params => Params}.

%% @doc Seal a term into an opaque blob for the client to echo back.
-spec seal(term(), binding()) -> binary().
seal(Term, Binding) ->
    Payload = term_to_binary(#{
        exp => erlang:system_time(millisecond) + ttl_ms(),
        principal => principal_digest(Binding),
        request => request_digest(Binding),
        state => Term
    }),
    Signed = <<?VERSION:8, Payload/binary>>,
    Mac = crypto:mac(hmac, sha256, ensure_key(), Signed),
    base64:encode(<<Mac:32/binary, Signed/binary>>).

%% @doc Recover a sealed term, or say why it cannot be trusted.
%%
%% The MAC is checked before anything is deserialised, so a forged blob
%% never reaches `binary_to_term/2'.
-spec unseal(binary(), binding()) -> {ok, term()} | {error, reason()}.
unseal(Blob, _Binding) when not is_binary(Blob) ->
    {error, invalid};
unseal(Blob, _Binding) when byte_size(Blob) > ?MAX_BLOB_BYTES ->
    {error, invalid};
unseal(Blob, Binding) ->
    case decode(Blob) of
        {ok, Mac, Signed} ->
            Expected = crypto:mac(hmac, sha256, ensure_key(), Signed),
            case crypto:hash_equals(Mac, Expected) of
                true -> verify_payload(Signed, Binding);
                false -> {error, invalid}
            end;
        error ->
            {error, invalid}
    end.

decode(Blob) ->
    try base64:decode(Blob) of
        <<Mac:32/binary, Signed/binary>> when byte_size(Signed) > 0 ->
            {ok, Mac, Signed};
        _ ->
            error
    catch
        _:_ -> error
    end.

%% Only reached once the MAC has been verified, so the payload is one
%% we produced. `safe' still applies: it costs nothing and keeps a
%% future format change from being a decoding hazard.
verify_payload(<<?VERSION:8, Payload/binary>>, Binding) ->
    try binary_to_term(Payload, [safe]) of
        #{exp := Exp, principal := P, request := R, state := Term} ->
            check(Exp, P, R, Term, Binding);
        _ ->
            {error, invalid}
    catch
        _:_ -> {error, invalid}
    end;
verify_payload(_Other, _Binding) ->
    %% A version we do not know, most likely a blob from an older or
    %% newer release. Not forged, but not usable either.
    {error, invalid}.

check(Exp, Principal, Request, Term, Binding) ->
    case erlang:system_time(millisecond) > Exp of
        true -> {error, expired};
        false -> check_bindings(Principal, Request, Term, Binding)
    end.

check_bindings(Principal, Request, Term, Binding) ->
    case crypto:hash_equals(Principal, principal_digest(Binding)) of
        false ->
            {error, principal_mismatch};
        true ->
            case crypto:hash_equals(Request, request_digest(Binding)) of
                true -> {ok, Term};
                false -> {error, request_mismatch}
            end
    end.

%%====================================================================
%% Digests
%%====================================================================

principal_digest(#{principal := Principal}) ->
    crypto:hash(sha256, canonical(Principal)).

%% The method plus the parameters that identify the call. `_meta'
%% varies between attempts (a progress token need not be reused) and
%% the MRTR fields are what a retry adds, so none of them can be part
%% of what makes two attempts the same request.
request_digest(#{method := Method, params := Params}) ->
    Salient = maps:without(
        [<<"_meta">>, <<"inputResponses">>, <<"requestState">>],
        params_map(Params)
    ),
    crypto:hash(sha256, canonical({Method, Salient})).

params_map(P) when is_map(P) -> P;
params_map(_) -> #{}.

%% Maps have no guaranteed serialisation order, so they are flattened
%% into sorted key/value lists before hashing. Two equal requests must
%% digest identically whatever order their keys arrived in.
canonical(Term) ->
    term_to_binary(canonicalize(Term)).

canonicalize(Map) when is_map(Map) ->
    {canonical_map, lists:sort([{K, canonicalize(V)} || {K, V} <- maps:to_list(Map)])};
canonicalize(List) when is_list(List) ->
    [canonicalize(E) || E <- List];
canonicalize(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([canonicalize(E) || E <- tuple_to_list(Tuple)]);
canonicalize(Other) ->
    Other.

%%====================================================================
%% Key
%%====================================================================

ttl_ms() ->
    application:get_env(barrel_mcp, request_state_ttl_ms, ?DEFAULT_TTL_MS).

%% @doc Return the signing key, generating an ephemeral one if none is
%% configured. Called at application start so that generation cannot
%% race between concurrent requests.
-spec ensure_key() -> binary().
ensure_key() ->
    case application:get_env(barrel_mcp, request_state_key, undefined) of
        Key when is_binary(Key), byte_size(Key) > 0 ->
            Key;
        _ ->
            ephemeral_key()
    end.

ephemeral_key() ->
    case persistent_term:get(?KEY_TERM, undefined) of
        undefined ->
            Key = crypto:strong_rand_bytes(32),
            persistent_term:put(?KEY_TERM, Key),
            logger:warning(
                "barrel_mcp: no request_state_key configured, using an "
                "ephemeral key. MRTR retries will fail after a restart, "
                "and on any other node. Configure request_state_key for "
                "anything beyond a single-node deployment."
            ),
            persistent_term:get(?KEY_TERM, Key);
        Key ->
            Key
    end.
