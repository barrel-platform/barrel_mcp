%%%-------------------------------------------------------------------
%%% @doc The MCP protocol core: JSON-RPC envelopes in, envelopes out.
%%%
%%% This module owns what every transport shares: decoding a request,
%%% deciding which era it belongs to and whether that era has the
%%% method, validating `_meta', running the method handler, and
%%% rendering the answer for that era. It owns nothing about the
%%% wire: no sockets, no headers, no sessions on the wire, no SSE. A
%%% transport (`barrel_mcp_http_engine', `barrel_mcp_stdio') calls
%%% {@link handle/2} with a protocol state map and writes whatever
%%% comes back.
%%%
%%% == What handle/2 returns ==
%%%
%%% A response map to encode, `no_response' for a notification,
%%% `{async, Plan}' for a `tools/call' (the transport drives the plan,
%%% see {@link drive_async_plan/4}, because only it knows how to
%%% stream the answer), `{subscribe, Sub}' for `subscriptions/listen',
%%% or a list for a batch.
%%%
%%% == Sections, in file order ==
%%%
%%% <ul>
%%%   <li>API: `handle/1,2', `decode/1', the response constructors.</li>
%%%   <li>Batches: the legacy batch envelope and its per-era refusal.</li>
%%%   <li>Era dispatch: `dispatch/4' → `dispatch_versioned/4' →
%%%       `dispatch_valid/4'; `serves/2' says which methods an era
%%%       has; `finalize/2' decorates a result for its era.</li>
%%%   <li>Tasks: the task collector, `task_plan/2' (the mode rule for
%%%       every transport but Streamable HTTP), `create_task_result/3'.</li>
%%%   <li>Multi round-trip requests: `input_required' rounds and the
%%%       sealed `request_state'.</li>
%%%   <li>Request handlers: one `handle_request/4' clause per method.</li>
%%%   <li>Notification handlers.</li>
%%%   <li>Internal functions, cursor pagination, envelope helpers.</li>
%%% </ul>
%%%
%%% == Processes ==
%%%
%%% Everything here runs in the caller's process (a request process
%%% under HTTP, a worker under stdio) except the task collector,
%%% which `spawn_task_collector/3' starts to outlive the request. See
%%% the Server Internals guide for the process model and the hop
%%% list of a request.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_protocol).

-include("barrel_mcp.hrl").

%% API
-export([
    decode/1,
    encode/1,
    handle/1,
    handle/2,
    error_response/3,
    error_response/4,
    success_response/2,
    success_response/3,
    notification_response/0,
    finalize/2,
    input_required_envelope/4,
    task_owner/1,
    tasks_enabled/1,
    create_task_result/3,
    missing_tasks_capability/1,
    spawn_task_collector/3
]).

%% JSON-RPC envelope helpers (shared by client + server)
-export([
    encode_request/3,
    encode_notification/2,
    encode_response/2,
    encode_error/3,
    decode_envelope/1,
    format_tool_result_external/1,
    drive_async_plan/2,
    drive_async_plan/3,
    drive_async_plan/4
]).

%% How long `tasks/result' waits for a task to finish before giving up.
-define(TASK_RESULT_TIMEOUT, 300000).

%% How long one element of a batch may take. A batch is answered as a
%% whole, so a slow element holds the rest.
-define(BATCH_ELEMENT_TIMEOUT, 60000).

%% Deepest JSON nesting accepted from a peer. Well past anything MCP
%% defines, and far below what would trouble the stack.
-define(DEFAULT_MAX_JSON_DEPTH, 64).

%% What the transport gets back from `handle/1,2'. See its doc for what
%% each shape obliges the transport to do.
-type result() ::
    map()
    | [map()]
    | no_response
    | {async, map()}
    | {subscribe, map()}.

-export_type([result/0]).

%%====================================================================
%% API
%%====================================================================

%% @doc Decode a JSON-RPC request body. The spec includes `list()'
%% in the success type so the HTTP transport can detect (and reject)
%% JSON-RPC batches.
-spec decode(binary()) -> {ok, map() | list()} | {error, term()}.
decode(Binary) ->
    Max = application:get_env(barrel_mcp, max_json_depth, ?DEFAULT_MAX_JSON_DEPTH),
    Depth = counters:new(1, []),
    try json:decode(Binary, ok, depth_counting_decoders(Depth, Max)) of
        {Term, _Acc, <<>>} -> {ok, Term};
        {_Term, _Acc, _Trailing} -> {error, parse_error}
    catch
        error:too_deep -> {error, too_deep};
        _:_ -> {error, parse_error}
    end.

%% Nesting is bounded by the parser itself rather than by a scan of our
%% own, so the limit cannot disagree with what is actually built. A
%% document deep enough to exhaust the stack is rejected before the term
%% exists, which a check on the finished term could not do.
depth_counting_decoders(Depth, Max) ->
    Enter = fun() ->
        counters:add(Depth, 1, 1),
        case counters:get(Depth, 1) > Max of
            true -> error(too_deep);
            false -> ok
        end
    end,
    Leave = fun() -> counters:sub(Depth, 1, 1) end,
    #{
        object_start => fun(_Acc) ->
            Enter(),
            []
        end,
        object_push => fun(Key, Value, Acc) -> [{Key, Value} | Acc] end,
        %% Not reversed: `maps:from_list/1' keeps the rightmost of any
        %% duplicate key, and the accumulator is in reverse document
        %% order, so the first occurrence wins. That is what the default
        %% decoder does, and a batch of duplicate keys must not decode
        %% differently here than it would there.
        object_finish => fun(Acc, OldAcc) ->
            Leave(),
            {maps:from_list(Acc), OldAcc}
        end,
        array_start => fun(_Acc) ->
            Enter(),
            []
        end,
        array_push => fun(Value, Acc) -> [Value | Acc] end,
        array_finish => fun(Acc, OldAcc) ->
            Leave(),
            {lists:reverse(Acc), OldAcc}
        end
    }.

%% @doc Encode a JSON-RPC response, or a batch of them.
-spec encode(map() | [map()]) -> binary().
encode(Response) ->
    iolist_to_binary(json:encode(Response)).

%% @doc Handle a JSON-RPC request with default state.
-spec handle(map() | list()) -> result().
handle(Request) ->
    handle(Request, #{}).

%% @doc Handle a JSON-RPC request with state.
%%
%% Returns one of:
%% <ul>
%%   <li>`map()': a JSON-RPC response envelope ready to encode.</li>
%%   <li>`[map()]': one envelope per request element of a batch, on
%%       the revisions that accept batches.</li>
%%   <li>`no_response': for inbound notifications, and for a batch of
%%       nothing but notifications and responses.</li>
%%   <li>`{async: AsyncPlan}', for `tools/call'. The transport
%%       spawns the worker via `(maps:get(spawn, AsyncPlan))(Ctx)'
%%       and waits on its mailbox for a `tool_result' / `tool_error' /
%%       `tool_failed' / `tool_validation_failed' / `cancelled'
%%       message.</li>
%%   <li>`{subscribe, Sub}': for `subscriptions/listen', which needs a
%%       stream the transport holds open.</li>
%% </ul>
%%
%% A top-level JSON array is a batch. Whether one is accepted depends on
%% the negotiated revision: required at 2025-03-26, accepted at
%% 2024-11-05, and refused with `Invalid Request' from 2025-06-18 on.
-spec handle(map() | list(), map()) -> result().
handle(L, State) when is_list(L) ->
    Revision = maps:get(protocol_version, State, undefined),
    case barrel_mcp_version:feature(batch_receive, Revision) of
        disabled ->
            error_response(
                null,
                ?JSONRPC_INVALID_REQUEST,
                <<"Batch requests are not supported">>
            );
        _Accepted ->
            handle_batch(L, State)
    end;
handle(#{<<"jsonrpc">> := <<"2.0">>, <<"method">> := Method} = Request, State) ->
    %% A peer controls both fields. The method is interpolated into
    %% binaries and the params are read with `maps:get/3', so a method
    %% that is not a string, or params that are not an object, raise
    %% `badarg' several frames deeper. Over stdio that ends the server.
    %% Reject here, where there is still an id to answer with.
    case {validate_envelope(Method, Request), maps:is_key(<<"id">>, Request)} of
        {{error, _Reason}, false} ->
            %% A notification, and JSON-RPC forbids replying to one even
            %% when it is malformed. Drop it.
            no_response;
        {{error, Reason}, true} ->
            error_response(id_or_null(Request), ?JSONRPC_INVALID_REQUEST, Reason);
        {ok, _} ->
            dispatch_envelope(Method, Request, State)
    end;
handle(#{<<"id">> := Id}, _State) when is_binary(Id); is_integer(Id) ->
    error_response(Id, ?JSONRPC_INVALID_REQUEST, <<"Invalid Request">>);
handle(_, _State) ->
    error_response(null, ?JSONRPC_INVALID_REQUEST, <<"Invalid Request">>).

%%====================================================================
%% Batches
%%
%% JSON-RPC allows an array of requests and/or notifications, or an
%% array of responses. It does not allow the two mixed, and the two are
%% answered differently: a malformed request can be told so, a
%% malformed response cannot, because a response is not something one
%% replies to.
%%====================================================================

handle_batch([], _State) ->
    error_response(null, ?JSONRPC_INVALID_REQUEST, <<"Invalid Request: empty batch">>);
handle_batch(Elements, State) ->
    case batch_category(Elements) of
        mixed ->
            error_response(
                null,
                ?JSONRPC_INVALID_REQUEST,
                <<"Invalid Request: a batch may not mix requests and responses">>
            );
        responses ->
            %% Nothing to answer. The transport reports acceptance by
            %% status alone, and a malformed element is dropped rather
            %% than described, since there is no request to describe it
            %% against.
            no_response;
        calls ->
            Answers = [batch_element(E, State) || E <- Elements],
            case [R || R <- Answers, R =/= no_response] of
                [] -> no_response;
                Responses -> Responses
            end
    end.

%% An array is one kind or the other. An element that is neither counts
%% as a call, so it earns an individual error rather than silence.
batch_category(Elements) ->
    Kinds = lists:usort([element_kind(E) || E <- Elements]),
    case Kinds of
        [response] ->
            responses;
        _ ->
            case lists:member(response, Kinds) of
                true -> mixed;
                false -> calls
            end
    end.

element_kind(E) when is_map(E) ->
    case
        {maps:is_key(<<"method">>, E), maps:is_key(<<"result">>, E), maps:is_key(<<"error">>, E)}
    of
        {true, _, _} -> call;
        {false, true, _} -> response;
        {false, _, true} -> response;
        _ -> call
    end;
element_kind(_E) ->
    call.

%% One element of a call batch. A tool call yields an async plan that
%% nobody else will drive, so it is driven here: a batch is a legacy
%% compatibility path and the caller is waiting on the whole array.
batch_element(Element, State) when is_map(Element) ->
    case handle(Element, State) of
        {async, Plan} ->
            drive_async_plan(Plan, ?BATCH_ELEMENT_TIMEOUT);
        no_response ->
            no_response;
        Response when is_map(Response) ->
            Response;
        _Stream ->
            %% Only a held-open stream is neither, and no revision that
            %% accepts batches has one. Refusing beats encoding a
            %% handle into an array.
            error_response(
                id_or_null(Element),
                ?JSONRPC_INTERNAL_ERROR,
                <<"Internal error">>
            )
    end;
batch_element(_Element, _State) ->
    error_response(null, ?JSONRPC_INVALID_REQUEST, <<"Invalid Request">>).

%% The method must be a string and `params', when present, an object.
%% Checked before anything reads either field. `params' itself stays
%% optional.
validate_envelope(Method, _Request) when not is_binary(Method) ->
    {error, <<"Invalid Request: method must be a string">>};
validate_envelope(_Method, Request) ->
    case maps:find(<<"params">>, Request) of
        {ok, P} when not is_map(P) ->
            {error, <<"Invalid Request: params must be an object">>};
        _ ->
            ok
    end.

%% An id worth echoing, or `null'. A malformed id is not echoed back:
%% JSON-RPC wants `null' when the id cannot be determined.
id_or_null(Request) ->
    case maps:get(<<"id">>, Request, undefined) of
        Id when is_binary(Id); is_integer(Id) -> Id;
        _ -> null
    end.

dispatch_envelope(Method, Request, State) ->
    Params = maps:get(<<"params">>, Request, #{}),
    Ctx = barrel_mcp_ctx:from_request(Request, State),
    case maps:find(<<"id">>, Request) of
        error ->
            %% No id: this is a notification, so no response.
            handle_notification(Method, Params, Ctx),
            no_response;
        {ok, Id} when is_binary(Id); is_integer(Id) ->
            dispatch(Method, Params, Id, Ctx);
        {ok, _BadId} ->
            %% MCP requires id to be a string or integer (and not
            %% null). Anything else is an Invalid Request.
            error_response(
                null,
                ?JSONRPC_INVALID_REQUEST,
                <<"Invalid Request: id must be a string or integer">>
            )
    end.

%% @doc Create an error response.
-spec error_response(term(), integer(), binary()) -> map().
error_response(Id, Code, Message) ->
    error_response(Id, Code, Message, #{}).

%% Optional `_meta' map on the error object. Empty map is omitted from
%% the wire. MCP defines `_meta' on results, not on errors, so this is
%% a barrel_mcp extension for hosts that want to thread state; it is
%% carried inside the error object rather than beside it so it cannot
%% be mistaken for a JSON-RPC member.
-spec error_response(term(), integer(), binary(), map()) -> map().
error_response(Id, Code, Message, Meta) ->
    Err = #{
        <<"code">> => Code,
        <<"message">> => Message
    },
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => with_meta(Err, Meta)
    }.

%% @doc Error response carrying a JSON-RPC `data' member.
%%
%% `data' is where the 2026-07-28 error codes put their payload:
%% `supported' / `requested' on UnsupportedProtocolVersion,
%% `requiredCapabilities' on MissingRequiredClientCapability.
-spec error_with_data(term(), integer(), binary(), term()) -> map().
error_with_data(Id, Code, Message, Data) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => #{
            <<"code">> => Code,
            <<"message">> => Message,
            <<"data">> => Data
        }
    }.

%% @doc Return a marker for no response (notifications).
-spec notification_response() -> no_response.
notification_response() ->
    no_response.

%%====================================================================
%% Era dispatch
%%====================================================================

%% Gate a request on its era, its `_meta' and its version, run it, then
%% decorate the result.
%%
%% A method the era does not have is not found whatever else is wrong
%% with the request, and malformed `_meta' is answered before the
%% version it failed to state: "unsupported version: undefined" names
%% the wrong problem.
dispatch(Method, Params, Id, Ctx) ->
    case serves(Method, Ctx) of
        false ->
            error_response(
                Id,
                ?JSONRPC_METHOD_NOT_FOUND,
                <<"Method not found: ", Method/binary>>
            );
        true ->
            dispatch_versioned(Method, Params, Id, Ctx)
    end.

dispatch_versioned(Method, Params, Id, Ctx) ->
    case barrel_mcp_ctx:validate_version(Ctx) of
        {error, Reason} ->
            meta_error(Id, Reason);
        ok ->
            case check_version(Ctx) of
                {error, Requested} -> unsupported_version_error(Id, Requested);
                ok -> dispatch_valid(Method, Params, Id, Ctx)
            end
    end.

dispatch_valid(Method, Params, Id, Ctx) ->
    case barrel_mcp_ctx:validate(Ctx) of
        {error, Reason} ->
            meta_error(Id, Reason);
        ok ->
            Response = handle_request(Method, Params, Id, Ctx),
            finalize(with_cache_hints(Method, Response, Ctx), Ctx)
    end.

meta_error(Id, {missing_meta, Key}) ->
    error_response(
        Id,
        ?JSONRPC_INVALID_PARAMS,
        <<"Missing required _meta field: ", Key/binary>>
    );
meta_error(Id, {invalid_meta, Key}) ->
    error_response(
        Id,
        ?JSONRPC_INVALID_PARAMS,
        <<"Invalid _meta field: ", Key/binary>>
    ).

%% Only modern requests declare a version per request. A legacy one
%% negotiated its version at `initialize', which validated it there.
check_version(Ctx) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        false ->
            ok;
        true ->
            %% Against the advertised list, not the compiled one: an
            %% operator serving only legacy clients refuses the modern
            %% era, and the probe is what a client falls back from.
            Requested = barrel_mcp_ctx:protocol_version(Ctx),
            Modern = [V || V <- advertised_versions(), lists:member(V, ?MCP_MODERN_VERSIONS)],
            case lists:member(Requested, Modern) of
                true -> ok;
                false -> {error, Requested}
            end
    end.

