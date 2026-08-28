%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc MCP request metadata headers (2026-07-28).
%%%
%%% The Streamable HTTP transport mirrors selected JSON-RPC body fields
%%% into HTTP headers so load balancers, gateways and observability
%%% tooling can route and inspect a request without parsing its body:
%%%
%%% <ul>
%%%   <li>`Mcp-Method' — the JSON-RPC `method', on every request.</li>
%%%   <li>`Mcp-Name' — `params.name' or `params.uri', on `tools/call',
%%%       `resources/read' and `prompts/get'.</li>
%%%   <li>`Mcp-Param-{Name}' — tool arguments a server opted into
%%%       mirroring, via `x-mcp-header' in its `inputSchema'.</li>
%%% </ul>
%%%
%%% Because two components may then act on different sources of truth,
%%% a server that reads the body <em>must</em> check that the headers
%%% agree with it, and reject a mismatch with `-32020'. That check is
%%% the reason this module exists, and why encoding is defined so
%%% precisely: both sides have to agree byte for byte.
%%%
%%% This module is pure. The transport decides when to apply it; the
%%% client uses the same functions to build what the server verifies.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_headers).

%% Largest integer JSON round-trips exactly (RFC 8259 section 6).
-define(JSON_SAFE_INTEGER, 9007199254740991).

-include("barrel_mcp.hrl").

%% Value encoding
-export([encode_value/1, decode_value/1, is_safe_value/1]).

%% Header construction (client side)
-export([standard/2, param_headers/2]).

%% Validation (server side)
-export([validate/4]).

%% Schema annotations, shared by the client (which builds the headers)
%% and the registry (which rejects an invalid annotation at
%% registration rather than on every call).
-export([scan_header_params/1]).

%% The sentinel wrapping a Base64 value. Case-sensitive, exactly as
%% written: a value that merely looks like it must be encoded too.
-define(SENTINEL_PREFIX, <<"=?base64?">>).
-define(SENTINEL_SUFFIX, <<"?=">>).

-type header() :: {binary(), binary()}.
-type param_binding() :: {HeaderName :: binary(), Path :: [binary()]}.

-export_type([header/0, param_binding/0]).

%%====================================================================
%% Value encoding
%%====================================================================

%% @doc Render a parameter value as an HTTP header value.
%%
%% Strings pass through when they are safe and are Base64-wrapped
%% otherwise; integers become decimal; booleans become `true' / `false'.
-spec encode_value(binary() | number() | boolean()) -> binary().
encode_value(true) ->
    <<"true">>;
encode_value(false) ->
    <<"false">>;
encode_value(V) when is_integer(V) ->
    integer_to_binary(V);
%% JSON has no integer type, so an integer-typed argument can arrive as
%% a float. Render an integral one as an integer; the server compares
%% numerically either way.
encode_value(V) when is_float(V) ->
    case trunc(V) == V of
        true -> integer_to_binary(trunc(V));
        false -> float_to_binary(V, [short])
    end;
encode_value(V) when is_binary(V) ->
    case is_safe_value(V) of
        true -> V;
        false -> wrap(V)
    end.

wrap(V) ->
    <<?SENTINEL_PREFIX/binary, (base64:encode(V))/binary, ?SENTINEL_SUFFIX/binary>>.

