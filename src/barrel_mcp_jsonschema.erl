%%%-------------------------------------------------------------------
%%% @doc JSON Schema 2020-12 validator.
%%%
%%% MCP describes tool inputs and outputs with 2020-12 schemas, so a
%%% subset validator either rejects valid data or accepts invalid data
%%% depending on which keyword it skipped. This implements the dialect:
%%% every assertion keyword, `$ref'/`$defs'/`$anchor', the dynamic pair,
%%% and the `unevaluated*' keywords that need annotations to answer.
%%%
%%% == Two phases ==
%%%
%%% {@link compile/1} resolves identifiers and references once and
%%% returns something {@link validate/2} can run repeatedly. A schema
%%% that cannot be resolved is rejected there rather than failing
%%% halfway through a validation.
%%%
%%% == No network ==
%%%
%%% A `$ref' to an absolute URI we were not given is an error, never a
%%% fetch. Supply such documents through {@link compile/2}'s registry.
%%% This is a MUST in the spec, and it is also what stops a schema from
%%% turning into an outbound request.
%%%
%%% == Bounds ==
%%%
%%% Depth, subschema count and reference expansions are capped, so a
%%% hostile schema cannot spend the caller's stack or time.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_jsonschema).

-export([compile/1, compile/2, validate/2, validate/3, is_valid_schema/1]).
-export([metaschema/0, validate_schema/1]).

-define(DEFAULT_MAX_DEPTH, 64).
-define(DEFAULT_MAX_SUBSCHEMAS, 10000).
-define(DEFAULT_MAX_EXPANSIONS, 10000).

-define(DIALECT, <<"https://json-schema.org/draft/2020-12/schema">>).

%% `ids' is keyed two ways: an absolute URI for `$id' and `$anchor', and
%% a `{dynamic, Name, Uri}' tuple for `$dynamicAnchor'. They are kept
%% apart because only the second takes part in dynamic resolution.
-type id_key() :: binary() | {dynamic, binary(), binary()}.

-record(schema, {
    root :: term(),
    ids = #{} :: #{id_key() => term()},
    %% `$dynamicAnchor' name -> [absolute URI], outermost first.
    dynamic = #{} :: #{binary() => [binary()]},
    base :: binary()
}).

-opaque schema() :: #schema{}.
-export_type([schema/0]).

-type path() :: [binary() | non_neg_integer()].
-type error() :: {path(), atom() | {atom(), term()}}.
-export_type([error/0]).

%% What a run carries: the compiled schema, the dynamic scope, and the
%% budget left.
-record(ctx, {
    schema :: #schema{},
    %% Innermost-first list of base URIs currently in scope, for
    %% `$dynamicRef'.
    scope = [] :: [binary()],
    depth = 0 :: non_neg_integer(),
    budget :: counters:counters_ref()
}).

%%====================================================================
%% Compilation
%%====================================================================