unsupported_version_error(Id, Requested) ->
    error_with_data(
        Id,
        ?MCP_UNSUPPORTED_PROTOCOL_VERSION,
        <<"Unsupported protocol version">>,
        #{
            <<"supported">> => advertised_versions(),
            <<"requested">> => Requested
        }
    ).

%% @doc The protocol revisions this server advertises, newest first.
%%
%% Controlled by the `advertise_versions' env:
%% <ul>
%%   <li>`modern' (default): only the stateless revisions. This is what
%%       a client can retry a rejected request with: the spec has it
%%       select from this list and re-send, and a legacy revision named
%%       in per-request metadata is rejected again, so advertising one
%%       here invites a loop. Legacy clients are unaffected; they never
%%       see this list and the `initialize' handshake still works.</li>
%%   <li>`all': both eras, for operators who want the full picture
%%       advertised. A client offered a legacy revision has to drop to
%%       the handshake to use it.</li>
%% </ul>
-spec advertised_versions() -> [binary()].
advertised_versions() ->
    case application:get_env(barrel_mcp, advertise_versions, modern) of
        all -> ?MCP_ALL_VERSIONS;
        legacy -> ?MCP_LEGACY_VERSIONS;
        _ -> ?MCP_MODERN_VERSIONS
    end.

serves(Method, Ctx) ->
    serves_in_era(Method, barrel_mcp_ctx:era(Ctx)) andalso
        serves_in_revision(Method, barrel_mcp_ctx:protocol_version(Ctx)).

serves_in_era(Method, legacy) ->
    not lists:member(Method, ?MODERN_ONLY_METHODS);
serves_in_era(Method, modern) ->
    not lists:member(Method, ?LEGACY_ONLY_METHODS).

%% The era says which family a method belongs to; the revision says
%% whether it existed yet. Tasks are the case that needs both: they are
%% legacy methods, but only from 2025-11-25.
%%
%% An un-negotiated connection is not gated. A limit defaults to the
%% strict side because guessing wrong there costs nothing; refusing a
%% method the peer does have is a different failure, and before
%% `initialize' there is no evidence either way.
serves_in_revision(_Method, undefined) ->
    true;
serves_in_revision(<<"tasks/", _/binary>>, Revision) ->
    barrel_mcp_version:has(tasks, Revision) orelse
        barrel_mcp_version:has(tasks_extension, Revision);
serves_in_revision(_Method, _Revision) ->
    true.

%% 2026-07-28 realigned resource-not-found onto the JSON-RPC
%% invalid-params code. Legacy clients still expect -32002, and the
%% spec asks modern clients to keep accepting it from older servers.
resource_not_found_code(Ctx) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        true -> ?JSONRPC_INVALID_PARAMS;
        false -> ?MCP_RESOURCE_NOT_FOUND
    end.

%% `-32000' and `-32001' sit in the `-32000' to `-32019' sub-range that
%% 2026-07-28 reserved as legacy and that new implementations "SHOULD
%% NOT use ... at all" (basic/index.mdx:117). A server error is a
%% protocol error (server/tools.mdx:742), so modern gets the JSON-RPC
%% code for one. Legacy keeps what its clients expect.
internal_error_code(Ctx) ->
    case is_modern_ctx(Ctx) of
        true -> ?JSONRPC_INTERNAL_ERROR;
        false -> ?MCP_TOOL_ERROR
    end.

resource_error_code(Ctx) ->
    case is_modern_ctx(Ctx) of
        true -> ?JSONRPC_INTERNAL_ERROR;
        false -> ?MCP_RESOURCE_ERROR
    end.

is_modern_ctx(Ctx) when is_map(Ctx) -> barrel_mcp_ctx:is_modern(Ctx);
is_modern_ctx(_Ctx) -> false.

%% How long a task collector waits to be told which process it is
%% collecting for. The handoff happens immediately after the worker is
%% spawned; this only bounds the case where spawning failed.
-define(WORKER_HANDOFF_MS, 30000).

%% Results the 2026-07-28 revision made cacheable. The hints complement
%% `listChanged' notifications rather than replacing them: a client that
%% subscribes hears about a change immediately, and one that does not
%% still refreshes within the TTL.
-define(CACHEABLE_METHODS, [
    <<"tools/list">>,
    <<"prompts/list">>,
    <<"resources/list">>,
    <<"resources/templates/list">>,
    <<"resources/read">>
]).

%% Add the freshness hints, unless the handler already set its own.
%%
%% Never on a multi round-trip retry: a result produced from
%% `inputResponses' or a `requestState' "MUST NOT be cached, as they
%% depend on inputs that are not part of the cache key"
%% (2026-07-28/server/utilities/caching.mdx:34).
with_cache_hints(Method, #{<<"result">> := Result} = Envelope, Ctx) when is_map(Result) ->
    Cacheable =
        barrel_mcp_ctx:is_modern(Ctx) andalso
            lists:member(Method, ?CACHEABLE_METHODS) andalso
            not retried_with_input(Ctx),
    case Cacheable of
        true -> Envelope#{<<"result">> => cacheable(Result)};
        false -> Envelope
    end;
with_cache_hints(_Method, Response, _Ctx) ->
    Response.

cacheable(Result) ->
    WithTtl =
        case maps:is_key(<<"ttlMs">>, Result) of
            true -> Result;
            false -> Result#{<<"ttlMs">> => cache_ttl_ms()}
        end,
    case maps:is_key(<<"cacheScope">>, WithTtl) of
        true -> WithTtl;
        false -> WithTtl#{<<"cacheScope">> => cache_scope()}
    end.

retried_with_input(Ctx) ->
    map_size(barrel_mcp_ctx:input_responses(Ctx)) > 0 orelse
        barrel_mcp_ctx:request_state(Ctx) =/= undefined.

%% "Servers MUST provide a `ttlMs' value that is >= 0"
%% (caching.mdx:60), so a misconfigured negative is floored rather than
%% put on the wire.
cache_ttl_ms() ->
    max(0, application:get_env(barrel_mcp, cache_ttl_ms, 60000)).

%% `private' by default, deliberately. `public' lets a shared
%% intermediary serve one caller's response to another, which is only
%% safe when every caller sees the same catalogue. A server that
%% filters tools or resources by principal would leak one principal's
%% view to the next, so opting into `public' has to be a decision the
%% deployment makes, not a default it inherits.
cache_scope() ->
    application:get_env(barrel_mcp, cache_scope, <<"private">>).

%% @doc Stamp the fields a modern result must carry: `resultType', and
%% `serverInfo' in the result's `_meta'.
%%
%% Public so transports that build a response envelope themselves (the
%% async tool path in `barrel_mcp_http_engine') decorate it the same
%% way. Legacy results, error responses and notifications pass through
%% untouched, as does anything with no context.
-spec finalize(
    map() | no_response | {async, map()} | {subscribe, map()},
    barrel_mcp_ctx:ctx() | undefined
) ->
    map() | no_response | {async, map()} | {subscribe, map()}.
finalize({subscribe, Sub}, _Ctx) ->
    {subscribe, Sub};
finalize({async, Plan}, Ctx) ->
    %% The transport finishes this one; hand it the context so it can
    %% decorate the envelope it builds.
    {async, Plan#{ctx => Ctx}};
finalize(Envelope, undefined) ->
    Envelope;
finalize(#{<<"result">> := Result} = Envelope, Ctx) when is_map(Result) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        true -> Envelope#{<<"result">> => decorate_result(Result)};
        false -> Envelope
    end;
finalize(Envelope, _Ctx) ->
    Envelope.

%% `resultType' is only defaulted, never overwritten: MRTR and the
%% tasks extension set their own ("input_required", "task").
decorate_result(Result) ->
    Typed =
        case maps:is_key(<<"resultType">>, Result) of
            true -> Result;
            false -> Result#{<<"resultType">> => <<"complete">>}
        end,
    case server_info_meta() of
        undefined ->
            Typed;
        Info ->
            Meta = maps:get(<<"_meta">>, Typed, #{}),
            Typed#{<<"_meta">> => Meta#{?MCP_META_SERVER_INFO => Info}}
    end.

%% The spec asks servers to identify themselves in every result, unless
%% deliberately configured not to.
server_info_meta() ->
    case application:get_env(barrel_mcp, send_server_info, true) of
        false -> undefined;
        _ -> server_info()
    end.

server_info() ->
    #{
        <<"name">> => application:get_env(barrel_mcp, server_name, <<"barrel">>),
        <<"version">> => application:get_env(barrel_mcp, server_version, <<"1.0.0">>)
    }.

%% What an `initialize' response advertises, for the revision that was
%% just negotiated. `subscribe' and `logging' exist in every
%% handshake-based revision; tasks arrived at 2025-11-25, so an older
%% client must not be told the server has them.
legacy_capabilities(Revision) ->
    Base = #{
        <<"tools">> => #{<<"listChanged">> => true},
        <<"resources">> => #{
            <<"subscribe">> => true,
            <<"listChanged">> => true
        },
        <<"prompts">> => #{<<"listChanged">> => true},
        <<"logging">> => #{}
    },
    case barrel_mcp_version:has(tasks, Revision) of
        false ->
            Base;
        true ->
            %% Per the MCP tasks SEP (and as enforced by the reference
            %% Python SDK), each operation key is an object whose
            %% presence advertises support; only `listChanged' is a bare
            %% boolean.
            Base#{
                <<"tasks">> => #{
                    <<"list">> => #{},
                    <<"get">> => #{},
                    <<"cancel">> => #{},
                    <<"result">> => #{},
                    <<"listChanged">> => true
                }
            }
    end.

%% What `server/discover' advertises. Discovery is a modern-era method,
%% so it describes the modern surface: no `subscribe' (subsumed by
%% `subscriptions/listen'), no `logging' (removed), no core `tasks'
%% (they moved into the extension advertised under `extensions').
modern_capabilities() ->
    #{
        <<"tools">> => #{<<"listChanged">> => true},
        <<"resources">> => #{<<"listChanged">> => true},
        <<"prompts">> => #{<<"listChanged">> => true},
        <<"extensions">> => #{?MCP_EXT_TASKS => #{}}
    }.