%% @doc Recover the original value from a header.
%%
%% Returns `{error, invalid_encoding}' for a sentinel whose payload is
%% not valid Base64, and for a value carrying bytes a header may not
%% hold. Servers decode before comparing against the body.
-spec decode_value(binary()) -> {ok, binary()} | {error, invalid_encoding}.
decode_value(V) when is_binary(V) ->
    case sentinel_payload(V) of
        {ok, Payload} ->
            try
                {ok, base64:decode(Payload)}
            catch
                _:_ -> {error, invalid_encoding}
            end;
        none ->
            case all_field_chars(V) of
                true -> {ok, V};
                false -> {error, invalid_encoding}
            end
    end.

%% A bound variable in a binary pattern is compared rather than bound
%% again, so the fence and what it wraps come out of one match. A value
%% too short for the fence gives a negative payload size, which fails
%% the match rather than raising.
sentinel_payload(V) ->
    Prefix = ?SENTINEL_PREFIX,
    Suffix = ?SENTINEL_SUFFIX,
    PLen = byte_size(Prefix),
    SLen = byte_size(Suffix),
    case V of
        <<Prefix:PLen/binary, Payload:(byte_size(V) - PLen - SLen)/binary, Suffix:SLen/binary>> ->
            {ok, Payload};
        _ ->
            none
    end.

%% @doc Whether a string can travel as a plain header value.
%%
%% RFC 9110 allows visible ASCII, space and horizontal tab, but a value
%% padded with either would not survive the round trip, and one shaped
%% like the sentinel would be decoded as if it were encoded.
-spec is_safe_value(binary()) -> boolean().
is_safe_value(<<>>) ->
    true;
is_safe_value(V) when is_binary(V) ->
    all_field_chars(V) andalso
        not padded(V) andalso
        sentinel_payload(V) =:= none.

padded(V) ->
    First = binary:first(V),
    Last = binary:last(V),
    is_ows(First) orelse is_ows(Last).

is_ows($\s) -> true;
is_ows($\t) -> true;
is_ows(_) -> false.

all_field_chars(V) ->
    lists:all(fun is_field_char/1, binary_to_list(V)).

is_field_char($\t) -> true;
is_field_char($\s) -> true;
is_field_char(C) -> C >= 16#21 andalso C =< 16#7E.

%%====================================================================
%% Header construction
%%====================================================================

%% @doc The standard headers for a request: `Mcp-Method' always, and
%% `Mcp-Name' for the three methods that name what they act on.
-spec standard(binary(), map()) -> [header()].
standard(Method, Params) when is_binary(Method), is_map(Params) ->
    [{<<"mcp-method">>, Method} | name_header(Method, Params)].

name_header(Method, Params) ->
    case name_field(Method) of
        undefined ->
            [];
        Field ->
            case maps:get(Field, Params, undefined) of
                V when is_binary(V) -> [{<<"mcp-name">>, encode_value(V)}];
                _ -> []
            end
    end.

%% Which body field `Mcp-Name' mirrors, per method.
name_field(<<"tools/call">>) -> <<"name">>;
name_field(<<"prompts/get">>) -> <<"name">>;
name_field(<<"resources/read">>) -> <<"uri">>;
%% The tasks extension mirrors the task id, so an intermediary can route
%% a follow-up to the instance holding that task's state.
name_field(<<"tasks/get">>) -> <<"taskId">>;
name_field(<<"tasks/update">>) -> <<"taskId">>;
name_field(<<"tasks/cancel">>) -> <<"taskId">>;
name_field(_) -> undefined.

%% @doc Mirror the arguments a tool's schema opted into.
%%
%% A binding whose value is absent from the arguments is skipped: the
%% spec has the header omitted rather than sent empty.
-spec param_headers(map(), [param_binding()]) -> [header()].
param_headers(Arguments, Bindings) when is_map(Arguments) ->
    lists:filtermap(
        fun({Name, Path}) ->
            case value_at(Path, Arguments) of
                {ok, V} -> {true, {param_header_name(Name), encode_value(V)}};
                none -> false
            end
        end,
        Bindings
    ).

param_header_name(Name) ->
    <<"mcp-param-", (string:lowercase(Name))/binary>>.