%% @equiv compile(Schema, #{})
-spec compile(term()) -> {ok, schema()} | {error, term()}.
compile(Schema) ->
    compile(Schema, #{}).

%% @doc Resolve a schema's identifiers and check every reference.
%%
%% `Registry' maps absolute URIs to schema documents, for the `$ref's
%% that name something outside this one. Anything not in it is an error:
%% nothing is fetched.
-spec compile(term(), #{binary() => term()}) -> {ok, schema()} | {error, term()}.
compile(Schema, Registry0) when is_map(Registry0) ->
    try
        %% The dialect's own documents are always available: a schema
        %% that references them is referencing something we ship, not
        %% something to fetch.
        Registry = maps:merge(metaschema_documents(), Registry0),
        Base = base_of(Schema),
        Ids0 = maps:fold(
            fun(Uri, Doc, Acc) ->
                %% Under the URI it was supplied as, as well as under
                %% whatever `$id' it carries: a document is reachable by
                %% the name the caller gave it.
                collect(Doc, Uri, Acc#{Uri => Doc})
            end,
            #{},
            Registry
        ),
        Ids = collect(Schema, Base, Ids0),
        ok = check_dialect(Schema, Ids),
        Dynamic = collect_dynamic(Ids),
        Compiled = #schema{root = Schema, ids = Ids, dynamic = Dynamic, base = Base},
        ok = check_refs(Schema, Base, Compiled),
        {ok, Compiled}
    catch
        error:{schema_error, Reason} -> {error, Reason}
    end.

%% @doc Whether this is a schema we can run at all. Used where a schema
%% is accepted from outside and has to be refused early.
-spec is_valid_schema(term()) -> boolean().
is_valid_schema(Schema) ->
    case compile(Schema) of
        {ok, _} -> true;
        {error, _} -> false
    end.

%% "Clients and servers MUST validate schemas according to their
%% declared or default dialect. They MUST handle unsupported dialects
%% gracefully by returning an appropriate error indicating the dialect
%% is not supported" (2026-07-28/basic/index.mdx:292).
%%
%% Supported means 2020-12, or a metaschema the caller supplied: a
%% custom metaschema built on these vocabularies is still this dialect,
%% and refusing it would refuse something we can in fact evaluate. An
%% earlier draft is neither, and validating it here would apply the
%% wrong rules to `items', `exclusiveMinimum' and `definitions'.
%%
%% Only the root of the schema being compiled. A registry entry is a
%% reference target rather than something we were asked to validate.
check_dialect(Schema, Ids) when is_map(Schema) ->
    case maps:get(<<"$schema">>, Schema, undefined) of
        undefined -> ok;
        Uri when is_binary(Uri) -> supported_dialect(strip_fragment(Uri), Ids);
        Other -> error({schema_error, {unsupported_dialect, Other}})
    end;
check_dialect(_Schema, _Ids) ->
    ok.

supported_dialect(?DIALECT, _Ids) ->
    ok;
supported_dialect(Uri, Ids) ->
    case maps:is_key(Uri, Ids) of
        true -> ok;
        false -> error({schema_error, {unsupported_dialect, Uri}})
    end.

base_of(Schema) when is_map(Schema) ->
    case maps:get(<<"$id">>, Schema, undefined) of
        Id when is_binary(Id) -> normalize_uri(strip_fragment(Id));
        _ -> <<>>
    end;
base_of(_Schema) ->
    <<>>.

%% Walk every subschema, recording `$id' and `$anchor' against the base
%% in force at that point.
collect(Schema, Base, Acc) ->
    collect(Schema, Base, Acc, 0).

collect(_Schema, _Base, _Acc, Depth) when Depth > ?DEFAULT_MAX_DEPTH ->
    error({schema_error, too_deep});
collect(Schema, Base, Acc, Depth) when is_map(Schema) ->
    Here = child_base(Schema, Base),
    Acc1 =
        case Here of
            Base -> Acc;
            _ -> Acc#{Here => Schema}
        end,
    Acc2 = with_anchor(Schema, Here, Acc1),
    Acc3 = with_dynamic_anchor(Schema, Here, Acc2),
    maps:fold(
        fun(Key, Value, A) -> collect_child(Key, Value, Here, A, Depth) end,
        Acc3,
        Schema
    );
collect(_Schema, _Base, Acc, _Depth) ->
    Acc.

child_base(Schema, Base) ->
    case maps:get(<<"$id">>, Schema, undefined) of
        Id when is_binary(Id) -> resolve_uri(Base, strip_fragment(Id));
        _ -> Base
    end.

with_anchor(Schema, Base, Acc) ->
    case maps:get(<<"$anchor">>, Schema, undefined) of
        A when is_binary(A) -> Acc#{<<Base/binary, "#", A/binary>> => Schema};
        _ -> Acc
    end.

with_dynamic_anchor(Schema, Base, Acc) ->
    case maps:get(<<"$dynamicAnchor">>, Schema, undefined) of
        A when is_binary(A) ->
            Uri = <<Base/binary, "#", A/binary>>,
            Acc#{Uri => Schema, {dynamic, A, Uri} => Schema};
        _ ->
            Acc
    end.

%% Keywords whose value is a map of subschemas, a list of subschemas, or
%% a subschema. Everything else is data and is not walked.
collect_child(Key, Value, Base, Acc, Depth) when
    Key =:= <<"properties">>;
    Key =:= <<"patternProperties">>;
    Key =:= <<"$defs">>;
    Key =:= <<"definitions">>;
    Key =:= <<"dependentSchemas">>
->
    case Value of
        Map when is_map(Map) ->
            maps:fold(fun(_K, V, A) -> collect(V, Base, A, Depth + 1) end, Acc, Map);
        _ ->
            Acc
    end;
collect_child(Key, Value, Base, Acc, Depth) when
    Key =:= <<"allOf">>;
    Key =:= <<"anyOf">>;
    Key =:= <<"oneOf">>;
    Key =:= <<"prefixItems">>
->
    case Value of
        List when is_list(List) ->
            lists:foldl(fun(V, A) -> collect(V, Base, A, Depth + 1) end, Acc, List);
        _ ->
            Acc
    end;
collect_child(Key, Value, Base, Acc, Depth) when
    Key =:= <<"items">>;
    Key =:= <<"contains">>;
    Key =:= <<"not">>;
    Key =:= <<"if">>;
    Key =:= <<"then">>;
    Key =:= <<"else">>;
    Key =:= <<"additionalProperties">>;
    Key =:= <<"unevaluatedProperties">>;
    Key =:= <<"unevaluatedItems">>;
    Key =:= <<"propertyNames">>;
    Key =:= <<"contentSchema">>
->
    collect(Value, Base, Acc, Depth + 1);
collect_child(_Key, _Value, _Base, Acc, _Depth) ->
    Acc.

collect_dynamic(Ids) ->
    maps:fold(
        fun
            ({dynamic, Name, Uri}, _Schema, Acc) ->
                maps:update_with(Name, fun(L) -> L ++ [Uri] end, [Uri], Acc);
            (_Key, _Schema, Acc) ->
                Acc
        end,
        #{},
        Ids
    ).

%% Every `$ref' must resolve now. A schema whose references only fail at
%% validation time would fail differently for different data.
check_refs(Schema, Base, Compiled) ->
    check_refs(Schema, Base, Compiled, 0),
    ok.

check_refs(_Schema, _Base, _Compiled, Depth) when Depth > ?DEFAULT_MAX_DEPTH ->
    error({schema_error, too_deep});
check_refs(Schema, Base, Compiled, Depth) when is_map(Schema) ->
    Here = child_base(Schema, Base),
    _ =
        case maps:get(<<"$ref">>, Schema, undefined) of
            Ref when is_binary(Ref) ->
                case lookup_ref(Here, Ref, Compiled) of
                    {ok, _} -> ok;
                    error -> error({schema_error, {unresolved_ref, Ref}})
                end;
            _ ->
                ok
        end,
    maps:foreach(
        fun(Key, Value) -> check_refs_child(Key, Value, Here, Compiled, Depth) end,
        Schema
    );
check_refs(_Schema, _Base, _Compiled, _Depth) ->
    ok.

check_refs_child(Key, Value, Base, Compiled, Depth) when
    Key =:= <<"properties">>;
    Key =:= <<"patternProperties">>;
    Key =:= <<"$defs">>;
    Key =:= <<"definitions">>;
    Key =:= <<"dependentSchemas">>
->
    case Value of
        Map when is_map(Map) ->
            maps:foreach(fun(_K, V) -> check_refs(V, Base, Compiled, Depth + 1) end, Map);
        _ ->
            ok
    end;
check_refs_child(Key, Value, Base, Compiled, Depth) when
    Key =:= <<"allOf">>;
    Key =:= <<"anyOf">>;
    Key =:= <<"oneOf">>;
    Key =:= <<"prefixItems">>
->
    case Value of
        List when is_list(List) ->
            lists:foreach(fun(V) -> check_refs(V, Base, Compiled, Depth + 1) end, List);
        _ ->
            ok
    end;
check_refs_child(Key, Value, Base, Compiled, Depth) when
    Key =:= <<"items">>;
    Key =:= <<"contains">>;
    Key =:= <<"not">>;
    Key =:= <<"if">>;
    Key =:= <<"then">>;
    Key =:= <<"else">>;
    Key =:= <<"additionalProperties">>;
    Key =:= <<"unevaluatedProperties">>;
    Key =:= <<"unevaluatedItems">>;
    Key =:= <<"propertyNames">>;
    Key =:= <<"contentSchema">>
->
    check_refs(Value, Base, Compiled, Depth + 1);
check_refs_child(_Key, _Value, _Base, _Compiled, _Depth) ->
    ok.

%%====================================================================
%% Validation
%%====================================================================

%% @doc Validate `Value' against a schema, compiling it first.
-spec validate(term(), term()) -> ok | {error, [error()]}.
validate(Value, Schema) ->
    case compile(Schema) of
        {ok, Compiled} -> validate(Value, Compiled, #{});
        {error, Reason} -> {error, [{[], {invalid_schema, Reason}}]}
    end.

%% @doc Validate against an already compiled schema.
-spec validate(term(), schema(), map()) -> ok | {error, [error()]}.
validate(Value, #schema{} = Compiled, _Opts) ->
    Ctx = #ctx{
        schema = Compiled,
        scope = [Compiled#schema.base],
        budget = counters:new(1, [])
    },
    try eval(Value, Compiled#schema.root, Compiled#schema.base, [], Ctx) of
        {[], _Ann} -> ok;
        {Errors, _Ann} -> {error, lists:reverse(Errors)}
    catch
        error:{schema_error, Reason} -> {error, [{[], {schema_error, Reason}}]}
    end.

%% The result of evaluating one schema against one value: the errors it
%% produced, and what it evaluated. `unevaluatedProperties' and
%% `unevaluatedItems' are defined in terms of the second, which is why
%% it is threaded rather than discarded.
-record(ann, {
    props = [] :: all | [binary()],
    %% Which array indices were evaluated. `all' is `items' having
    %% applied to the tail.
    items = [] :: all | [non_neg_integer()]
}).

eval(_Value, _Schema, _Base, Path, #ctx{depth = D}) when D > ?DEFAULT_MAX_DEPTH ->
    error({schema_error, {too_deep, Path}});
%% A `true' schema asserts nothing and evaluates nothing: it is not
%% `additionalProperties: true', and treating it as such would let it
%% satisfy an `unevaluated*' it never looked at.
eval(_Value, true, _Base, _Path, _Ctx) ->
    {[], #ann{}};
eval(_Value, false, _Base, Path, _Ctx) ->
    {[{Path, false_schema}], #ann{}};
eval(Value, Schema, Base, Path, Ctx) when is_map(Schema) ->
    eval_at(Value, Schema, child_base(Schema, Base), Path, Ctx);
eval(_Value, _Schema, _Base, Path, _Ctx) ->
    {[{Path, invalid_schema}], #ann{}}.

%% As `eval/5', with the base already settled. Entering through a
%% reference is the case that needs it: the lookup resolved the target's
%% own `$id' to get there, and applying it a second time would nest the
%% URI inside itself.
eval_at(_Value, true, _Base, _Path, _Ctx) ->
    {[], #ann{}};
eval_at(_Value, false, _Base, Path, _Ctx) ->
    {[{Path, false_schema}], #ann{}};
eval_at(Value, Schema, Base, Path, Ctx) when is_map(Schema) ->
    ok = spend(Ctx),
    Ctx1 = Ctx#ctx{depth = Ctx#ctx.depth + 1, scope = [Base | Ctx#ctx.scope]},
    run_keywords(Value, Schema, Base, Path, Ctx1);
eval_at(_Value, _Schema, _Base, Path, _Ctx) ->
    {[{Path, invalid_schema}], #ann{}}.

spend(#ctx{budget = Budget}) ->
    counters:add(Budget, 1, 1),
    case counters:get(Budget, 1) > ?DEFAULT_MAX_SUBSCHEMAS of
        true -> error({schema_error, too_many_subschemas});
        false -> ok
    end.

%% `$ref' is applied alongside the other keywords, not instead of them:
%% 2019-09 onward made it a normal keyword.
run_keywords(Value, Schema, Base, Path, Ctx) ->
    {RefErrs, RefAnn} = apply_refs(Value, Schema, Base, Path, Ctx),
    {CoreErrs, CoreAnn} = apply_core(Value, Schema, Base, Path, Ctx),
    {AppErrs, AppAnn} = apply_applicators(Value, Schema, Base, Path, Ctx),
    Ann = merge_ann([RefAnn, CoreAnn, AppAnn]),
    Errors = RefErrs ++ CoreErrs ++ AppErrs,
    %% The `unevaluated*' pair sees everything the rest of this schema
    %% evaluated, which is why it runs last and takes the merge.
    {UnErrs, UnAnn} = apply_unevaluated(Value, Schema, Base, Path, Ctx, Ann, Errors),
    {Errors ++ UnErrs, merge_ann([Ann, UnAnn])}.

apply_refs(Value, Schema, Base, Path, Ctx) ->
    Results = lists:flatten([
        [ref_result(Value, Ref, Base, Path, Ctx) || Ref <- [ref_of(Schema)], Ref =/= undefined],
        [
            dynamic_result(Value, Ref, Base, Path, Ctx)
         || Ref <- [dynamic_ref_of(Schema)], Ref =/= undefined
        ]
    ]),
    collect_results(Results).

ref_of(Schema) -> binary_or_undefined(maps:get(<<"$ref">>, Schema, undefined)).
dynamic_ref_of(Schema) -> binary_or_undefined(maps:get(<<"$dynamicRef">>, Schema, undefined)).

binary_or_undefined(B) when is_binary(B) -> B;
binary_or_undefined(_) -> undefined.

ref_result(Value, Ref, Base, Path, Ctx) ->
    case lookup_ref(Base, Ref, Ctx#ctx.schema) of
        {ok, {Target, TargetBase}} -> eval_at(Value, Target, TargetBase, Path, Ctx);
        error -> {[{Path, {unresolved_ref, Ref}}], #ann{}}
    end.

%% A `$dynamicRef' resolves against the outermost `$dynamicAnchor' of
%% the same name that is in scope, which is what lets a schema extend
%% one it does not know the name of.
%% The scope is only searched when the reference's own target carries a
%% `$dynamicAnchor' of that name: that "bookend" is what makes it
%% dynamic. Without it the keyword behaves as a plain `$ref', and an
%% unrelated `$dynamicAnchor' further out must not capture it.
dynamic_result(Value, Ref, Base, Path, Ctx) ->
    Name = fragment_of(Ref),
    case lookup_ref(Base, Ref, Ctx#ctx.schema) of
        error ->
            {[{Path, {unresolved_ref, Ref}}], #ann{}};
        {ok, {Initial, InitialBase}} ->
            case bookended(Initial, Name) andalso dynamic_target(Name, Ctx) of
                {ok, {Target, TargetBase}} -> eval_at(Value, Target, TargetBase, Path, Ctx);
                _ -> eval_at(Value, Initial, InitialBase, Path, Ctx)
            end
    end.

bookended(Target, Name) when is_map(Target), is_binary(Name) ->
    maps:get(<<"$dynamicAnchor">>, Target, undefined) =:= Name;
bookended(_Target, _Name) ->
    false.

dynamic_target(undefined, _Ctx) ->
    error;
dynamic_target(Name, #ctx{schema = S, scope = Scope}) ->
    %% Only a `$dynamicAnchor' takes part in dynamic resolution. A plain
    %% `$anchor' of the same name is a different thing, which is why the
    %% two are indexed separately.
    Candidates = [
        Uri
     || Uri <- lists:reverse(Scope),
        maps:is_key({dynamic, Name, <<Uri/binary, "#", Name/binary>>}, S#schema.ids)
    ],
    case Candidates of
        [Uri | _] ->
            Key = {dynamic, Name, <<Uri/binary, "#", Name/binary>>},
            {ok, {maps:get(Key, S#schema.ids), Uri}};
        [] ->
            error
    end.

collect_results(Results) ->
    lists:foldl(
        fun({Errs, Ann}, {AccErrs, AccAnn}) ->
            {AccErrs ++ Errs, merge_ann([AccAnn, Ann])}
        end,
        {[], #ann{}},
        Results
    ).

merge_ann(Anns) ->
    lists:foldl(
        fun(#ann{props = P, items = I}, #ann{props = AccP, items = AccI}) ->
            #ann{props = merge_props(AccP, P), items = merge_items(AccI, I)}
        end,
        #ann{},
        Anns
    ).

merge_props(all, _) -> all;
merge_props(_, all) -> all;
merge_props(A, B) -> lists:usort(A ++ B).

merge_items(all, _) -> all;
merge_items(_, all) -> all;
merge_items(A, B) -> lists:usort(A ++ B).

%%====================================================================
%% Assertions
%%====================================================================

apply_core(Value, Schema, _Base, Path, _Ctx) ->
    Errors = lists:append([
        check_type(Value, maps:get(<<"type">>, Schema, undefined), Path),
        check_enum(Value, Schema, Path),
        check_const(Value, Schema, Path),
        check_number(Value, Schema, Path),
        check_string(Value, Schema, Path),
        check_array_bounds(Value, Schema, Path),
        check_object_bounds(Value, Schema, Path)
    ]),
    {Errors, #ann{}}.

%%-- type -------------------------------------------------------------

check_type(_Value, undefined, _Path) ->
    [];
check_type(Value, Types, Path) when is_list(Types) ->
    case lists:any(fun(T) -> is_type(Value, T) end, Types) of
        true -> [];
        false -> [{Path, {type_mismatch, Types}}]
    end;
check_type(Value, Type, Path) ->
    case is_type(Value, Type) of
        true -> [];
        false -> [{Path, {type_mismatch, Type}}]
    end.

is_type(V, <<"object">>) -> is_map(V);
is_type(V, <<"array">>) -> is_list(V);
is_type(V, <<"string">>) -> is_binary(V);
is_type(V, <<"boolean">>) -> is_boolean(V);
is_type(V, <<"null">>) -> V =:= null;
%% "an integer is a number with a zero fractional part", so 1.0 is one.
is_type(V, <<"integer">>) when is_integer(V) -> true;
is_type(V, <<"integer">>) when is_float(V) -> trunc(V) == V;
is_type(V, <<"number">>) -> is_number(V) andalso not is_boolean(V);
is_type(_V, _Type) -> false.

%%-- enum / const -----------------------------------------------------

check_enum(Value, Schema, Path) ->
    case maps:get(<<"enum">>, Schema, undefined) of
        Values when is_list(Values) ->
            case lists:any(fun(V) -> json_equal(Value, V) end, Values) of
                true -> [];
                false -> [{Path, {not_in_enum, Values}}]
            end;
        _ ->
            []
    end.

check_const(Value, Schema, Path) ->
    case maps:find(<<"const">>, Schema) of
        {ok, Const} ->
            case json_equal(Value, Const) of
                true -> [];
                false -> [{Path, const}]
            end;
        error ->
            []
    end.

%% JSON equality, where 1 and 1.0 are the same number but `true' is not
%% 1, and object key order does not matter.
json_equal(A, B) when is_boolean(A) ->
    A =:= B;
json_equal(A, B) when is_boolean(B) ->
    A =:= B;
json_equal(A, B) when is_number(A), is_number(B) ->
    A == B;
json_equal(A, B) when is_list(A), is_list(B) ->
    length(A) =:= length(B) andalso
        lists:all(fun({X, Y}) -> json_equal(X, Y) end, lists:zip(A, B));
json_equal(A, B) when is_map(A), is_map(B) ->
    maps:size(A) =:= maps:size(B) andalso
        lists:all(
            fun({K, V}) ->
                case maps:find(K, B) of
                    {ok, V2} -> json_equal(V, V2);
                    error -> false
                end
            end,
            maps:to_list(A)
        );
json_equal(A, B) ->
    A =:= B.

%%-- numbers ----------------------------------------------------------

check_number(Value, Schema, Path) when is_number(Value), not is_boolean(Value) ->
    lists:append([
        bound(
            Value,
            maps:get(<<"minimum">>, Schema, undefined),
            fun(V, L) -> V >= L end,
            minimum,
            Path
        ),
        bound(
            Value,
            maps:get(<<"maximum">>, Schema, undefined),
            fun(V, L) -> V =< L end,
            maximum,
            Path
        ),
        bound(
            Value,
            maps:get(<<"exclusiveMinimum">>, Schema, undefined),
            fun(V, L) -> V > L end,
            exclusive_minimum,
            Path
        ),
        bound(
            Value,
            maps:get(<<"exclusiveMaximum">>, Schema, undefined),
            fun(V, L) -> V < L end,
            exclusive_maximum,
            Path
        ),
        check_multiple_of(Value, maps:get(<<"multipleOf">>, Schema, undefined), Path)
    ]);
check_number(_Value, _Schema, _Path) ->
    [].

bound(_Value, undefined, _Pred, _Name, _Path) ->
    [];
bound(Value, Limit, Pred, Name, Path) when is_number(Limit) ->
    case Pred(Value, Limit) of
        true -> [];
        false -> [{Path, {Name, Limit}}]
    end;
bound(_Value, _Limit, _Pred, _Name, _Path) ->
    [].

check_multiple_of(_Value, undefined, _Path) ->
    [];
check_multiple_of(_Value, Divisor, Path) when not is_number(Divisor) ->
    _ = Path,
    [];
check_multiple_of(_Value, Divisor, _Path) when Divisor =< 0 ->
    [];
check_multiple_of(Value, Divisor, Path) when is_integer(Value), is_integer(Divisor) ->
    case Value rem Divisor of
        0 -> [];
        _ -> [{Path, {multiple_of, Divisor}}]
    end;
check_multiple_of(Value, Divisor, Path) ->
    %% A quotient that overflows to infinity is not an integer, and the
    %% suite expects that instance to be invalid rather than to raise.
    try
        Quotient = Value / Divisor,
        abs(Quotient - round(Quotient)) < 1.0e-9
    of
        true -> [];
        false -> [{Path, {multiple_of, Divisor}}]
    catch
        error:badarith -> [{Path, {multiple_of, Divisor}}]
    end.

%%-- strings ----------------------------------------------------------

check_string(Value, Schema, Path) when is_binary(Value) ->
    Length = string:length(Value),
    lists:append([
        bound(
            Length,
            maps:get(<<"minLength">>, Schema, undefined),
            fun(V, L) -> V >= L end,
            min_length,
            Path
        ),
        bound(
            Length,
            maps:get(<<"maxLength">>, Schema, undefined),
            fun(V, L) -> V =< L end,
            max_length,
            Path
        ),
        check_pattern(Value, maps:get(<<"pattern">>, Schema, undefined), Path)
    ]);
check_string(_Value, _Schema, _Path) ->
    [].

check_pattern(_Value, undefined, _Path) ->
    [];
check_pattern(Value, Pattern, Path) when is_binary(Pattern) ->
    case matches(Value, Pattern) of
        true -> [];
        false -> [{Path, {pattern_mismatch, Pattern}}]
    end;
check_pattern(_Value, _Pattern, _Path) ->
    [].

%%-- array and object bounds ------------------------------------------

check_array_bounds(Value, Schema, Path) when is_list(Value) ->
    Length = length(Value),
    lists:append([
        bound(
            Length,
            maps:get(<<"minItems">>, Schema, undefined),
            fun(V, L) -> V >= L end,
            min_items,
            Path
        ),
        bound(
            Length,
            maps:get(<<"maxItems">>, Schema, undefined),
            fun(V, L) -> V =< L end,
            max_items,
            Path
        ),
        check_unique(Value, maps:get(<<"uniqueItems">>, Schema, false), Path)
    ]);
check_array_bounds(_Value, _Schema, _Path) ->
    [].

check_unique(Value, true, Path) ->
    case has_duplicate(Value) of
        true -> [{Path, items_not_unique}];
        false -> []
    end;
check_unique(_Value, _Flag, _Path) ->
    [].

has_duplicate([]) -> false;
has_duplicate([H | T]) -> lists:any(fun(X) -> json_equal(H, X) end, T) orelse has_duplicate(T).

check_object_bounds(Value, Schema, Path) when is_map(Value) ->
    Size = maps:size(Value),
    lists:append([
        bound(
            Size,
            maps:get(<<"minProperties">>, Schema, undefined),
            fun(V, L) -> V >= L end,
            min_properties,
            Path
        ),
        bound(
            Size,
            maps:get(<<"maxProperties">>, Schema, undefined),
            fun(V, L) -> V =< L end,
            max_properties,
            Path
        ),
        check_required(Value, maps:get(<<"required">>, Schema, undefined), Path),
        check_dependent_required(Value, maps:get(<<"dependentRequired">>, Schema, undefined), Path)
    ]);
check_object_bounds(_Value, _Schema, _Path) ->
    [].

check_required(Value, Names, Path) when is_list(Names) ->
    [{Path, {missing_required, N}} || N <- Names, is_binary(N), not maps:is_key(N, Value)];
check_required(_Value, _Names, _Path) ->
    [].

check_dependent_required(Value, Deps, Path) when is_map(Deps) ->
    maps:fold(
        fun(Key, Names, Acc) ->
            case maps:is_key(Key, Value) andalso is_list(Names) of
                true -> check_required(Value, Names, Path) ++ Acc;
                false -> Acc
            end
        end,
        [],
        Deps
    );
check_dependent_required(_Value, _Deps, _Path) ->
    [].

%%====================================================================
%% Applicators
%%====================================================================

apply_applicators(Value, Schema, Base, Path, Ctx) ->
    Results = [
        in_place(Value, Schema, Base, Path, Ctx),
        object_applicators(Value, Schema, Base, Path, Ctx),
        array_applicators(Value, Schema, Base, Path, Ctx)
    ],
    collect_results(Results).

%%-- in-place ---------------------------------------------------------

in_place(Value, Schema, Base, Path, Ctx) ->
    collect_results([
        all_of(Value, Schema, Base, Path, Ctx),
        any_of(Value, Schema, Base, Path, Ctx),
        one_of(Value, Schema, Base, Path, Ctx),
        negate(Value, Schema, Base, Path, Ctx),
        conditional(Value, Schema, Base, Path, Ctx),
        dependent_schemas(Value, Schema, Base, Path, Ctx)
    ]).

all_of(Value, Schema, Base, Path, Ctx) ->
    case maps:get(<<"allOf">>, Schema, undefined) of
        List when is_list(List) ->
            Results = [eval(Value, Sub, Base, Path, Ctx) || Sub <- List],
            {lists:append([E || {E, _} <- Results]), merge_ann(successful(Results))};
        _ ->
            {[], #ann{}}
    end.

%% "an instance validates against anyOf if it validates against at least
%% one", and only the branches that did validate contribute annotations.
any_of(Value, Schema, Base, Path, Ctx) ->
    case maps:get(<<"anyOf">>, Schema, undefined) of
        List when is_list(List) ->
            Results = [eval(Value, Sub, Base, Path, Ctx) || Sub <- List],
            case successful(Results) of
                [] -> {[{Path, no_anyof_match}], #ann{}};
                Ok -> {[], merge_ann(Ok)}
            end;
        _ ->
            {[], #ann{}}
    end.

one_of(Value, Schema, Base, Path, Ctx) ->
    case maps:get(<<"oneOf">>, Schema, undefined) of
        List when is_list(List) ->
            Results = [eval(Value, Sub, Base, Path, Ctx) || Sub <- List],
            case successful(Results) of
                [Ann] -> {[], Ann};
                [] -> {[{Path, no_oneof_match}], #ann{}};
                _Many -> {[{Path, multiple_oneof_match}], #ann{}}
            end;
        _ ->
            {[], #ann{}}
    end.

%% A `not' that passes contributes no annotations: nothing under it was
%% evaluated in the sense `unevaluated*' means.
negate(Value, Schema, Base, Path, Ctx) ->
    case maps:find(<<"not">>, Schema) of
        {ok, Sub} ->
            case eval(Value, Sub, Base, Path, Ctx) of
                {[], _} -> {[{Path, 'not'}], #ann{}};
                {_, _} -> {[], #ann{}}
            end;
        error ->
            {[], #ann{}}
    end.

conditional(Value, Schema, Base, Path, Ctx) ->
    case maps:find(<<"if">>, Schema) of
        error ->
            {[], #ann{}};
        {ok, If} ->
            case eval(Value, If, Base, Path, Ctx) of
                {[], IfAnn} -> branch(<<"then">>, Value, Schema, Base, Path, Ctx, IfAnn);
                {_, _} -> branch(<<"else">>, Value, Schema, Base, Path, Ctx, #ann{})
            end
    end.

branch(Key, Value, Schema, Base, Path, Ctx, IfAnn) ->
    case maps:find(Key, Schema) of
        error ->
            {[], IfAnn};
        {ok, Sub} ->
            {Errs, Ann} = eval(Value, Sub, Base, Path, Ctx),
            case Errs of
                [] -> {[], merge_ann([IfAnn, Ann])};
                _ -> {Errs, IfAnn}
            end
    end.

dependent_schemas(Value, Schema, Base, Path, Ctx) when is_map(Value) ->
    case maps:get(<<"dependentSchemas">>, Schema, undefined) of
        Deps when is_map(Deps) ->
            Results = [
                eval(Value, Sub, Base, Path, Ctx)
             || {Key, Sub} <- maps:to_list(Deps), maps:is_key(Key, Value)
            ],
            {lists:append([E || {E, _} <- Results]), merge_ann(successful(Results))};
        _ ->
            {[], #ann{}}
    end;
dependent_schemas(_Value, _Schema, _Base, _Path, _Ctx) ->
    {[], #ann{}}.

successful(Results) ->
    [Ann || {[], Ann} <- Results].

%%-- objects ----------------------------------------------------------

object_applicators(Value, Schema, Base, Path, Ctx) when is_map(Value) ->
    {PropErrs, Named} = properties(Value, Schema, Base, Path, Ctx),
    {PatErrs, Matched} = pattern_properties(Value, Schema, Base, Path, Ctx),
    Evaluated = lists:usort(Named ++ Matched),
    {AddErrs, AddAnn} = additional_properties(
        Value, Schema, Base, Path, Ctx, Evaluated
    ),
    {NameErrs, _} = property_names(Value, Schema, Base, Path, Ctx),
    Ann = merge_ann([#ann{props = Evaluated}, AddAnn]),
    {PropErrs ++ PatErrs ++ AddErrs ++ NameErrs, Ann};
object_applicators(_Value, _Schema, _Base, _Path, _Ctx) ->
    {[], #ann{}}.

properties(Value, Schema, Base, Path, Ctx) ->
    case maps:get(<<"properties">>, Schema, undefined) of
        Props when is_map(Props) ->
            Present = [K || K <- maps:keys(Props), maps:is_key(K, Value)],
            Errors = lists:append([
                element(
                    1,
                    eval(maps:get(K, Value), maps:get(K, Props), Base, Path ++ [K], Ctx)
                )
             || K <- Present
            ]),
            {Errors, Present};
        _ ->
            {[], []}
    end.

pattern_properties(Value, Schema, Base, Path, Ctx) ->
    case maps:get(<<"patternProperties">>, Schema, undefined) of
        Patterns when is_map(Patterns) ->
            Pairs = [
                {K, Sub}
             || {Pattern, Sub} <- maps:to_list(Patterns),
                K <- maps:keys(Value),
                matches(K, Pattern)
            ],
            Errors = lists:append([
                element(1, eval(maps:get(K, Value), Sub, Base, Path ++ [K], Ctx))
             || {K, Sub} <- Pairs
            ]),
            {Errors, [K || {K, _} <- Pairs]};
        _ ->
            {[], []}
    end.

%% ECMA-262 is the dialect's regex language and PCRE is not quite it, so
%% a pattern we cannot compile asserts nothing rather than raising.
matches(Value, Pattern) when is_binary(Pattern) ->
    case compiled_pattern(Pattern) of
        error ->
            false;
        {ok, MP} ->
            try re:run(Value, MP, [{capture, none}]) of
                match -> true;
                _ -> false
            catch
                _:_ -> false
            end
    end;
matches(_Value, _Pattern) ->
    false.

%% `re:run/3' given a binary pattern compiles it on every call, and a
%% `patternProperties' entry is applied once per property of every
%% object it sees. Memoised in the process dictionary rather than a
%% shared table: the validating process serves one request, so the cache
%% cannot outlive it, and the subschema budget bounds how many distinct
%% patterns a peer can reach.
compiled_pattern(Pattern) ->
    Key = {?MODULE, pattern, Pattern},
    case get(Key) of
        undefined ->
            Result =
                try re:compile(ecma_properties(Pattern), [unicode, ucp]) of
                    {ok, MP} -> {ok, MP};
                    {error, _} -> error
                catch
                    _:_ -> error
                end,
            put(Key, Result),
            Result;
        Cached ->
            Cached
    end.

additional_properties(Value, Schema, Base, Path, Ctx, Evaluated) ->
    case maps:find(<<"additionalProperties">>, Schema) of
        error ->
            {[], #ann{}};
        {ok, false} ->
            %% Reported as the property that was not allowed rather than
            %% as a `false' schema at its path: the caller wants to know
            %% which key it was.
            Rest = [K || K <- maps:keys(Value), not lists:member(K, Evaluated)],
            {[{Path, {unexpected_property, K}} || K <- Rest], #ann{props = Rest}};
        {ok, Sub} ->
            Rest = [K || K <- maps:keys(Value), not lists:member(K, Evaluated)],
            Errors = lists:append([
                element(1, eval(maps:get(K, Value), Sub, Base, Path ++ [K], Ctx))
             || K <- Rest
            ]),
            {Errors, #ann{props = Rest}}
    end.

property_names(Value, Schema, Base, Path, Ctx) ->
    case maps:find(<<"propertyNames">>, Schema) of
        error ->
            {[], #ann{}};
        {ok, Sub} ->
            Errors = lists:append([
                element(1, eval(K, Sub, Base, Path ++ [K], Ctx))
             || K <- maps:keys(Value)
            ]),
            {Errors, #ann{}}
    end.

%%-- arrays -----------------------------------------------------------

array_applicators(Value, Schema, Base, Path, Ctx) when is_list(Value) ->
    {PrefixErrs, PrefixCount} = prefix_items(Value, Schema, Base, Path, Ctx),
    {ItemErrs, ItemAnn} = items(Value, Schema, Base, Path, Ctx, PrefixCount),
    {ContainsErrs, ContainsAnn} = contains(Value, Schema, Base, Path, Ctx),
    Prefixed = lists:seq(0, PrefixCount - 1),
    Ann = merge_ann([#ann{items = Prefixed}, ItemAnn, ContainsAnn]),
    {PrefixErrs ++ ItemErrs ++ ContainsErrs, Ann};
array_applicators(_Value, _Schema, _Base, _Path, _Ctx) ->
    {[], #ann{}}.

prefix_items(Value, Schema, Base, Path, Ctx) ->
    case maps:get(<<"prefixItems">>, Schema, undefined) of
        List when is_list(List) ->
            Count = min(length(List), length(Value)),
            Errors = lists:append([
                element(
                    1,
                    eval(lists:nth(I + 1, Value), lists:nth(I + 1, List), Base, Path ++ [I], Ctx)
                )
             || I <- lists:seq(0, Count - 1)
            ]),
            {Errors, Count};
        _ ->
            {[], 0}
    end.

items(Value, Schema, Base, Path, Ctx, Skip) ->
    case maps:find(<<"items">>, Schema) of
        error ->
            {[], #ann{}};
        {ok, Sub} ->
            Rest = lists:nthtail(min(Skip, length(Value)), Value),
            Errors = lists:append([
                element(1, eval(V, Sub, Base, Path ++ [I], Ctx))
             || {I, V} <- lists:zip(lists:seq(Skip, Skip + length(Rest) - 1), Rest)
            ]),
            %% "applies to every index past prefixItems", so everything
            %% from here on counts as evaluated even when there is
            %% nothing left.
            {Errors, #ann{items = all}}
    end.

contains(Value, Schema, Base, Path, Ctx) ->
    case maps:find(<<"contains">>, Schema) of
        error ->
            {[], #ann{}};
        {ok, Sub} ->
            Indexed = lists:zip(lists:seq(0, length(Value) - 1), Value),
            Matched = [
                I
             || {I, V} <- Indexed, element(1, eval(V, Sub, Base, Path ++ [I], Ctx)) =:= []
            ],
            Count = length(Matched),
            Min = bounded(maps:get(<<"minContains">>, Schema, 1)),
            Max = bounded(maps:get(<<"maxContains">>, Schema, undefined)),
            Errors = lists:append([
                [{Path, {min_contains, Min}} || is_number(Min), Count < Min],
                [{Path, {max_contains, Max}} || is_number(Max), Count > Max]
            ]),
            {Errors, #ann{items = Matched}}
    end.

%% A bound written as `2.0' is the integer 2; one with a fraction can
%% never be met exactly by a count, so it is compared numerically.
bounded(N) when is_number(N) -> N;
bounded(_N) -> undefined.

%% ECMAScript spells a Unicode general category out; PCRE wants the
%% abbreviation and rejects the long form outright. Script names are
%% spelled the same in both and pass through.
ecma_properties(Pattern) ->
    case binary:match(Pattern, <<"\\p{">>) of
        nomatch ->
            case binary:match(Pattern, <<"\\P{">>) of
                nomatch -> Pattern;
                _ -> rewrite_properties(Pattern)
            end;
        _ ->
            rewrite_properties(Pattern)
    end.

rewrite_properties(Pattern) ->
    lists:foldl(
        fun({Long, Short}, Acc) ->
            binary:replace(
                Acc, <<"{", Long/binary, "}">>, <<"{", Short/binary, "}">>, [global]
            )
        end,
        Pattern,
        general_categories()
    ).

%% Table 66 of ECMA-262, which is closed.
general_categories() ->
    [
        {<<"Cased_Letter">>, <<"LC">>},
        {<<"Close_Punctuation">>, <<"Pe">>},
        {<<"Connector_Punctuation">>, <<"Pc">>},
        {<<"Control">>, <<"Cc">>},
        {<<"Currency_Symbol">>, <<"Sc">>},
        {<<"Dash_Punctuation">>, <<"Pd">>},
        {<<"Decimal_Number">>, <<"Nd">>},
        {<<"Enclosing_Mark">>, <<"Me">>},
        {<<"Final_Punctuation">>, <<"Pf">>},
        {<<"Format">>, <<"Cf">>},
        {<<"Initial_Punctuation">>, <<"Pi">>},
        {<<"Letter_Number">>, <<"Nl">>},
        {<<"Letter">>, <<"L">>},
        {<<"Line_Separator">>, <<"Zl">>},
        {<<"Lowercase_Letter">>, <<"Ll">>},
        {<<"Mark">>, <<"M">>},
        {<<"Math_Symbol">>, <<"Sm">>},
        {<<"Modifier_Letter">>, <<"Lm">>},
        {<<"Modifier_Symbol">>, <<"Sk">>},
        {<<"Nonspacing_Mark">>, <<"Mn">>},
        {<<"Number">>, <<"N">>},
        {<<"Open_Punctuation">>, <<"Ps">>},
        {<<"Other_Letter">>, <<"Lo">>},
        {<<"Other_Number">>, <<"No">>},
        {<<"Other_Punctuation">>, <<"Po">>},
        {<<"Other_Symbol">>, <<"So">>},
        {<<"Other">>, <<"C">>},
        {<<"Paragraph_Separator">>, <<"Zp">>},
        {<<"Private_Use">>, <<"Co">>},
        {<<"Punctuation">>, <<"P">>},
        {<<"Separator">>, <<"Z">>},
        {<<"Space_Separator">>, <<"Zs">>},
        {<<"Spacing_Mark">>, <<"Mc">>},
        {<<"Surrogate">>, <<"Cs">>},
        {<<"Symbol">>, <<"S">>},
        {<<"Titlecase_Letter">>, <<"Lt">>},
        {<<"Unassigned">>, <<"Cn">>},
        {<<"Uppercase_Letter">>, <<"Lu">>}
    ].

%%====================================================================
%% unevaluated*
%%====================================================================

%% These see what the rest of the schema evaluated, so they run against
%% the merged annotation. A schema that already failed cannot become
%% valid here, but it must not report a second, misleading error either.
apply_unevaluated(_Value, _Schema, _Base, _Path, _Ctx, _Ann, [_ | _]) ->
    {[], #ann{}};
apply_unevaluated(Value, Schema, Base, Path, Ctx, Ann, []) ->
    collect_results([
        unevaluated_properties(Value, Schema, Base, Path, Ctx, Ann),
        unevaluated_items(Value, Schema, Base, Path, Ctx, Ann)
    ]).

unevaluated_properties(Value, Schema, Base, Path, Ctx, #ann{props = Seen}) when is_map(Value) ->
    case maps:find(<<"unevaluatedProperties">>, Schema) of
        error ->
            {[], #ann{}};
        {ok, _Sub} when Seen =:= all ->
            {[], #ann{props = all}};
        {ok, Sub} ->
            Rest = [K || K <- maps:keys(Value), not lists:member(K, Seen)],
            Errors = lists:append([
                element(1, eval(maps:get(K, Value), Sub, Base, Path ++ [K], Ctx))
             || K <- Rest
            ]),
            {Errors, #ann{props = Rest}}
    end;
unevaluated_properties(_Value, _Schema, _Base, _Path, _Ctx, _Ann) ->
    {[], #ann{}}.

unevaluated_items(Value, Schema, Base, Path, Ctx, #ann{items = Seen}) when is_list(Value) ->
    case maps:find(<<"unevaluatedItems">>, Schema) of
        error ->
            {[], #ann{}};
        {ok, _Sub} when Seen =:= all ->
            {[], #ann{items = all}};
        {ok, Sub} ->
            Indexed = lists:zip(lists:seq(0, length(Value) - 1), Value),
            Rest = [{I, V} || {I, V} <- Indexed, not lists:member(I, Seen)],
            Errors = lists:append([
                element(1, eval(V, Sub, Base, Path ++ [I], Ctx))
             || {I, V} <- Rest
            ]),
            {Errors, #ann{items = [I || {I, _} <- Rest]}}
    end;
unevaluated_items(_Value, _Schema, _Base, _Path, _Ctx, _Ann) ->
    {[], #ann{}}.

%%====================================================================
%% URIs and pointers
%%====================================================================

strip_fragment(Uri) ->
    case binary:split(Uri, <<"#">>) of
        [Base | _] -> Base;
        _ -> Uri
    end.

fragment_of(Uri) ->
    case binary:split(Uri, <<"#">>) of
        [_, <<>>] -> undefined;
        [_, Fragment] -> Fragment;
        _ -> undefined
    end.

normalize_uri(Uri) -> Uri.

%% Enough of RFC 3986 reference resolution for the shapes schemas use:
%% absolute URIs, absolute paths, and relative ones.
%% An empty reference is the base itself, not the empty URI.
resolve_uri(Base, <<>>) ->
    Base;
resolve_uri(Base, Reference) ->
    case has_scheme(Reference) of
        true ->
            Reference;
        false ->
            case Reference of
                <<"//", _/binary>> -> with_scheme_of(Base, Reference);
                <<"/", _/binary>> -> replace_path(Base, Reference);
                _ -> merge_relative(Base, Reference)
            end
    end.

%% RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ).
%% Scanned rather than matched because `resolve_uri/2' is on the eval
%% path, once per `$ref' application, and a binary pattern is compiled
%% on every `re:run/3'.
has_scheme(Uri) ->
    case scheme_end(Uri) of
        error -> false;
        {ok, _} -> true
    end.

%% The offset of the `:' ending the scheme, or `error'.
scheme_end(<<C, Rest/binary>>) when
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
->
    scheme_rest(Rest, 1);
scheme_end(_Uri) ->
    error.

scheme_rest(<<$:, _/binary>>, N) ->
    {ok, N};
scheme_rest(<<C, Rest/binary>>, N) when
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse
        C =:= $+ orelse C =:= $- orelse C =:= $.
->
    scheme_rest(Rest, N + 1);
scheme_rest(_Rest, _N) ->
    error.

with_scheme_of(Base, Reference) ->
    case binary:split(Base, <<":">>) of
        [Scheme, _] -> <<Scheme/binary, ":", Reference/binary>>;
        _ -> Reference
    end.

replace_path(Base, Reference) ->
    <<(authority_of(Base))/binary, Reference/binary>>.

%% Scheme and authority, without the path. `<<>>' for anything with no
%% `://', a `urn:' among them.
authority_of(Base) ->
    case scheme_end(Base) of
        error ->
            <<>>;
        {ok, N} ->
            case Base of
                <<Scheme:N/binary, "://", Rest/binary>> ->
                    <<Scheme/binary, "://", (up_to_slash(Rest))/binary>>;
                _ ->
                    <<>>
            end
    end.

up_to_slash(Bin) ->
    case binary:match(Bin, <<"/">>) of
        nomatch -> Bin;
        {Pos, _} -> binary:part(Bin, 0, Pos)
    end.

merge_relative(Base, Reference) ->
    Dir = directory_of(Base),
    remove_dot_segments(<<Dir/binary, Reference/binary>>).

directory_of(Base) ->
    case binary:matches(Base, <<"/">>) of
        [] ->
            <<>>;
        Matches ->
            {Pos, _} = lists:last(Matches),
            binary:part(Base, 0, Pos + 1)
    end.

remove_dot_segments(Uri) ->
    Prefix = authority_of(Uri),
    Rest = binary:part(Uri, byte_size(Prefix), byte_size(Uri) - byte_size(Prefix)),
    Segments = binary:split(Rest, <<"/">>, [global]),
    Cleaned = lists:foldl(
        fun
            (<<".">>, Acc) -> Acc;
            (<<"..">>, [_ | Acc]) -> Acc;
            (<<"..">>, []) -> [];
            (Segment, Acc) -> [Segment | Acc]
        end,
        [],
        Segments
    ),
    <<Prefix/binary, (iolist_to_binary(lists:join(<<"/">>, lists:reverse(Cleaned))))/binary>>.

%% A `$ref' is a URI reference against the base in force, whose fragment
%% is either an anchor name or a JSON pointer.
lookup_ref(Base, Ref, #schema{} = Schema) ->
    Target = strip_fragment(Ref),
    Fragment = fragment_of(Ref),
    Absolute =
        case Target of
            <<>> -> Base;
            _ -> resolve_uri(Base, Target)
        end,
    case Fragment of
        undefined -> lookup_document(Absolute, Schema);
        <<"/", _/binary>> -> lookup_pointer(Absolute, Fragment, Schema);
        <<>> -> lookup_document(Absolute, Schema);
        _ -> lookup_anchor(Absolute, Fragment, Schema)
    end.

lookup_document(Uri, #schema{ids = Ids, base = Base, root = Root}) ->
    case maps:find(Uri, Ids) of
        {ok, Doc} ->
            {ok, {Doc, Uri}};
        error when Uri =:= Base ->
            {ok, {Root, Base}};
        error ->
            error
    end.

lookup_anchor(Uri, Anchor, #schema{ids = Ids} = Schema) ->
    case maps:find(<<Uri/binary, "#", Anchor/binary>>, Ids) of
        {ok, Doc} -> {ok, {Doc, Uri}};
        error -> lookup_document(Uri, Schema)
    end.

lookup_pointer(Uri, Pointer, Schema) ->
    case lookup_document(Uri, Schema) of
        error ->
            error;
        {ok, {Doc, DocBase}} ->
            case walk_pointer(Doc, tokens(Pointer)) of
                {ok, Target} -> {ok, {Target, DocBase}};
                error -> error
            end
    end.

tokens(<<"/", Rest/binary>>) ->
    [unescape(percent_decode(T)) || T <- binary:split(Rest, <<"/">>, [global])];
tokens(_Pointer) ->
    [].

%% A pointer travels in a URI fragment, so it arrives percent-encoded.
percent_decode(Bin) -> percent_decode(Bin, <<>>).

percent_decode(<<$%, A, B, Rest/binary>>, Acc) ->
    try binary_to_integer(<<A, B>>, 16) of
        Byte -> percent_decode(Rest, <<Acc/binary, Byte>>)
    catch
        _:_ -> percent_decode(Rest, <<Acc/binary, $%, A, B>>)
    end;
percent_decode(<<C, Rest/binary>>, Acc) ->
    percent_decode(Rest, <<Acc/binary, C>>);
percent_decode(<<>>, Acc) ->
    Acc.

%% RFC 6901: `~1' is `/' and `~0' is `~', in that order.
unescape(Token) ->
    Once = binary:replace(Token, <<"~1">>, <<"/">>, [global]),
    binary:replace(Once, <<"~0">>, <<"~">>, [global]).

walk_pointer(Target, []) ->
    {ok, Target};
walk_pointer(Map, [Token | Rest]) when is_map(Map) ->
    case maps:find(Token, Map) of
        {ok, Next} -> walk_pointer(Next, Rest);
        error -> error
    end;
walk_pointer(List, [Token | Rest]) when is_list(List) ->
    try binary_to_integer(Token) of
        I when I >= 0, I < length(List) -> walk_pointer(lists:nth(I + 1, List), Rest);
        _ -> error
    catch
        _:_ -> error
    end;
walk_pointer(_Target, _Tokens) ->
    error.

%%====================================================================
%% The dialect's own schema
%%====================================================================

%% @doc The 2020-12 metaschema, compiled. Use it to check that something
%% claiming to be a schema is one.
-spec metaschema() -> schema().
metaschema() ->
    case persistent_term:get({?MODULE, metaschema}, undefined) of
        undefined ->
            Docs = metaschema_documents(),
            {ok, Compiled} = compile(maps:get(?DIALECT, Docs), Docs),
            persistent_term:put({?MODULE, metaschema}, Compiled),
            Compiled;
        Compiled ->
            Compiled
    end.

%% @doc Whether `Schema' is a valid 2020-12 schema, by the dialect's own
%% rules rather than by whether we happen to understand it.
-spec validate_schema(term()) -> ok | {error, [error()]}.
validate_schema(Schema) ->
    validate(Schema, metaschema(), #{}).

metaschema_documents() ->
    case persistent_term:get({?MODULE, meta_docs}, undefined) of
        undefined ->
            Docs = load_metaschema_documents(),
            persistent_term:put({?MODULE, meta_docs}, Docs),
            Docs;
        Docs ->
            Docs
    end.

load_metaschema_documents() ->
    Dir = filename:join(code:priv_dir(barrel_mcp), "jsonschema"),
    maps:from_list([
        {Uri, read_json(filename:join(Dir, File))}
     || {Uri, File} <- [
            {?DIALECT, "schema.json"},
            {<<"https://json-schema.org/draft/2020-12/meta/core">>, "meta_core.json"},
            {<<"https://json-schema.org/draft/2020-12/meta/applicator">>, "meta_applicator.json"},
            {<<"https://json-schema.org/draft/2020-12/meta/validation">>, "meta_validation.json"},
            {<<"https://json-schema.org/draft/2020-12/meta/unevaluated">>, "meta_unevaluated.json"},
            {<<"https://json-schema.org/draft/2020-12/meta/format-annotation">>,
                "meta_format-annotation.json"},
            {<<"https://json-schema.org/draft/2020-12/meta/content">>, "meta_content.json"},
            {<<"https://json-schema.org/draft/2020-12/meta/meta-data">>, "meta_meta-data.json"}
        ]
    ]).

read_json(Path) ->
    {ok, Bin} = file:read_file(Path),
    json:decode(Bin).