%% Tool dispatch is asynchronous. The transport drives the lifecycle:
%% it builds `Ctx', invokes the spawn closure, records the in-flight
%% entry, and waits on its mailbox for one of `{tool_result, _, _}',
%% `{tool_error, _, _}', `{tool_input_required, _, _, _}',
%% `{tool_failed, _, _}', `{tool_validation_failed, _, _}', or
%% `{cancelled, _}' (sent by `barrel_mcp_session:cancel_in_flight/2').
tool_call_plan(Params, Id, Ctx, Mrtr) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    Args = maps:get(<<"arguments">>, Params, #{}),
    Plan = #{
        request_id => Id,
        tool_name => Name,
        meta => maps:get(<<"_meta">>, Params, #{}),
        %% Carried so whichever transport finishes the call can seal a
        %% new state against the same request.
        mrtr_binding => {<<"tools/call">>, Params},
        spawn => fun(TransportCtx) ->
            ToolCtx = TransportCtx#{mcp_ctx => Ctx, mrtr => Mrtr},
            case barrel_mcp_registry:run_tool(Name, Args, ToolCtx) of
                {ok, Pid} ->
                    Pid;
                {error, _} = Err ->
                    %% Surface as if the worker reported it: the
                    %% transport then maps the error.
                    ReplyTo = maps:get(reply_to, ToolCtx),
                    RequestId = maps:get(request_id, ToolCtx),
                    ReplyTo ! {tool_failed, RequestId, Err},
                    undefined
            end
        end
    },
    {async, Plan}.

%% @doc A tool that could not run, as the error result the reference
%% implementation returns for it.
%%
%% Both Python SDK generations turn every exception in the tool-call
%% handler into a CallToolResult with isError, never a protocol error
%% (v2 mcp/server/mcpserver/server.py:424, v1 lowlevel/server.py:472),
%% and an unknown tool raises ToolError("Unknown tool: <name>") into
%% that same branch (tools/tool_manager.py:72). That is what clients on
%% the wire expect and what the official conformance runner asserts.
%%
%% 2026-07-28/server/tools.mdx:742-745 lists an unknown tool under
%% protocol errors instead. The reference implementation wins here;
%% this comment is so the disagreement is not rediscovered.
%%
%% Crash details stay logged server-side by the registry. Only the
%% unknown-tool case carries a name; everything else is a fixed text,
%% since a reason can hold paths or secret-bearing exception terms.
tool_failure_result(Reason) ->
    Text =
        case Reason of
            {error, {not_found, tool, Name}} when is_binary(Name) ->
                <<"Unknown tool: ", Name/binary>>;
            _ ->
                <<"Internal tool error">>
        end,
    #{
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => Text}],
        <<"isError">> => true
    }.

%% @doc Turn a handler's `{input_required, Requests, State}' into the
%% JSON-RPC envelope for it, given the plan that produced the call.
%%
%% Shared by every transport so an MRTR turn looks the same whichever
%% one served it.
-spec input_required_envelope(map(), map(), term(), term()) -> map().
input_required_envelope(Plan, Requests, State, RequestId) ->
    case maps:get(ctx, Plan, undefined) of
        undefined ->
            mrtr_unavailable(RequestId, <<"no request context">>);
        Ctx ->
            case maps:get(mrtr_binding, Plan, undefined) of
                {Method, Params} ->
                    seal_input_required(
                        Requests, State, Method, Params, Ctx, RequestId
                    );
                _ ->
                    mrtr_unavailable(RequestId, <<"no request binding">>)
            end
    end.

seal_input_required(Requests, State, Method, Params, Ctx, RequestId) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        false ->
            %% MRTR is a 2026-07-28 pattern. A legacy client has the
            %% blocking server-to-client calls instead, so a handler
            %% returning this to one is a programming error.
            mrtr_unavailable(RequestId, <<"legacy client">>);
        true ->
            case input_required_result(Requests, State, Method, Params, Ctx) of
                {ok, Result} ->
                    success_response(RequestId, Result);
                {error, Missing} ->
                    error_with_data(
                        RequestId,
                        ?MCP_MISSING_CLIENT_CAPABILITY,
                        <<"Client did not declare a required capability">>,
                        #{<<"requiredCapabilities">> => capabilities_object(Missing)}
                    )
            end
    end.

mrtr_unavailable(RequestId, Why) ->
    logger:error(
        "Tool returned {input_required, _, _} but it cannot be served: ~s "
        "(request_id=~p)",
        [Why, RequestId]
    ),
    error_response(
        RequestId,
        ?JSONRPC_INTERNAL_ERROR,
        <<"Internal tool error">>
    ).

%%====================================================================
%% Tasks
%%====================================================================

%% The extension makes -32021 a MUST for a client that calls a task
%% method without declaring the extension: it would otherwise be told to
%% poll something it does not know it can call. Read from this request's
%% own `_meta', never a capability remembered from an earlier one.
with_tasks_extension(Id, Ctx, Fun) ->
    case barrel_mcp_ctx:is_modern(Ctx) andalso not tasks_enabled(Ctx) of
        true ->
            error_with_data(
                Id,
                ?MCP_MISSING_CLIENT_CAPABILITY,
                <<"Client did not declare a required capability">>,
                #{<<"requiredCapabilities">> => extension_object(?MCP_EXT_TASKS)}
            );
        false ->
            Fun()
    end.

%% @doc Who a task belongs to, which differs by era.
%%
%% A legacy task is scoped to its session. A modern request has no
%% session, so it is scoped to the authenticated principal instead;
%% without one that is `{principal, undefined}', which is still a real
%% scope and not a wildcard.
-spec task_owner(barrel_mcp_ctx:ctx()) -> term().
task_owner(Ctx) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        true -> {principal, barrel_mcp_ctx:principal(Ctx)};
        false -> barrel_mcp_ctx:session_id(Ctx)
    end.

%% @doc Whether this client opted into receiving task handles.
%%
%% A server must never hand a task to a client that did not declare the
%% extension: it would poll a method it does not know it can call.
%% Legacy clients negotiated tasks in the handshake instead.
-spec tasks_enabled(barrel_mcp_ctx:ctx()) -> boolean().
tasks_enabled(Ctx) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        true -> barrel_mcp_ctx:supports_extension(Ctx, ?MCP_EXT_TASKS);
        false -> true
    end.

task_support(Name) ->
    barrel_mcp_registry:task_support(Name).

%% @doc Run a tool's outcome into its task rather than back to the
%% caller, which has already been handed the task id.
%%
%% Takes the spawn rather than returning a bare collector so the worker
%% cannot be started without the collector being told to watch it: that
%% handoff is what keeps a worker that dies silently from stranding the
%% task, and a second call site would otherwise be free to forget it.
%% `undefined' when the tool could not be started at all, which the
%% collector settles as `no_worker'.
-spec spawn_task_collector(term(), binary(), fun((pid()) -> pid() | undefined)) ->
    {pid(), pid() | undefined}.
spawn_task_collector(Owner, TaskId, SpawnWorker) ->
    Collector = spawn(fun() -> task_collector_init(Owner, TaskId) end),
    Worker = SpawnWorker(Collector),
    Collector ! {task_worker, Worker},
    {Collector, Worker}.

%% The worker is spawned after this process, so it cannot be watched
%% until the caller hands its pid over. Until then a worker that dies
%% without reporting would leave the collector blocked and the task
%% `working' forever, and the sweep never evicts a working task.
%%
%% The timeout covers the caller failing to spawn a worker at all: the
%% handoff is immediate when it happens.
task_collector_init(Owner, TaskId) ->
    receive
        {task_worker, undefined} ->
            barrel_mcp_tasks:fail(Owner, TaskId, no_worker);
        {task_worker, Worker} ->
            _ = monitor(process, Worker),
            task_collector_loop(Owner, TaskId)
    after ?WORKER_HANDOFF_MS ->
        barrel_mcp_tasks:fail(Owner, TaskId, no_worker)
    end.

task_collector_loop(Owner, TaskId) ->
    receive
        {tool_result, _ReqId, Result} ->
            barrel_mcp_tasks:finish(Owner, TaskId, #{
                <<"content">> => format_tool_result_external(Result)
            });
        {tool_result_meta, _ReqId, Result, _Meta} ->
            barrel_mcp_tasks:finish(Owner, TaskId, #{
                <<"content">> => format_tool_result_external(Result)
            });
        {tool_structured, _ReqId, Data, Content} ->
            barrel_mcp_tasks:finish(Owner, TaskId, #{
                <<"content">> => Content,
                <<"structuredContent">> => Data
            });
        {tool_structured_meta, _ReqId, Data, Content, _Meta} ->
            barrel_mcp_tasks:finish(Owner, TaskId, #{
                <<"content">> => Content,
                <<"structuredContent">> => Data
            });
        {tool_error, _ReqId, Content} ->
            %% A tool that reports a domain failure has still completed.
            %% `failed' is for protocol errors, and the extension
            %% requires the CallToolResult with isError to be the task's
            %% result rather than an error object.
            barrel_mcp_tasks:finish(Owner, TaskId, #{
                <<"content">> => format_tool_result_external(Content),
                <<"isError">> => true
            });
        {tool_failed, _ReqId, Reason} ->
            barrel_mcp_tasks:fail(Owner, TaskId, Reason);
        {tool_validation_failed, _ReqId, Errors} ->
            barrel_mcp_tasks:fail(Owner, TaskId, {validation_failed, Errors});
        {tool_input_required, _ReqId, Requests, HandlerState} ->
            task_input_round(Owner, TaskId, Requests, HandlerState);
        {cancelled, _ReqId} ->
            barrel_mcp_tasks:cancel(Owner, TaskId);
        %% The worker died without reporting. A result sent before it
        %% exited is already ahead of this in the mailbox and matched
        %% above, so reaching here means nothing is coming.
        {'DOWN', _Ref, process, _Pid, Reason} ->
            barrel_mcp_tasks:fail(Owner, TaskId, {worker_died, Reason});
        _Other ->
            task_collector_loop(Owner, TaskId)
    end.