%% Read the instance value at an exact chain of `properties' keys.
%% `null' counts as absent: the spec has the header omitted for it.
%% Floats are accepted because JSON does not distinguish them from
%% integers, not because `number' is a permitted annotation target.
value_at([], V) when is_integer(V) ->
    %% Outside the JSON safe range the two ends do not agree on the
    %% value, so there is nothing a mirrored header could prove.
    case V >= -?JSON_SAFE_INTEGER andalso V =< ?JSON_SAFE_INTEGER of
        true -> {ok, V};
        false -> none
    end;
value_at([], V) when is_binary(V); is_float(V); is_boolean(V) ->
    {ok, V};
value_at([], _V) ->
    none;
value_at([Key | Rest], Map) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Sub} -> value_at(Rest, Sub);
        error -> none
    end;
value_at(_Path, _Other) ->
    none.

%%====================================================================
%% Validation
%%====================================================================

%% @doc Check that the headers agree with the body.
%%
%% `Bindings' are the tool's `x-mcp-header' annotations, empty for
%% anything that is not a `tools/call'. Returns the message for a
%% `-32020' error when they disagree.
-spec validate(
    [header()],
    binary(),
    map(),
    [param_binding()]
) -> ok | {error, binary()}.
validate(Headers, Method, Params, Bindings) ->
    Checks = [
        fun() -> check_method(Headers, Method) end,
        fun() -> check_name(Headers, Method, Params) end,
        fun() -> check_params(Headers, Params, Bindings) end
    ],
    run_checks(Checks).

run_checks([]) ->
    ok;
run_checks([Check | Rest]) ->
    case Check() of
        ok -> run_checks(Rest);
        {error, _} = Err -> Err
    end.

check_method(Headers, Method) ->
    case header(<<"mcp-method">>, Headers) of
        undefined ->
            {error, <<"Header mismatch: Mcp-Method header is required">>};
        Method ->
            ok;
        Other ->
            {error, mismatch_message(<<"Mcp-Method">>, Other, Method)}
    end.

check_name(Headers, Method, Params) ->
    case name_field(Method) of
        undefined ->
            ok;
        Field ->
            Expected = maps:get(Field, Params, undefined),
            compare(<<"Mcp-Name">>, header(<<"mcp-name">>, Headers), Expected)
    end.

check_params(Headers, Params, Bindings) ->
    Arguments = maps:get(<<"arguments">>, Params, #{}),
    run_checks([
        fun() ->
            Header = header(param_header_name(Name), Headers),
            Expected =
                case value_at(Path, Arguments) of
                    {ok, V} -> V;
                    none -> undefined
                end,
            compare(<<"Mcp-Param-", Name/binary>>, Header, Expected)
        end
     || {Name, Path} <- Bindings
    ]).

%% Absent on both sides is agreement; absent on one is not.
compare(_Label, undefined, undefined) ->
    ok;
compare(Label, undefined, _Expected) ->
    {error, <<"Header mismatch: ", Label/binary, " header is required">>};
compare(Label, Raw, undefined) ->
    {error,
        <<"Header mismatch: ", Label/binary, " header '", Raw/binary,
            "' has no matching body value">>};
compare(Label, Raw, Expected) ->
    case decode_value(Raw) of
        {error, invalid_encoding} ->
            {error, <<"Header mismatch: ", Label/binary, " header is malformed">>};
        {ok, Decoded} ->
            case matches(Decoded, Expected) of
                true -> ok;
                false -> {error, mismatch_message(Label, Decoded, Expected)}
            end
    end.

mismatch_message(Label, Got, Expected) ->
    <<"Header mismatch: ", Label/binary, " header value '", (to_text(Got))/binary,
        "' does not match body value '", (to_text(Expected))/binary, "'">>.

%% Numbers compare numerically, so 42 and 42.0 agree; everything else
%% compares as the text it travelled as.
matches(Decoded, Expected) when is_number(Expected) ->
    case to_number(Decoded) of
        {ok, N} -> N == Expected;
        error -> false
    end;
matches(Decoded, Expected) when is_boolean(Expected) ->
    Decoded =:= atom_to_binary(Expected, utf8);
matches(Decoded, Expected) when is_binary(Expected) ->
    Decoded =:= Expected;
matches(_Decoded, _Expected) ->
    false.

to_number(Bin) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        _:_ ->
            try
                {ok, binary_to_float(Bin)}
            catch
                _:_ -> error
            end
    end.

to_text(V) when is_binary(V) -> V;
to_text(V) when is_integer(V) -> integer_to_binary(V);
to_text(V) when is_float(V) -> float_to_binary(V, [short]);
to_text(V) when is_boolean(V) -> atom_to_binary(V, utf8);
to_text(undefined) -> <<"(absent)">>;
to_text(V) -> iolist_to_binary(io_lib:format("~p", [V])).

header(Name, Headers) ->
    Lower = string:lowercase(Name),
    case lists:search(fun({K, _}) -> string:lowercase(to_binary(K)) =:= Lower end, Headers) of
        {value, {_, V}} -> to_binary(V);
        false -> undefined
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> iolist_to_binary(L).

%%====================================================================
%% `x-mcp-header' annotations
%%====================================================================