%% Rendered for the era that asked, since the retention field is named
%% `ttl' before the extension and `ttlMs' in it.
read_task_for(Owner, TaskId, Ctx) ->
    Era = barrel_mcp_ctx:era(Ctx),
    case barrel_mcp_tasks:get(Owner, TaskId, Era) of
        {ok, T} -> T;
        _ -> #{<<"taskId">> => TaskId, <<"status">> => <<"working">>}
    end.

%% Run the handler again, reporting into the same task. This is a fresh
%% worker: nothing of the original one survived its return.
resume_task(Owner, TaskId, Info, Ctx) ->
    #{params := Params, responses := Responses, methods := Methods, state := HState} = Info,
    Name = maps:get(<<"name">>, Params, <<>>),
    Args = maps:get(<<"arguments">>, Params, #{}),
    Mrtr = #{responses => Responses, methods => Methods, state => HState},
    spawn_task_collector(Owner, TaskId, fun(Collector) ->
        ToolCtx = #{
            request_id => TaskId,
            session_id => barrel_mcp_ctx:session_id(Ctx),
            progress_token => undefined,
            meta => #{},
            emit_progress => fun(_, _, _) -> ok end,
            emit_log => fun(_, _, _) -> ok end,
            reply_to => Collector,
            auth_info => barrel_mcp_ctx:auth_info(Ctx),
            mcp_ctx => Ctx,
            mrtr => Mrtr
        },
        case barrel_mcp_registry:run_tool(Name, Args, ToolCtx) of
            {ok, Pid} ->
                Pid;
            {error, _} = Err ->
                Collector ! {tool_failed, TaskId, Err},
                undefined
        end
    end).