%% @doc Collect the `x-mcp-header' bindings from a tool's `inputSchema'.
%%
%% A binding is only valid on a property reachable from the schema root
%% through a chain of `properties' keys alone. Anything behind `items',
%% a composition or conditional keyword, or a `$ref' has no single
%% instance path, so a header could not be derived from it
%% unambiguously. Such an annotation invalidates the whole tool
%% definition rather than being ignored, so the failure surfaces at
%% registration instead of on some later call.
-spec scan_header_params(map()) ->
    {ok, [param_binding()]} | {error, term()}.
scan_header_params(Schema) when is_map(Schema) ->
    case collect(Schema, [], []) of
        {error, _} = Err ->
            Err;
        {ok, Bindings} ->
            case duplicate_name(Bindings) of
                undefined -> {ok, lists:reverse(Bindings)};
                Name -> {error, {duplicate_x_mcp_header, Name}}
            end
    end;
scan_header_params(_Schema) ->
    {ok, []}.

collect(Schema, Path, Acc) ->
    case reject_nested_annotation(Schema) of
        {error, _} = Err ->
            Err;
        ok ->
            Properties = maps:get(<<"properties">>, Schema, #{}),
            case is_map(Properties) of
                false -> {ok, Acc};
                true -> collect_properties(maps:to_list(Properties), Path, Acc)
            end
    end.

collect_properties([], _Path, Acc) ->
    {ok, Acc};
collect_properties([{Key, Sub} | Rest], Path, Acc) when is_map(Sub) ->
    SubPath = Path ++ [Key],
    case binding_of(Sub, SubPath) of
        {error, _} = Err ->
            Err;
        {ok, none} ->
            case collect(Sub, SubPath, Acc) of
                {error, _} = Err -> Err;
                {ok, Acc1} -> collect_properties(Rest, Path, Acc1)
            end;
        {ok, Binding} ->
            case collect(Sub, SubPath, [Binding | Acc]) of
                {error, _} = Err -> Err;
                {ok, Acc1} -> collect_properties(Rest, Path, Acc1)
            end
    end;
collect_properties([_ | Rest], Path, Acc) ->
    collect_properties(Rest, Path, Acc).

binding_of(Sub, SubPath) ->
    case maps:get(<<"x-mcp-header">>, Sub, undefined) of
        undefined ->
            {ok, none};
        Name when is_binary(Name), is_map_key(<<"$ref">>, Sub) ->
            %% A `$ref' is an opaque pointer. Whatever it resolves to may
            %% not be a primitive, and we would be binding a header to a
            %% type we never looked at.
            {error, {x_mcp_header_on_ref, Name}};
        Name when is_binary(Name) ->
            case valid_name(Name) of
                false ->
                    {error, {invalid_x_mcp_header, Name}};
                true ->
                    case primitive_type(maps:get(<<"type">>, Sub, undefined)) of
                        true -> {ok, {Name, SubPath}};
                        false -> {error, {x_mcp_header_on_non_primitive, Name}}
                    end
            end;
        Other ->
            {error, {invalid_x_mcp_header, Other}}
    end.

%% `number' is excluded on purpose: its text form is not canonical, so
%% a header and a body value could not be compared reliably.
primitive_type(<<"string">>) -> true;
primitive_type(<<"integer">>) -> true;
primitive_type(<<"boolean">>) -> true;
primitive_type(_) -> false.

valid_name(<<>>) ->
    false;
valid_name(Name) ->
    lists:all(fun is_tchar/1, binary_to_list(Name)).

%% tchar, RFC 9110 section 5.6.2.
is_tchar(C) when C >= $a, C =< $z -> true;
is_tchar(C) when C >= $A, C =< $Z -> true;
is_tchar(C) when C >= $0, C =< $9 -> true;
is_tchar(C) -> lists:member(C, "!#$%&'*+-.^_`|~").

%% Keywords whose subschemas have no single instance path. An
%% annotation anywhere under one of them is invalid.
-define(OPAQUE_KEYWORDS, [
    <<"items">>,
    <<"prefixItems">>,
    <<"additionalProperties">>,
    <<"patternProperties">>,
    <<"contains">>,
    <<"oneOf">>,
    <<"anyOf">>,
    <<"allOf">>,
    <<"not">>,
    <<"if">>,
    <<"then">>,
    <<"else">>,
    <<"$defs">>,
    <<"definitions">>
]).

reject_nested_annotation(Schema) ->
    Subschemas = [maps:get(K, Schema, undefined) || K <- ?OPAQUE_KEYWORDS],
    case lists:any(fun has_annotation/1, Subschemas) of
        true -> {error, x_mcp_header_not_statically_reachable};
        false -> ok
    end.

has_annotation(undefined) ->
    false;
has_annotation(Map) when is_map(Map) ->
    maps:is_key(<<"x-mcp-header">>, Map) orelse
        lists:any(fun has_annotation/1, maps:values(Map));
has_annotation(List) when is_list(List) ->
    lists:any(fun has_annotation/1, List);
has_annotation(_) ->
    false.

duplicate_name(Bindings) ->
    Names = [string:lowercase(N) || {N, _} <- Bindings],
    case Names -- lists:usort(Names) of
        [] -> undefined;
        [Dup | _] -> Dup
    end.