%% Exactly what the underlying request would have returned, which is
%% the whole point of the method: a successful result or its error.
task_result_response(#{<<"status">> := <<"completed">>} = Task, Id) ->
    success_response(Id, maps:get(<<"result">>, Task, #{}));
task_result_response(#{<<"status">> := <<"failed">>} = Task, Id) ->
    case maps:get(<<"error">>, Task, undefined) of
        #{<<"code">> := Code, <<"message">> := Message} ->
            error_response(Id, Code, Message);
        Other ->
            error_response(Id, ?MCP_TOOL_ERROR, format_task_error(Other))
    end;
task_result_response(#{<<"status">> := <<"cancelled">>}, Id) ->
    error_response(Id, ?JSONRPC_INVALID_PARAMS, <<"Task cancelled">>);
task_result_response(_Task, Id) ->
    error_response(Id, ?JSONRPC_INTERNAL_ERROR, <<"Task not terminal">>).

format_task_error(undefined) -> <<"Task failed">>;
format_task_error(B) when is_binary(B) -> B;
format_task_error(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

%% The eras ask completely differently, though the status is the same.
%%
%% A legacy task has a session and a stream to send down, so the server
%% issues real requests and waits for the answers, exactly as a
%% non-task handler does. A modern one has no back-channel, so the task
%% parks and publishes what it wants; the client answers through
%% `tasks/update'.
task_input_round(Owner, TaskId, Requests, HandlerState) when is_binary(Owner) ->
    case legacy_input_answers(Owner, TaskId, Requests) of
        {ok, Responses} ->
            resume_legacy_task(Owner, TaskId, Responses, HandlerState);
        {error, Reason} ->
            barrel_mcp_tasks:fail(Owner, TaskId, input_error(Reason))
    end;
task_input_round(Owner, TaskId, Requests, HandlerState) ->
    case
        barrel_mcp_tasks:await_input(
            Owner, TaskId, Requests, HandlerState, task_params(TaskId, Owner)
        )
    of
        ok ->
            ok;
        {error, Reason} ->
            barrel_mcp_tasks:fail(Owner, TaskId, input_error(Reason))
    end.

%% Issued through the session's own pending-request registry, the same
%% one sampling, elicitation and roots already use, so an id is never
%% allocated twice for one session and a response routes back the usual
%% way. Every message carries the related-task metadata the legacy
%% specification requires.
legacy_input_answers(SessionId, TaskId, Requests) ->
    Meta = #{?MCP_META_RELATED_TASK => #{<<"taskId">> => TaskId}},
    maps:fold(
        fun
            (_Key, _Request, {error, _} = Err) ->
                Err;
            (Key, Request, {ok, Acc}) ->
                case legacy_input_answer(SessionId, Request, Meta) of
                    {ok, Response} -> {ok, Acc#{Key => Response}};
                    {error, _} = Err -> Err
                end
        end,
        {ok, #{}},
        Requests
    ).

legacy_input_answer(SessionId, Request, Meta) ->
    Params = with_related_task(request_params(Request), Meta),
    case request_method(Request) of
        <<"elicitation/create">> ->
            barrel_mcp_session:elicit_create(SessionId, Params, #{});
        <<"sampling/createMessage">> ->
            case barrel_mcp_session:sampling_create_message(SessionId, Params, #{}) of
                {ok, Result, _Usage} -> {ok, Result};
                {error, _} = Err -> Err
            end;
        <<"roots/list">> ->
            case barrel_mcp_session:roots_list(SessionId, #{}) of
                {ok, Roots} -> {ok, #{<<"roots">> => Roots}};
                {error, _} = Err -> Err
            end;
        Other ->
            {error, {unsupported_input_request, Other}}
    end.

with_related_task(Params, Meta) when is_map(Params) ->
    Existing = maps:get(<<"_meta">>, Params, #{}),
    Params#{<<"_meta">> => maps:merge(Existing, Meta)};
with_related_task(_Params, Meta) ->
    #{<<"_meta">> => Meta}.

%% Answered, so the handler runs again reporting into the same task.
resume_legacy_task(Owner, TaskId, Responses, HandlerState) ->
    case barrel_mcp_tasks:params(Owner, TaskId) of
        {ok, Params} ->
            Info = #{
                params => Params,
                responses => Responses,
                methods => #{},
                state => HandlerState
            },
            _ = resume_task(Owner, TaskId, Info, legacy_ctx(Owner)),
            ok;
        {error, not_found} ->
            ok
    end.

legacy_ctx(SessionId) ->
    barrel_mcp_ctx:from_request(#{<<"method">> => <<"tools/call">>}, #{
        session_id => SessionId
    }).

%% The params of the call this task was created for, so the handler can
%% be re-invoked once its questions are answered.
task_params(TaskId, Owner) ->
    case barrel_mcp_tasks:params(Owner, TaskId) of
        {ok, Params} -> Params;
        _ -> #{}
    end.

%% A limit reached mid-flight has no request left to answer, so it ends
%% the task with an error object rather than a JSON-RPC reply.
input_error(Reason) ->
    #{
        <<"code">> => ?JSONRPC_INTERNAL_ERROR,
        <<"message">> => iolist_to_binary(io_lib:format("~p", [Reason]))
    }.

%% @doc The result that hands a client a task instead of a value.
%%
%% `pollIntervalMs' is a hint at how often to come back; `ttlMs' is how
%% long the handle stays resolvable.
-spec create_task_result(binary(), map(), barrel_mcp_ctx:ctx()) -> map().
create_task_result(_TaskId, Task, Ctx) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        %% Legacy clients negotiated the core task methods and expect
        %% the handle wrapped, not a polymorphic result type.
        false ->
            #{<<"task">> => Task};
        true ->
            %% `CreateTaskResult = Result & Task': the task's fields are
            %% spread into the result rather than nested, and taskId,
            %% status, createdAt, lastUpdatedAt and ttlMs are all
            %% required. Building a handle by hand left the timestamps
            %% out, so the stored task is the source here.
            Task#{
                <<"resultType">> => <<"task">>,
                <<"pollIntervalMs">> =>
                    application:get_env(barrel_mcp, task_poll_interval_ms, 1000)
            }
    end.

%%====================================================================
%% Multi round-trip requests
%%====================================================================

%% Assemble what a handler needs to resume: the client's responses,
%% which server request each key was answering, and the handler's own
%% state from the previous attempt.
%%
%% A request with no `requestState' is a first attempt. One carrying a
%% state that does not verify is rejected outright: the spec has that
%% state treated as attacker-controlled, so it is never guessed at.
mrtr_context(Method, Params, Ctx) ->
    case barrel_mcp_ctx:request_state(Ctx) of
        undefined ->
            {ok, #{responses => #{}, methods => #{}, state => undefined}};
        Blob ->
            Binding = mrtr_binding(Method, Params, Ctx),
            case barrel_mcp_request_state:unseal(Blob, Binding) of
                {ok, #{user := State, methods := Methods}} ->
                    {ok, #{
                        responses => barrel_mcp_ctx:input_responses(Ctx),
                        methods => Methods,
                        state => State
                    }};
                {ok, _Other} ->
                    {error, unexpected_payload};
                {error, _} = Err ->
                    Err
            end
    end.

%% @doc Run a synchronous handler with a context it can ask for input
%% from.
%%
%% Tools get this through the async plan; prompts and resources run
%% inline, so they get it here. Either way the handler sees the same
%% `mcp_ctx' and `mrtr' keys, and `barrel_mcp:input/2',
%% `request_state/1' and `client_supports/2' read them the same way.
%%
%% A `requestState' that does not verify never reaches the handler.
with_mrtr(Method, Params, Id, Ctx, Fun) ->
    case mrtr_context(Method, Params, Ctx) of
        {error, Reason} ->
            log_bad_request_state(Id, Reason),
            error_response(Id, ?JSONRPC_INVALID_PARAMS, <<"Invalid requestState">>);
        {ok, Mrtr} ->
            Fun(#{mcp_ctx => Ctx, mrtr => Mrtr})
    end.

mrtr_binding(Method, Params, Ctx) ->
    barrel_mcp_request_state:binding(
        barrel_mcp_ctx:principal(Ctx),
        Method,
        Params
    ).

%% @doc Build the result that ends this attempt and tells the client
%% what to gather before retrying.
%%
%% Fails with `-32021' when the handler asks for something the client
%% never declared: the spec forbids sending such a request, and the
%% client needs to know which capability would have been required.
-spec input_required_result(map(), term(), binary(), map(), barrel_mcp_ctx:ctx()) ->
    {ok, map()} | {error, [binary()]}.
input_required_result(Requests, State, Method, Params, Ctx) ->
    case undeclared_capabilities(Requests, Ctx) of
        [] ->
            Sealed = barrel_mcp_request_state:seal(
                #{user => State, methods => request_methods(Requests)},
                mrtr_binding(Method, Params, Ctx)
            ),
            {ok, #{
                <<"resultType">> => <<"input_required">>,
                <<"inputRequests">> => wire_input_requests(Requests),
                <<"requestState">> => Sealed
            }};
        Missing ->
            {error, Missing}
    end.

%% Every legacy revision publishes protocolVersion, capabilities and
%% clientInfo as required; the reference SDK types them with no default.
validate_initialize_params(Params) when is_map(Params) ->
    Required = [
        {<<"protocolVersion">>, fun(V) -> is_binary(V) orelse is_integer(V) end},
        {<<"capabilities">>, fun is_map/1},
        {<<"clientInfo">>, fun is_map/1}
    ],
    Bad = [
        K
     || {K, Ok} <- Required,
        not (maps:is_key(K, Params) andalso Ok(maps:get(K, Params)))
    ],
    case Bad of
        [] -> ok;
        [Key | _] -> {error, Key}
    end;
validate_initialize_params(_Params) ->
    {error, <<"params">>}.

initialize(Params, Id, Ctx) ->
    NegotiatedVersion = negotiate_protocol_version(
        maps:get(<<"protocolVersion">>, Params, undefined)
    ),
    %% Persist client capabilities (notably `sampling') so the server can
    %% later issue server-to-client requests via barrel_mcp_session.
    %% Also persist the negotiated protocol_version on the session.
    _ =
        case barrel_mcp_ctx:session_id(Ctx) of
            SessionId when is_binary(SessionId) ->
                ClientCaps = maps:get(<<"capabilities">>, Params, #{}),
                _ = barrel_mcp_session:set_client_capabilities(SessionId, ClientCaps),
                _ = barrel_mcp_session:set_protocol_version(SessionId, NegotiatedVersion),
                ok;
            undefined ->
                ok
        end,
    success_response(Id, #{
        <<"protocolVersion">> => NegotiatedVersion,
        <<"capabilities">> =>
            maybe_advertise_completions(legacy_capabilities(NegotiatedVersion)),
        <<"serverInfo">> => server_info()
    }).

%% `requiredCapabilities' is a ClientCapabilities object, not a list of
%% names: the reference server builds one at
%% `mcp/server/mcpserver/resolve.py:695'. The dotted names
%% `missing_mode/3' produces nest, so `elicitation.form' is
%% `{"elicitation": {"form": {}}}'.
%% `binary:split/2' stops at the first separator, so a name splits into
%% at most two parts and the clause below cannot fail to match.
capabilities_object(Names) ->
    lists:foldl(
        fun(Name, Acc) ->
            case binary:split(Name, <<".">>) of
                [Capability] ->
                    Acc#{Capability => maps:get(Capability, Acc, #{})};
                [Capability, Mode] ->
                    Inner = maps:get(Capability, Acc, #{}),
                    Acc#{Capability => Inner#{Mode => #{}}}
            end
        end,
        #{},
        Names
    ).

%% An extension is named under `extensions', keyed by its identifier
%% (`mcp/server/mcpserver/server.py:1337').
extension_object(Identifier) ->
    #{<<"extensions">> => #{Identifier => #{}}}.

undeclared_capabilities(Requests, Ctx) ->
    lists:usort(
        lists:append([missing_capabilities(R, Ctx) || R <- maps:values(Requests)])
    ).

missing_capabilities(Request, Ctx) ->
    Method = request_method(Request),
    case capability_for(Method) of
        undefined ->
            [];
        Capability ->
            case barrel_mcp_ctx:supports(Ctx, Capability) of
                false -> [Capability];
                true -> missing_mode(Method, Request, Ctx)
            end
    end.

%% "Servers MUST NOT send elicitation requests with modes that are not
%% supported by the client" (2026-07-28/client/elicitation.mdx:77).
missing_mode(<<"elicitation/create">>, Request, Ctx) ->
    Mode = elicitation_mode(Request),
    Declared = lists:member(Mode, barrel_mcp_ctx:elicitation_modes(Ctx)),
    case Declared andalso mode_in_revision(Mode, Ctx) of
        true -> [];
        false -> [<<"elicitation.", Mode/binary>>]
    end;
missing_mode(_Method, _Request, _Ctx) ->
    [].

%% A client can only have declared a mode its revision defines, so a
%% declaration that disagrees with the revision loses.
mode_in_revision(<<"url">>, Ctx) ->
    barrel_mcp_version:has(elicitation_url, barrel_mcp_ctx:protocol_version(Ctx));
mode_in_revision(_Mode, Ctx) ->
    barrel_mcp_version:has(elicitation, barrel_mcp_ctx:protocol_version(Ctx)).

%% Absent `mode' is form mode (elicitation.mdx:97).
elicitation_mode(Request) when is_map(Request) ->
    Params =
        case request_params(Request) of
            P when is_map(P) -> P;
            _ -> #{}
        end,
    case maps:get(<<"mode">>, Params, maps:get(mode, Params, undefined)) of
        M when is_binary(M) -> M;
        _ -> <<"form">>
    end;
elicitation_mode(_Request) ->
    <<"form">>.

%% Which client capability each server-to-client request needs.
capability_for(<<"elicitation/create">>) -> <<"elicitation">>;
capability_for(<<"sampling/createMessage">>) -> <<"sampling">>;
capability_for(<<"roots/list">>) -> <<"roots">>;
capability_for(_) -> undefined.

request_methods(Requests) ->
    maps:map(fun(_Key, Request) -> request_method(Request) end, Requests).

request_method(Request) when is_map(Request) ->
    case maps:get(method, Request, undefined) of
        undefined -> maps:get(<<"method">>, Request, undefined);
        Method -> Method
    end;
request_method(_Request) ->
    undefined.

%% Handlers may use atom or binary keys; the wire wants binaries.
wire_input_requests(Requests) ->
    maps:map(fun(_Key, Request) -> wire_input_request(Request) end, Requests).

wire_input_request(Request) ->
    #{
        <<"method">> => request_method(Request),
        <<"params">> => request_params(Request)
    }.

request_params(Request) when is_map(Request) ->
    case maps:get(params, Request, undefined) of
        undefined -> maps:get(<<"params">>, Request, #{});
        Params -> Params
    end.

log_bad_request_state(Id, Reason) ->
    logger:warning(
        "Rejected MRTR requestState: ~p (request_id=~p)",
        [Reason, Id]
    ).

%%====================================================================
%% Request Handlers
%%====================================================================

handle_request(<<"initialize">>, Params, Id, Ctx) ->
    case validate_initialize_params(Params) of
        {error, Key} ->
            error_response(
                Id,
                ?JSONRPC_INVALID_PARAMS,
                <<"Invalid initialize params: ", Key/binary>>
            );
        ok ->
            initialize(Params, Id, Ctx)
    end;
%% Open a long-lived notification stream. The transport owns the

%% Open a long-lived notification stream. The transport owns the
%% stream, so this only settles what the client asked for; nothing is
%% sent from here.
%%
%% A transport that cannot hold a response open has no way to serve
%% this, so it does not exist there. Answering method-not-found is what
%% the client can act on; handing back a stream nobody can write would
%% only fail later and further away.
handle_request(<<"subscriptions/listen">>, Params, Id, Ctx) ->
    Filter = barrel_mcp_subscriptions:normalize_filter(Params),
    case barrel_mcp_ctx:streaming(Ctx) of
        true when map_get(task_ids, Filter) =/= [] ->
            %% Task notifications are part of the extension, so a client
            %% that did not declare it may not ask for them.
            case tasks_enabled(Ctx) of
                false ->
                    error_with_data(
                        Id,
                        ?MCP_MISSING_CLIENT_CAPABILITY,
                        <<"Client did not declare a required capability">>,
                        #{<<"requiredCapabilities">> => extension_object(?MCP_EXT_TASKS)}
                    );
                true ->
                    %% Bound to the principal, and narrowed to the ids
                    %% it actually holds. An id owned by someone else
                    %% and an id naming nothing are both dropped, so the
                    %% acknowledgement cannot be read as an existence
                    %% check.
                    Owner = task_owner(Ctx),
                    Allowed = barrel_mcp_tasks:owned(Owner, map_get(task_ids, Filter)),
                    {subscribe, #{
                        id => Id,
                        filter => Filter#{task_ids => Allowed, principal => Owner}
                    }}
            end;
        true ->
            {subscribe, #{id => Id, filter => Filter}};
        false ->
            error_response(
                Id,
                ?JSONRPC_METHOD_NOT_FOUND,
                <<"Method not found: subscriptions/listen">>
            )
    end;
%% Discovery. Servers MUST implement this, and it is answered in both
%% eras: on stdio it doubles as the probe a dual-era client uses to
%% decide whether to fall back to the `initialize' handshake.
handle_request(<<"server/discover">>, _Params, Id, _Ctx) ->
    Base = #{
        <<"supportedVersions">> => advertised_versions(),
        <<"capabilities">> => maybe_advertise_completions(modern_capabilities()),
        <<"ttlMs">> => max(0, application:get_env(barrel_mcp, discover_ttl_ms, 60000)),
        <<"cacheScope">> =>
            application:get_env(barrel_mcp, discover_cache_scope, <<"public">>)
    },
    Result =
        case application:get_env(barrel_mcp, instructions, undefined) of
            Text when is_binary(Text) -> Base#{<<"instructions">> => Text};
            _ -> Base
        end,
    %% `serverInfo' belongs in `_meta'. A modern request gets it from
    %% `finalize/2'; a legacy probe would not, so put it there either
    %% way and let the merge in `decorate_result/1' be idempotent.
    success_response(Id, Result, #{?MCP_META_SERVER_INFO => server_info()});
handle_request(<<"ping">>, _Params, Id, _State) ->
    success_response(Id, #{});
%% Tools
handle_request(<<"tools/list">>, Params, Id, Ctx) ->
    registry_page(tool, <<"tools">>, Params, Id, fun({Name, Handler}) ->
        Base = #{
            <<"name">> => Name,
            <<"description">> => maps:get(description, Handler, <<>>),
            <<"inputSchema">> => maps:get(input_schema, Handler, #{<<"type">> => <<"object">>})
        },
        Listed = with_optional_fields(Base, Handler, Ctx, [
            {<<"outputSchema">>, output_schema, output_schema},
            {<<"title">>, title, title},
            {<<"icons">>, icons, icons},
            {<<"annotations">>, annotations, always}
        ]),
        with_execution(Listed, Handler, Ctx)
    end);
handle_request(<<"tools/call">>, Params, Id, Ctx) ->
    case mrtr_context(<<"tools/call">>, Params, Ctx) of
        {error, Reason} ->
            log_bad_request_state(Id, Reason),
            error_response(
                Id,
                ?JSONRPC_INVALID_PARAMS,
                <<"Invalid requestState">>
            );
        {ok, Mrtr} ->
            tool_call_plan(Params, Id, Ctx, Mrtr)
    end;
%% Resources
handle_request(<<"resources/list">>, Params, Id, _State) ->
    registry_page(resource, <<"resources">>, Params, Id, fun({_Name, Handler}) ->
        Base = #{
            <<"uri">> => maps:get(uri, Handler, <<>>),
            <<"name">> => maps:get(name, Handler, <<>>),
            <<"description">> => maps:get(description, Handler, <<>>),
            <<"mimeType">> => maps:get(mime_type, Handler, <<"text/plain">>)
        },
        with_optional_fields(Base, Handler, [
            {<<"title">>, title},
            {<<"icons">>, icons},
            {<<"annotations">>, annotations}
        ])
    end);
handle_request(<<"resources/read">>, Params, Id, Ctx) ->
    Uri = maps:get(<<"uri">>, Params, <<>>),
    %% Exact-URI lookup first.
    Resources = barrel_mcp_registry:all(resource),
    with_mrtr(<<"resources/read">>, Params, Id, Ctx, fun(HandlerCtx) ->
        %% The template path merges URI variables into the handler's
        %% arguments, but the state is sealed against the request's own
        %% params: those are what the retry carries back.
        Bind = #{ctx => Ctx, params => Params, handler_ctx => HandlerCtx},
        case lists:keyfind(Uri, 1, [{maps:get(uri, H, <<>>), N, H} || {N, H} <- Resources]) of
            {Uri, Name, _Handler} ->
                run_resource_read(resource, Name, Params, Uri, Id, Bind);
            false ->
                %% Fall back to RFC 6570 template matching against
                %% registered `resource_template' entries.
                case match_resource_template(Uri) of
                    {ok, TplName, Vars} ->
                        Args = maps:merge(Params, Vars),
                        run_resource_read(
                            resource_template, TplName, Args, Uri, Id, Bind
                        );
                    nomatch ->
                        error_response(
                            Id,
                            resource_not_found_code(Ctx),
                            <<"Resource not found">>
                        )
                end
        end
    end);
handle_request(<<"resources/templates/list">>, Params, Id, _State) ->
    registry_page(resource_template, <<"resourceTemplates">>, Params, Id, fun({_Name, Handler}) ->
        Base = #{
            <<"uriTemplate">> => maps:get(uri_template, Handler, <<>>),
            <<"name">> => maps:get(name, Handler, <<>>),
            <<"description">> => maps:get(description, Handler, <<>>),
            <<"mimeType">> => maps:get(mime_type, Handler, <<"text/plain">>)
        },
        Compact = maps:filter(fun(_K, V) -> V =/= <<>> end, Base),
        with_optional_fields(Compact, Handler, [
            {<<"title">>, title},
            {<<"icons">>, icons},
            {<<"annotations">>, annotations}
        ])
    end);
handle_request(<<"resources/subscribe">>, Params, Id, Ctx) ->
    Uri = maps:get(<<"uri">>, Params, <<>>),
    case barrel_mcp_ctx:session_id(Ctx) of
        SessionId when is_binary(SessionId), Uri =/= <<>> ->
            barrel_mcp_session:subscribe_resource(SessionId, Uri),
            success_response(Id, #{});
        _ ->
            error_response(
                Id,
                ?JSONRPC_INVALID_PARAMS,
                <<"Subscribe requires a session and a uri">>
            )
    end;
handle_request(<<"resources/unsubscribe">>, Params, Id, Ctx) ->
    Uri = maps:get(<<"uri">>, Params, <<>>),
    case barrel_mcp_ctx:session_id(Ctx) of
        SessionId when is_binary(SessionId), Uri =/= <<>> ->
            barrel_mcp_session:unsubscribe_resource(SessionId, Uri),
            success_response(Id, #{});
        _ ->
            error_response(
                Id,
                ?JSONRPC_INVALID_PARAMS,
                <<"Unsubscribe requires a session and a uri">>
            )
    end;
%% Prompts
handle_request(<<"prompts/list">>, Params, Id, _State) ->
    registry_page(prompt, <<"prompts">>, Params, Id, fun({Name, Handler}) ->
        Base = #{
            <<"name">> => Name,
            <<"description">> => maps:get(description, Handler, <<>>),
            <<"arguments">> => lists:map(
                fun(Arg) ->
                    #{
                        <<"name">> => maps:get(name, Arg, <<>>),
                        <<"description">> => maps:get(description, Arg, <<>>),
                        <<"required">> => maps:get(required, Arg, false)
                    }
                end,
                maps:get(arguments, Handler, [])
            )
        },
        with_optional_fields(Base, Handler, [
            {<<"title">>, title},
            {<<"icons">>, icons},
            {<<"annotations">>, annotations}
        ])
    end);
handle_request(<<"prompts/get">>, Params, Id, Ctx) ->
    Name = maps:get(<<"name">>, Params, <<>>),
    Args = maps:get(<<"arguments">>, Params, #{}),
    with_mrtr(<<"prompts/get">>, Params, Id, Ctx, fun(HandlerCtx) ->
        case barrel_mcp_registry:run(prompt, Name, Args, HandlerCtx) of
            {ok, {input_required, Requests, State}} ->
                seal_input_required(
                    Requests, State, <<"prompts/get">>, Params, Ctx, Id
                );
            {ok, Result} ->
                success_response(Id, #{
                    <<"description">> => maps:get(description, Result, <<>>),
                    <<"messages">> => maps:get(messages, Result, [])
                });
            {error, {not_found, _, _}} ->
                error_response(Id, ?JSONRPC_INVALID_PARAMS, <<"Prompt not found">>);
            {error, Crash} ->
                log_handler_crash(prompt, Name, Id, Crash),
                error_response(Id, ?JSONRPC_INTERNAL_ERROR, <<"Internal prompt error">>)
        end
    end);
%% Tasks
handle_request(<<"tasks/list">>, Params, Id, Ctx) ->
    SessionId = barrel_mcp_ctx:session_id(Ctx),
    Cursor = maps:get(<<"cursor">>, Params, undefined),
    {ok, AllTasks} = barrel_mcp_tasks:list(SessionId, #{}),
    {Page, Next} = paginate(
        AllTasks,
        Cursor,
        fun(T) -> maps:get(<<"taskId">>, T) end
    ),
    success_response(Id, with_next_cursor(#{<<"tasks">> => Page}, Next));
handle_request(<<"tasks/get">>, Params, Id, Ctx) ->
    with_tasks_extension(Id, Ctx, fun() ->
        TaskId = maps:get(<<"taskId">>, Params, <<>>),
        case barrel_mcp_tasks:get(task_owner(Ctx), TaskId, barrel_mcp_ctx:era(Ctx)) of
            {ok, Task} ->
                success_response(Id, Task);
            {error, not_found} ->
                error_response(Id, ?JSONRPC_INVALID_PARAMS, <<"Task not found">>)
        end
    end);
%% Supply answers the task was waiting on. The extension has the server
%% ignore anything it does not need rather than reject it, so this only
%% fails when the task itself is unknown.
handle_request(<<"tasks/update">>, Params, Id, Ctx) ->
    TaskId = maps:get(<<"taskId">>, Params, <<>>),
    with_tasks_extension(Id, Ctx, fun() ->
        Responses =
            case maps:get(<<"inputResponses">>, Params, #{}) of
                R when is_map(R) -> R;
                _ -> #{}
            end,
        Owner = task_owner(Ctx),
        case barrel_mcp_tasks:update(Owner, TaskId, Responses) of
            ok ->
                success_response(Id, #{<<"resultType">> => <<"complete">>});
            {resume, Info} ->
                %% Every question is answered, so the handler runs again
                %% from the top with the answers in its context. The
                %% worker that asked has long since exited.
                _ = resume_task(Owner, TaskId, Info, Ctx),
                success_response(Id, #{<<"resultType">> => <<"complete">>});
            {error, not_found} ->
                error_response(Id, ?JSONRPC_INVALID_PARAMS, <<"Task not found">>)
        end
    end);
handle_request(<<"tasks/cancel">>, Params, Id, Ctx) ->
    with_tasks_extension(Id, Ctx, fun() ->
        Owner = task_owner(Ctx),
        TaskId = maps:get(<<"taskId">>, Params, <<>>),
        case barrel_mcp_tasks:cancel(Owner, TaskId) of
            ok ->
                cancel_task_response(Owner, TaskId, Id, Ctx);
            {error, not_found} ->
                error_response(Id, ?JSONRPC_INVALID_PARAMS, <<"Task not found">>)
        end
    end);
handle_request(<<"tasks/result">>, Params, Id, Ctx) ->
    SessionId = barrel_mcp_ctx:session_id(Ctx),
    TaskId = maps:get(<<"taskId">>, Params, <<>>),
    %% Blocks until the task is terminal, which is what the requestor
    %% asked for by calling this rather than polling tasks/get. The wait
    %% is in this process, not the tasks server: that server has to
    %% accept the very transition that ends the wait.
    case barrel_mcp_tasks:await_result(SessionId, TaskId, ?TASK_RESULT_TIMEOUT) of
        {ok, Task} -> task_result_response(Task, Id);
        {error, timeout} -> error_response(Id, ?JSONRPC_INTERNAL_ERROR, <<"Task timed out">>);
        {error, not_found} -> error_response(Id, ?JSONRPC_INVALID_PARAMS, <<"Task not found">>)
    end;
%% Completions
handle_request(<<"completion/complete">>, Params, Id, _State) ->
    Ref = maps:get(<<"ref">>, Params, #{}),
    Argument = maps:get(<<"argument">>, Params, #{}),
    ArgName = maps:get(<<"name">>, Argument, <<>>),
    Value = maps:get(<<"value">>, Argument, <<>>),
    case completion_lookup_key(Ref, ArgName) of
        undefined ->
            success_response(Id, #{<<"completion">> => empty_completion()});
        Key ->
            case barrel_mcp_registry:run_completion(Key, Value, #{}) of
                {ok, {ok, Values}} ->
                    success_response(Id, #{
                        <<"completion">> =>
                            completion_payload(Values, false)
                    });
                {ok, {ok, Values, #{has_more := HasMore}}} ->
                    success_response(Id, #{
                        <<"completion">> =>
                            completion_payload(Values, HasMore)
                    });
                {error, {not_found, _, _}} ->
                    success_response(Id, #{<<"completion">> => empty_completion()});
                {error, Crash} ->
                    log_handler_crash(completion, Key, Id, Crash),
                    error_response(
                        Id,
                        ?JSONRPC_INTERNAL_ERROR,
                        <<"Internal completion error">>
                    )
            end
    end;
%% Logging
handle_request(<<"logging/setLevel">>, Params, Id, Ctx) ->
    Level = maps:get(<<"level">>, Params, undefined),
    case {Level, barrel_mcp_ctx:session_id(Ctx)} of
        {undefined, _} ->
            error_response(
                Id,
                ?JSONRPC_INVALID_PARAMS,
                <<"Missing required parameter: level">>
            );
        {_, undefined} ->
            %% Stdio / no session, accept but no per-session storage.
            case barrel_mcp_session:log_level_priority(Level) of
                error ->
                    error_response(
                        Id,
                        ?JSONRPC_INVALID_PARAMS,
                        <<"Invalid log level">>
                    );
                _ ->
                    success_response(Id, #{})
            end;
        {_, SessionId} ->
            case barrel_mcp_session:set_log_level(SessionId, Level) of
                ok ->
                    success_response(Id, #{});
                {error, invalid_level} ->
                    error_response(
                        Id,
                        ?JSONRPC_INVALID_PARAMS,
                        <<"Invalid log level">>
                    );
                {error, not_found} ->
                    success_response(Id, #{})
            end
    end;
%% Unknown method
handle_request(Method, _Params, Id, _State) ->
    error_response(
        Id,
        ?JSONRPC_METHOD_NOT_FOUND,
        <<"Method not found: ", Method/binary>>
    ).

%% 2025-11-25 returns the cancelled task; the extension returns an
%% acknowledgement.
cancel_task_response(Owner, TaskId, Id, Ctx) ->
    case barrel_mcp_ctx:is_modern(Ctx) of
        true ->
            success_response(Id, #{<<"resultType">> => <<"complete">>});
        false ->
            case barrel_mcp_tasks:get(Owner, TaskId) of
                {ok, Task} -> success_response(Id, Task);
                {error, not_found} -> success_response(Id, #{})
            end
    end.

%%====================================================================
%% Notification Handlers
%%====================================================================

%% Spec name (2025-03-26+).
handle_notification(<<"notifications/initialized">>, _Params, _State) ->
    ok;
%% Legacy bare name kept for one release; older clients still send this.
handle_notification(<<"initialized">>, _Params, _State) ->
    ok;
handle_notification(<<"notifications/cancelled">>, Params, Ctx) ->
    case barrel_mcp_ctx:session_id(Ctx) of
        SessionId when is_binary(SessionId) ->
            case maps:find(<<"requestId">>, Params) of
                {ok, RequestId} ->
                    barrel_mcp_session:cancel_in_flight(SessionId, RequestId);
                error ->
                    ok
            end;
        _ ->
            ok
    end;
handle_notification(<<"notifications/progress">>, _Params, _State) ->
    %% The server doesn't currently emit anything special on inbound
    %% client-side progress notifications (used for client→server
    %% requests, which we don't have). Acknowledge silently.
    ok;
handle_notification(<<"notifications/roots/list_changed">>, Params, State) ->
    case application:get_env(barrel_mcp, roots_changed_handler) of
        {ok, {Mod, Fun}} ->
            try
                Mod:Fun(Params, State)
            catch
                _:_ -> ok
            end;
        _ ->
            ok
    end;
handle_notification(_, _Params, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

success_response(Id, Result) ->
    success_response(Id, Result, #{}).

success_response(Id, Result, Meta) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => with_meta(Result, Meta)
    }.

%% Attach `_meta' to a result or error object, only when the supplied
%% map is non-empty (keeps wire payloads compact).
%%
%% `_meta' goes *inside* the object: the MCP schema declares it as a
%% field of `Result', so an envelope-level `_meta' sitting beside
%% `result' is invisible to a conforming client.
with_meta(Object, Meta) when is_map(Object), is_map(Meta), map_size(Meta) > 0 ->
    Object#{<<"_meta">> => Meta};
with_meta(Object, _) ->
    Object.

%% @doc Format a tool handler's plain return value into the MCP
%% content-block list shape. Public so transports driving async
%% tool calls (HTTP / stdio) can produce identical envelopes.
-spec format_tool_result_external(term()) -> [map()].
format_tool_result_external(Result) ->
    format_tool_result(Result).

%% @doc Drive an `{async, AsyncPlan}' from `handle/2' to completion
%% on the calling process and return a JSON-RPC response map.
%%
%% Used by transports that don't have their own request/wait
%% machinery (stdio, legacy HTTP). The Streamable HTTP transport
%% drives async plans itself because it needs to record per-session
%% in-flight entries for cancellation routing.
-spec drive_async_plan(map(), timeout()) -> map().
drive_async_plan(Plan, Timeout) ->
    drive_async_plan(Plan, Timeout, undefined).

%% @doc As {@link drive_async_plan/2}, but threads the authenticated
%% principal (`AuthInfo', the auth provider's `authenticate/2' map) into
%% the tool `Ctx' under `auth_info'. Transports that authenticate before
%% driving the plan (the simple HTTP transport) pass it here; callers
%% with no auth provider use the `/2' form and `auth_info' is `undefined'.
-spec drive_async_plan(map(), timeout(), term()) -> map().
drive_async_plan(Plan, Timeout, AuthInfo) ->
    drive_async_plan(Plan, Timeout, AuthInfo, fun(_Worker) -> ok end).

%% `ToolExecution.taskSupport' is the extension's field, listed only in
%% the era that has the extension and only for tools that take part.
with_execution(Listed, Handler, Ctx) ->
    Support = maps:get(task_support, Handler, forbidden),
    case barrel_mcp_ctx:is_modern(Ctx) andalso Support =/= forbidden of
        true -> Listed#{<<"execution">> => #{<<"taskSupport">> => atom_to_binary(Support, utf8)}};
        false -> Listed
    end.

%% @doc As {@link drive_async_plan/3}, telling `OnSpawn' the worker pid
%% before waiting on it. A caller that must reap the worker if its own
%% peer goes away has no other way to learn the pid: the wait is
%% blocking and the spawn happens inside it.
-spec drive_async_plan(map(), timeout(), term(), fun((pid() | undefined) -> term())) -> map().
drive_async_plan(Plan, Timeout, AuthInfo, OnSpawn) ->
    Ctx = maps:get(ctx, Plan, undefined),
    RequestId = maps:get(request_id, Plan),
    case task_plan(Plan, Ctx) of
        {required, _ToolName} ->
            finalize(missing_tasks_capability(RequestId), Ctx);
        {task, ToolName} ->
            case barrel_mcp_ctx:is_modern(Ctx) of
                true ->
                    finalize(drive_inline_then_task(Plan, ToolName, Ctx, AuthInfo, OnSpawn), Ctx);
                false ->
                    finalize(drive_as_task(Plan, ToolName, Ctx, AuthInfo), Ctx)
            end;
        inline ->
            finalize(run_async_plan(Plan, Timeout, AuthInfo, OnSpawn), Ctx)
    end.

%% What a call becomes: `inline' for a tool without task support, or
%% one the client cannot poll and does not require a task for; `{task,
%% Name}' when it can; `{required, Name}' when the tool insists and the
%% client did not declare the extension. Without a request context (a
%% hand-built plan) there is nothing to decide from.
task_plan(_Plan, undefined) ->
    inline;
task_plan(Plan, Ctx) ->
    case maps:get(tool_name, Plan, undefined) of
        undefined ->
            inline;
        Name ->
            case {task_support(Name), tasks_enabled(Ctx)} of
                {forbidden, _} -> inline;
                {optional, false} -> inline;
                {required, false} -> {required, Name};
                {_, true} -> {task, Name}
            end
    end.

%% tasks.md "Task Creation": a task-supporting tool may still answer
%% synchronously when it can, and an MRTR round before the work starts
%% is synchronous too; see {@link barrel_mcp_task_relay}.
drive_inline_then_task(Plan, ToolName, Ctx, AuthInfo, OnSpawn) ->
    RequestId = maps:get(request_id, Plan),
    Spawn = maps:get(spawn, Plan),
    Relay = barrel_mcp_task_relay:start(),
    ToolCtx = #{
        request_id => RequestId,
        session_id => session_of(Ctx),
        progress_token => undefined,
        meta => maps:get(meta, Plan, #{}),
        emit_progress => fun(_, _, _) -> ok end,
        emit_log => fun(_, _, _) -> ok end,
        reply_to => Relay,
        auth_info => AuthInfo
    },
    Worker = Spawn(ToolCtx),
    barrel_mcp_task_relay:worker(Relay, Worker),
    _ = OnSpawn(Worker),
    case await_plan_outcome(Plan, RequestId, barrel_mcp_task_relay:inline_ms()) of
        timeout ->
            ok = barrel_mcp_task_relay:hold(Relay),
            %% Anything that arrived between the timeout and the hold
            %% is ahead of us in the mailbox: answer it synchronously.
            case await_plan_outcome(Plan, RequestId, 0) of
                timeout ->
                    unlink(Relay),
                    {_Method, Params} = maps:get(mrtr_binding, Plan, {<<>>, #{}}),
                    case
                        barrel_mcp_task_relay:escalate(
                            Relay, Worker, task_owner(Ctx), ToolName, Params, #{
                                request_id => RequestId, mcp_ctx => Ctx
                            }
                        )
                    of
                        {ok, Result} ->
                            success_response(RequestId, Result);
                        {error, too_many_tasks} ->
                            error_response(
                                RequestId, ?JSONRPC_INTERNAL_ERROR, <<"Too many concurrent tasks">>
                            )
                    end;
                Response ->
                    barrel_mcp_task_relay:stop(Relay),
                    Response
            end;
        Response ->
            barrel_mcp_task_relay:stop(Relay),
            Response
    end.

%% @doc The `-32021' a client without the tasks extension gets from a
%% tool that requires one (tasks.md "Capability Negotiation").
-spec missing_tasks_capability(term()) -> map().
missing_tasks_capability(Id) ->
    error_with_data(
        Id,
        ?MCP_MISSING_CLIENT_CAPABILITY,
        <<"Client did not declare a required capability">>,
        #{<<"requiredCapabilities">> => extension_object(?MCP_EXT_TASKS)}
    ).

%% Hand back the task id straight away and let the worker report into
%% the task. The caller is not waiting on it.
drive_as_task(Plan, ToolName, Ctx, AuthInfo) ->
    RequestId = maps:get(request_id, Plan),
    {_Method, Params} = maps:get(mrtr_binding, Plan, {<<>>, #{}}),
    case barrel_mcp_tasks:create(task_owner(Ctx), ToolName, #{params => Params}) of
        {error, too_many_tasks} ->
            %% Refused at admission, so there is still a request to
            %% answer. Running the tool anyway would produce a result
            %% with nowhere to put it.
            error_response(
                RequestId,
                ?JSONRPC_INTERNAL_ERROR,
                <<"Too many concurrent tasks">>
            );
        {ok, TaskId} ->
            drive_as_task(Plan, ToolName, Ctx, AuthInfo, TaskId)
    end.

drive_as_task(Plan, _ToolName, Ctx, AuthInfo, TaskId) ->
    RequestId = maps:get(request_id, Plan),
    Spawn = maps:get(spawn, Plan),
    Owner = task_owner(Ctx),
    {_Collector, Worker} = spawn_task_collector(Owner, TaskId, fun(Collector) ->
        Spawn(#{
            request_id => RequestId,
            session_id => barrel_mcp_ctx:session_id(Ctx),
            progress_token => undefined,
            meta => maps:get(meta, Plan, #{}),
            emit_progress => fun(_, _, _) -> ok end,
            emit_log => fun(_, _, _) -> ok end,
            reply_to => Collector,
            auth_info => AuthInfo
        })
    end),
    _ =
        case is_pid(Worker) of
            true ->
                barrel_mcp_tasks:set_worker(
                    Owner,
                    TaskId,
                    #{worker => Worker, request_id => RequestId}
                );
            false ->
                ok
        end,
    Task = read_task_for(Owner, TaskId, Ctx),
    success_response(RequestId, create_task_result(TaskId, Task, Ctx)).

session_of(undefined) -> undefined;
session_of(Ctx) -> barrel_mcp_ctx:session_id(Ctx).

run_async_plan(Plan, Timeout, AuthInfo, OnSpawn) ->
    Self = self(),
    PlanCtx = maps:get(ctx, Plan, undefined),
    RequestId = maps:get(request_id, Plan),
    Spawn = maps:get(spawn, Plan),
    Meta = maps:get(meta, Plan, #{}),
    Ctx = #{
        request_id => RequestId,
        %% stdio has a session even though it answers inline, and a tool
        %% needs it to reach the client at all.
        session_id => session_of(PlanCtx),
        progress_token => undefined,
        meta => Meta,
        emit_progress => fun(_, _, _) -> ok end,
        emit_log => fun(_, _, _) -> ok end,
        reply_to => Self,
        auth_info => AuthInfo
    },
    _ = OnSpawn(Spawn(Ctx)),
    case await_plan_outcome(Plan, RequestId, Timeout) of
        timeout -> error_response(RequestId, internal_error_code(PlanCtx), <<"Tool timed out">>);
        Response -> Response
    end.

%% One outcome message for `RequestId', turned into its response, or
%% `timeout'.
await_plan_outcome(Plan, RequestId, Timeout) ->
    receive
        {tool_result, RequestId, Result} ->
            success_response(
                RequestId,
                #{<<"content">> => format_tool_result_external(Result)}
            );
        {tool_result_meta, RequestId, Result, RespMeta} ->
            success_response(
                RequestId,
                #{<<"content">> => format_tool_result_external(Result)},
                RespMeta
            );
        {tool_structured, RequestId, Data, Content} ->
            success_response(
                RequestId,
                #{
                    <<"content">> => Content,
                    <<"structuredContent">> => Data
                }
            );
        {tool_structured_meta, RequestId, Data, Content, RespMeta} ->
            success_response(
                RequestId,
                #{
                    <<"content">> => Content,
                    <<"structuredContent">> => Data
                },
                RespMeta
            );
        {tool_input_required, RequestId, Requests, State} ->
            input_required_envelope(Plan, Requests, State, RequestId);
        {tool_error, RequestId, Content} ->
            success_response(
                RequestId,
                #{
                    <<"content">> => format_tool_result(Content),
                    <<"isError">> => true
                }
            );
        {tool_error_meta, RequestId, Content, RespMeta} ->
            success_response(
                RequestId,
                #{
                    <<"content">> => format_tool_result(Content),
                    <<"isError">> => true
                },
                RespMeta
            );
        {tool_validation_failed, RequestId, Errors} ->
            Msg = iolist_to_binary(
                io_lib:format(
                    "Invalid tool input: ~p", [Errors]
                )
            ),
            success_response(
                RequestId,
                #{
                    <<"content">> =>
                        [#{<<"type">> => <<"text">>, <<"text">> => Msg}],
                    <<"isError">> => true
                }
            );
        {tool_failed, RequestId, Reason} ->
            %% Built here, not by a handler, so finalize never sees it:
            %% stamp resultType and serverInfo the way every result gets.
            success_response(RequestId, decorate_result(tool_failure_result(Reason)))
    after Timeout ->
        timeout
    end.

format_tool_result(Result) when is_binary(Result) ->
    [#{<<"type">> => <<"text">>, <<"text">> => Result}];
format_tool_result(Result) when is_map(Result) ->
    case maps:get(<<"type">>, Result, undefined) of
        undefined ->
            [#{<<"type">> => <<"text">>, <<"text">> => iolist_to_binary(json:encode(Result))}];
        _ ->
            [Result]
    end;
format_tool_result(Result) when is_list(Result) ->
    Result;
format_tool_result(Result) ->
    [#{<<"type">> => <<"text">>, <<"text">> => io_lib:format("~p", [Result])}].

%% Run a resource handler (exact match or template) and shape
%% the response.
run_resource_read(Type, Name, Args, Uri, Id, Bind) ->
    #{ctx := Ctx, params := Params, handler_ctx := HandlerCtx} = Bind,
    case barrel_mcp_registry:run(Type, Name, Args, HandlerCtx) of
        {ok, {input_required, Requests, State}} ->
            seal_input_required(
                Requests, State, <<"resources/read">>, Params, Ctx, Id
            );
        {ok, Result} ->
            Content = format_resource_result(Uri, Result),
            success_response(
                Id,
                resource_freshness(Type, Name, #{<<"contents">> => Content})
            );
        {error, Crash} ->
            log_handler_crash(resource, Name, Id, Crash),
            error_response(Id, resource_error_code(Ctx), <<"Internal resource error">>)
    end.

%% A resource registered with its own `cache_ttl_ms' overrides the
%% server-wide default: how long a body stays fresh is a property of
%% the resource, not of the deployment.
resource_freshness(Type, Name, Result) ->
    case barrel_mcp_registry:find(Type, Name) of
        {ok, Handler} ->
            case maps:get(cache_ttl_ms, Handler, undefined) of
                Ttl when is_integer(Ttl) -> Result#{<<"ttlMs">> => max(0, Ttl)};
                _ -> Result
            end;
        error ->
            Result
    end.

%% Walk the registered resource_template entries and return the
%% first whose `uri_template' matches `Uri'.
match_resource_template(Uri) ->
    Templates = barrel_mcp_registry:all(resource_template),
    do_match_template(Uri, Templates).

do_match_template(_Uri, []) ->
    nomatch;
do_match_template(Uri, [{Name, Handler} | Rest]) ->
    Tpl = maps:get(uri_template, Handler, <<>>),
    case Tpl of
        <<>> ->
            do_match_template(Uri, Rest);
        _ ->
            case barrel_mcp_uri_template:match(Uri, Tpl) of
                {ok, Vars} -> {ok, Name, Vars};
                nomatch -> do_match_template(Uri, Rest)
            end
    end.

format_resource_result(Uri, Result) when is_list(Result) ->
    [add_resource_uri(Uri, B) || B <- Result];
format_resource_result(Uri, Result) when is_binary(Result) ->
    [#{<<"uri">> => Uri, <<"text">> => Result}];
format_resource_result(Uri, #{text := Text} = M) ->
    Block = #{<<"uri">> => Uri, <<"text">> => Text},
    [decorate_block(Block, M)];
format_resource_result(Uri, #{blob := Blob, mimeType := MimeType} = M) ->
    Block = #{
        <<"uri">> => Uri,
        <<"blob">> => base64:encode(Blob),
        <<"mimeType">> => MimeType
    },
    [decorate_block(Block, M)];
format_resource_result(Uri, Result) when is_map(Result) ->
    [#{<<"uri">> => Uri, <<"text">> => iolist_to_binary(json:encode(Result))}];
format_resource_result(Uri, Result) ->
    [#{<<"uri">> => Uri, <<"text">> => io_lib:format("~p", [Result])}].

%% Pass `annotations' / `mimeType' through onto an already-built block.
decorate_block(Block, M) ->
    Block1 =
        case maps:find(mimeType, M) of
            {ok, Mime} -> Block#{<<"mimeType">> => Mime};
            error -> Block
        end,
    case maps:find(annotations, M) of
        {ok, Ann} -> Block1#{<<"annotations">> => Ann};
        error -> Block1
    end.

%% Inject `uri' into a pre-built content block (binary-keyed map).
add_resource_uri(Uri, Block) when is_map(Block) ->
    case maps:is_key(<<"uri">>, Block) of
        true -> Block;
        false -> Block#{<<"uri">> => Uri}
    end.

%% Log a crashed resource/prompt/completion handler server-side and
%% never surface the exception term to the client: a caught `Reason'
%% can carry internal paths, argument values or secret-bearing terms.
%% The wire layer returns a generic message; operators cross-reference
%% via the request id. Mirrors the tool path in barrel_mcp_registry.
log_handler_crash(Kind, Name, Id, Crash) ->
    logger:error(
        "~p handler crashed: ~p (request_id=~p, name=~p)",
        [Kind, Crash, Id, Name]
    ).

maybe_advertise_completions(Caps) ->
    case barrel_mcp_registry:all(completion) of
        [] -> Caps;
        _ -> Caps#{<<"completions">> => #{}}
    end.

completion_lookup_key(
    #{<<"type">> := <<"ref/prompt">>, <<"name">> := Name},
    ArgName
) when is_binary(Name) ->
    <<"prompt:", Name/binary, ":", ArgName/binary>>;
completion_lookup_key(
    #{<<"type">> := <<"ref/resource">>, <<"uri">> := Uri},
    ArgName
) when is_binary(Uri) ->
    <<"resource_template:", Uri/binary, ":", ArgName/binary>>;
completion_lookup_key(_, _) ->
    undefined.

empty_completion() ->
    #{<<"values">> => [], <<"hasMore">> => false}.

completion_payload(Values, HasMore) when is_list(Values) ->
    #{
        <<"values">> => Values,
        <<"hasMore">> => HasMore =:= true,
        <<"total">> => length(Values)
    }.

%% Add optional fields from a Handler map to a wire envelope. Each
%% pair `{WireKey, HandlerKey}' becomes `WireKey => Value' in the
%% envelope only when the value is present and not the empty
%% binary; this keeps wire payloads compact and back-compat.
with_optional_fields(Envelope, Handler, Fields) ->
    lists:foldl(
        fun({WireKey, HandlerKey}, Acc) ->
            case maps:get(HandlerKey, Handler, undefined) of
                undefined -> Acc;
                <<>> -> Acc;
                V -> Acc#{WireKey => V}
            end
        end,
        Envelope,
        Fields
    ).

%% As above, dropping any field the negotiated revision does not define.
%% A tool whose `outputSchema' cannot be rendered is still listed and
%% still callable; only the field it cannot carry is left out.
with_optional_fields(Envelope, Handler, Ctx, Fields) ->
    Revision = barrel_mcp_ctx:protocol_version(Ctx),
    lists:foldl(
        fun({WireKey, HandlerKey, Feature}, Acc) ->
            case renderable(Feature, Revision) of
                false -> Acc;
                true -> with_optional_fields(Acc, Handler, [{WireKey, HandlerKey}])
            end
        end,
        Envelope,
        Fields
    ).

renderable(always, _Revision) ->
    true;
%% Before anything is negotiated there is no revision to render for, and
%% dropping every optional field would make a probe look impoverished.
renderable(_Feature, undefined) ->
    true;
renderable(Feature, Revision) ->
    barrel_mcp_version:has(Feature, Revision).

%%====================================================================
%% Cursor pagination for `*/list' handlers
%%====================================================================

-define(PAGE_SIZE, 50).

%% Sort `Items' by `KeyFn(Item)', drop everything up to and
%% including `Cursor', take up to `?PAGE_SIZE'. Returns
%% `{Page, NextCursor}' where `NextCursor' is the last key of the
%% page when more items remain, or `undefined' otherwise.
%% `Cursor' is the opaque last-seen key from a prior response.
%% The four catalogue listings differ only in what they list and how one
%% entry is rendered. `tasks/list' is not one of them: it lists from
%% barrel_mcp_tasks and keys on `taskId', not the registry.
registry_page(Kind, WireKey, Params, Id, Render) ->
    Cursor = maps:get(<<"cursor">>, Params, undefined),
    {Page, Next} = paginate(
        barrel_mcp_registry:all(Kind),
        Cursor,
        fun({N, _}) -> N end
    ),
    success_response(Id, with_next_cursor(#{WireKey => lists:map(Render, Page)}, Next)).

paginate(Items, Cursor, KeyFn) ->
    Sorted = lists:sort(fun(A, B) -> KeyFn(A) =< KeyFn(B) end, Items),
    AfterCursor = drop_until_after(Sorted, Cursor, KeyFn),
    case
        lists:split(
            min(?PAGE_SIZE, length(AfterCursor)),
            AfterCursor
        )
    of
        {Page, []} ->
            {Page, undefined};
        {Page, _Rest} ->
            Last = lists:last(Page),
            {Page, KeyFn(Last)}
    end.

drop_until_after(Items, undefined, _) ->
    Items;
drop_until_after(Items, Cursor, KeyFn) ->
    lists:dropwhile(fun(I) -> KeyFn(I) =< Cursor end, Items).

with_next_cursor(Resp, undefined) -> Resp;
with_next_cursor(Resp, Cursor) -> Resp#{<<"nextCursor">> => Cursor}.

%% Pick the protocol version to advertise in the `initialize'
%% response. If the client's requested version is one we speak, echo
%% it; otherwise return our preferred version and let the client
%% decide.
negotiate_protocol_version(undefined) ->
    ?MCP_LATEST_LEGACY_VERSION;
negotiate_protocol_version(Requested) when is_binary(Requested) ->
    case lists:member(Requested, ?MCP_SUPPORTED_VERSIONS) of
        true -> Requested;
        false -> ?MCP_LATEST_LEGACY_VERSION
    end.

%%====================================================================
%% JSON-RPC envelope helpers
%%====================================================================

%% @doc Build a JSON-RPC request envelope.
-spec encode_request(term(), binary(), map()) -> map().
encode_request(Id, Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }.

%% @doc Build a JSON-RPC notification envelope (no id).
-spec encode_notification(binary(), map()) -> map().
encode_notification(Method, Params) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    }.

%% @doc Build a JSON-RPC success response.
-spec encode_response(term(), term()) -> map().
encode_response(Id, Result) ->
    #{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => Result
    }.

%% @doc Build a JSON-RPC error response. Alias of `error_response/3'.
-spec encode_error(term(), integer(), binary()) -> map().
encode_error(Id, Code, Message) ->
    error_response(Id, Code, Message).

%% @doc Classify a decoded JSON-RPC envelope.
%%
%% Returns the kind so client and server agree on routing without each
%% having to peek at the same keys.
-spec decode_envelope(map()) ->
    {request, Id :: term(), Method :: binary(), Params :: map()}
    | {notification, Method :: binary(), Params :: map()}
    | {response, Id :: term(), Result :: term()}
    | {error, Id :: term(), Code :: integer(), Message :: binary(), Data :: term()}
    | {invalid, term()}.
decode_envelope(L) when is_list(L) ->
    {invalid, batch_unsupported};
decode_envelope(#{<<"jsonrpc">> := <<"2.0">>} = Msg) ->
    case
        {
            maps:find(<<"method">>, Msg),
            maps:find(<<"id">>, Msg),
            maps:find(<<"result">>, Msg),
            maps:find(<<"error">>, Msg)
        }
    of
        {{ok, Method}, {ok, Id}, error, error} when
            is_binary(Id) orelse is_integer(Id)
        ->
            {request, Id, Method, maps:get(<<"params">>, Msg, #{})};
        {{ok, _Method}, {ok, _BadId}, error, error} ->
            {invalid, bad_id};
        {{ok, Method}, error, error, error} ->
            {notification, Method, maps:get(<<"params">>, Msg, #{})};
        {error, {ok, Id}, {ok, Result}, error} when
            is_binary(Id) orelse is_integer(Id)
        ->
            {response, Id, Result};
        {error, {ok, _BadId}, {ok, _Result}, error} ->
            {invalid, bad_id};
        {error, {ok, Id}, error, {ok, Err}} when
            is_binary(Id) orelse is_integer(Id)
        ->
            Code = maps:get(<<"code">>, Err, ?JSONRPC_INTERNAL_ERROR),
            Message = maps:get(<<"message">>, Err, <<>>),
            Data = maps:get(<<"data">>, Err, undefined),
            {error, Id, Code, Message, Data};
        {error, {ok, _BadId}, error, {ok, _Err}} ->
            {invalid, bad_id};
        _ ->
            {invalid, malformed}
    end;
decode_envelope(Other) ->
    {invalid, Other}.
