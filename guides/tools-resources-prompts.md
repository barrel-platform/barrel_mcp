# Tools, Resources & Prompts

The Model Context Protocol defines three core primitives for exposing functionality
to AI assistants. barrel_mcp provides a simple, consistent API for all three.

## Tools

Tools are functions that the AI can call to perform actions or retrieve information.

### Registering a Tool

```erlang
-module(my_tools).
-export([search/1, calculate/1]).

%% Simple tool returning text
search(Args) ->
    Query = maps:get(<<"query">>, Args),
    %% Return a binary string
    <<"Results for: ", Query/binary>>.

%% Tool returning structured data (auto-converted to JSON)
calculate(Args) ->
    A = maps:get(<<"a">>, Args),
    B = maps:get(<<"b">>, Args),
    Op = maps:get(<<"op">>, Args, <<"add">>),
    Result = case Op of
        <<"add">> -> A + B;
        <<"sub">> -> A - B;
        <<"mul">> -> A * B;
        <<"div">> -> A / B
    end,
    #{<<"result">> => Result, <<"operation">> => Op}.
```

Register with full schema:

```erlang
barrel_mcp:reg_tool(<<"search">>, my_tools, search, #{
    description => <<"Search for information">>,
    input_schema => #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"query">> => #{
                <<"type">> => <<"string">>,
                <<"description">> => <<"Search query">>
            }
        },
        <<"required">> => [<<"query">>]
    }
}).

barrel_mcp:reg_tool(<<"calculate">>, my_tools, calculate, #{
    description => <<"Perform arithmetic operations">>,
    input_schema => #{
        <<"type">> => <<"object">>,
        <<"properties">> => #{
            <<"a">> => #{<<"type">> => <<"number">>},
            <<"b">> => #{<<"type">> => <<"number">>},
            <<"op">> => #{
                <<"type">> => <<"string">>,
                <<"enum">> => [<<"add">>, <<"sub">>, <<"mul">>, <<"div">>],
                <<"default">> => <<"add">>
            }
        },
        <<"required">> => [<<"a">>, <<"b">>]
    }
}).
```

### Tool Return Values

Tools can return any of:

```erlang
%% Binary -> single text content block.
text_tool(_Args) ->
    <<"Hello, World!">>.

%% Map -> JSON-encoded text content block.
json_tool(_Args) ->
    #{<<"key">> => <<"value">>, <<"count">> => 42}.

%% List of content blocks -> verbatim.
multi_tool(_Args) ->
    [
        #{<<"type">> => <<"text">>, <<"text">> => <<"First result">>},
        #{<<"type">> => <<"text">>, <<"text">> => <<"Second result">>}
    ].

%% Image content block.
image_tool(_Args) ->
    ImageData = base64:encode(read_image_file()),
    #{
        <<"type">> => <<"image">>,
        <<"data">> => ImageData,
        <<"mimeType">> => <<"image/png">>
    }.

%% Tool-level error: rendered as `{ "isError": true, "content": [...] }'
%% on the wire. Use this for failures that are part of the tool's
%% domain (validation, business rules) rather than infrastructure.
flaky_tool(_Args) ->
    {tool_error, [#{<<"type">> => <<"text">>,
                    <<"text">> => <<"Quota exceeded">>}]}.

%% Structured output: machine-readable data plus optional human-readable
%% content blocks. Surfaces as `structuredContent' on the wire.
%% Pair with the `output_schema' option to validate the data shape.
weather(_Args) ->
    {structured, #{<<"tempF">> => 72, <<"sky">> => <<"clear">>},
     [#{<<"type">> => <<"text">>, <<"text">> => <<"72°F, clear">>}]}.
```

`{tool_error, Content}` and `{structured, Data, Content}` are the
recommended shapes. Plain returns still work; raised exceptions are
caught and surfaced as a JSON-RPC error to the client.

### Async handlers (`Ctx`-aware)

Tools may be exported as arity 2 instead of arity 1. The second
argument is a context map the runtime fills in:

```erlang
%% (Args, Ctx) -> Result. Ctx holds:
%%   session_id     :: binary() | undefined,
%%   request_id     :: integer() | binary(),
%%   progress_token :: binary() | undefined,
%%   emit_progress  :: fun((Done, Total, Message | undefined) -> ok)
download(Args, Ctx) ->
    Url = maps:get(<<"url">>, Args),
    Emit = maps:get(emit_progress, Ctx),
    Emit(0.0, 1.0, undefined),
    {ok, Body} = fetch(Url),
    Emit(1.0, 1.0, undefined),
    Body.
```

Arity-2 handlers are needed for tools that:

- emit `notifications/progress` updates,
- cooperate with `notifications/cancelled` (the worker receives
  `{cancel, RequestId}` in its mailbox),
- need the calling session id for server→client primitives.

Arity-1 handlers continue to work; pick whichever arity you need.

### Long-running tools (tasks)

Set `long_running => true` on `reg_tool/4` and the tool returns
immediately to the client with a `taskId`. The handler keeps
running in the background and the runtime stores its eventual
outcome on the task. Clients track progress via `tasks/get`,
`tasks/list`, or `notifications/tasks/changed`.

```erlang
barrel_mcp:reg_tool(<<"render_video">>, my_tools, render_video, #{
    long_running => true,
    description => <<"Render a video on the GPU farm">>
}).
```

The same handler shape (arity 1 or arity 2) applies. Long-running
handlers may emit progress just like any other tool.

### Schema validation

Two opt-in flags on `reg_tool/4`:

```erlang
barrel_mcp:reg_tool(<<"search">>, my_tools, search, #{
    input_schema => #{<<"type">> => <<"object">>,
                       <<"required">> => [<<"query">>]},
    output_schema => #{<<"type">> => <<"object">>,
                        <<"required">> => [<<"results">>]},
    validate_input  => true,
    validate_output => true
}).
```

`validate_input` checks the call's `arguments` against
`input_schema` before invoking the handler. `validate_output`
checks the structured `Data` from `{structured, Data, _}` returns
against `output_schema`. Failures surface to the client as
`isError: true` content. The validator subset is documented under
`barrel_mcp_schema`.

### Metadata: `title` and `icons`

Every registration accepts a human-readable `title` and a list of
`icons` (each `#{src, sizes?, mime_type?}`). Both surface in the
matching `*/list` response. Empty fields are omitted from the
wire.

```erlang
barrel_mcp:reg_tool(<<"search">>, my_tools, search, #{
    title => <<"Knowledge Base Search">>,
    icons => [#{<<"src">> => <<"https://example.com/icon.png">>,
                 <<"sizes">> => <<"32x32">>}]
}).
```

### Managing Tools

```erlang
%% List all tools
Tools = barrel_mcp:list_tools().

%% Call a tool locally (for testing)
Result = barrel_mcp:call_tool(<<"search">>, #{<<"query">> => <<"test">>}).

%% Unregister a tool
barrel_mcp:unreg_tool(<<"search">>).
```

## Resources

Resources expose data that the AI can read, like files or configuration.

### Registering a Resource

```erlang
-module(my_resources).
-export([get_config/1, get_users/1]).

%% Text resource
get_config(_Args) ->
    <<"app_name=MyApp\nversion=1.0.0\ndebug=false">>.

%% JSON resource (map auto-encoded)
get_users(_Args) ->
    #{
        <<"users">> => [
            #{<<"id">> => 1, <<"name">> => <<"Alice">>},
            #{<<"id">> => 2, <<"name">> => <<"Bob">>}
        ]
    }.
```

Register resources:

```erlang
barrel_mcp:reg_resource(<<"config">>, my_resources, get_config, #{
    name => <<"Application Configuration">>,
    uri => <<"config://app/settings">>,
    description => <<"Current application settings">>,
    mime_type => <<"text/plain">>
}).

barrel_mcp:reg_resource(<<"users">>, my_resources, get_users, #{
    name => <<"User List">>,
    uri => <<"app://users/list">>,
    description => <<"All registered users">>,
    mime_type => <<"application/json">>
}).
```

### Binary Resources

For binary data like images or files:

```erlang
get_logo(_Args) ->
    #{
        blob => read_file("logo.png"),
        mimeType => <<"image/png">>
    }.
```

Register:

```erlang
barrel_mcp:reg_resource(<<"logo">>, my_resources, get_logo, #{
    name => <<"Company Logo">>,
    uri => <<"assets://logo">>,
    mime_type => <<"image/png">>
}).
```

### Managing Resources

```erlang
%% List all resources
Resources = barrel_mcp:list_resources().

%% Read a resource locally
Content = barrel_mcp:read_resource(<<"config">>).

%% Unregister
barrel_mcp:unreg_resource(<<"config">>).
```

## Prompts

Prompts are pre-defined conversation templates that the AI can use.

### Registering a Prompt

```erlang
-module(my_prompts).
-export([summarize/1, translate/1]).

summarize(Args) ->
    Content = maps:get(<<"content">>, Args),
    Style = maps:get(<<"style">>, Args, <<"concise">>),
    #{
        description => <<"Summarize the provided content">>,
        messages => [
            #{
                role => <<"user">>,
                content => #{
                    type => <<"text">>,
                    text => <<"Please summarize the following in a ",
                              Style/binary, " style:\n\n", Content/binary>>
                }
            }
        ]
    }.

translate(Args) ->
    Text = maps:get(<<"text">>, Args),
    TargetLang = maps:get(<<"target_language">>, Args),
    #{
        description => <<"Translate text to another language">>,
        messages => [
            #{
                role => <<"system">>,
                content => #{
                    type => <<"text">>,
                    text => <<"You are a professional translator.">>
                }
            },
            #{
                role => <<"user">>,
                content => #{
                    type => <<"text">>,
                    text => <<"Translate the following to ",
                              TargetLang/binary, ":\n\n", Text/binary>>
                }
            }
        ]
    }.
```

Register prompts:

```erlang
barrel_mcp:reg_prompt(<<"summarize">>, my_prompts, summarize, #{
    description => <<"Summarize content in various styles">>,
    arguments => [
        #{
            name => <<"content">>,
            description => <<"The content to summarize">>,
            required => true
        },
        #{
            name => <<"style">>,
            description => <<"Summary style: concise, detailed, or bullet">>,
            required => false
        }
    ]
}).

barrel_mcp:reg_prompt(<<"translate">>, my_prompts, translate, #{
    description => <<"Translate text to another language">>,
    arguments => [
        #{
            name => <<"text">>,
            description => <<"Text to translate">>,
            required => true
        },
        #{
            name => <<"target_language">>,
            description => <<"Target language (e.g., Spanish, French)">>,
            required => true
        }
    ]
}).
```

### Multi-Turn Prompts

Create prompts with conversation history:

```erlang
code_review(Args) ->
    Code = maps:get(<<"code">>, Args),
    Language = maps:get(<<"language">>, Args, <<"unknown">>),
    #{
        description => <<"Interactive code review session">>,
        messages => [
            #{
                role => <<"system">>,
                content => #{
                    type => <<"text">>,
                    text => <<"You are a senior ", Language/binary,
                              " developer performing a code review.">>
                }
            },
            #{
                role => <<"user">>,
                content => #{
                    type => <<"text">>,
                    text => <<"Please review this code:\n\n```",
                              Language/binary, "\n", Code/binary, "\n```">>
                }
            },
            #{
                role => <<"assistant">>,
                content => #{
                    type => <<"text">>,
                    text => <<"I'll analyze this code for:\n",
                              "1. Correctness\n2. Performance\n",
                              "3. Security\n4. Best practices\n\n",
                              "Let me start the review...">>
                }
            }
        ]
    }.
```

### Managing Prompts

```erlang
%% List all prompts
Prompts = barrel_mcp:list_prompts().

%% Get a prompt with arguments
PromptResult = barrel_mcp:get_prompt(<<"summarize">>, #{
    <<"content">> => <<"Long text here...">>,
    <<"style">> => <<"bullet">>
}).

%% Unregister
barrel_mcp:unreg_prompt(<<"summarize">>).
```

## Resource Templates

URI templates (RFC 6570) advertise families of resources without
enumerating every URI. Register one handler per template:

```erlang
barrel_mcp:reg_resource_template(<<"file">>, my_resources, read_file_uri, #{
    name => <<"File Reader">>,
    uri_template => <<"file:///{path}">>,
    description => <<"Read any file on the local FS">>,
    mime_type => <<"text/plain">>
}).
```

`barrel_mcp:list_resource_templates/0` lists registrations.
Templates surface on the wire via `resources/templates/list`. The
matching `resources/read` request still goes through your normal
resource handler (or directly through the template handler if you
implement URI parsing yourself).

## Completions

Completion handlers suggest values for a prompt argument or a
resource-template argument. Register them keyed by the parent
plus the argument name:

```erlang
suggest_lengths(<<"sh">>, _Ctx) -> {ok, [<<"short">>]};
suggest_lengths(_, _Ctx)        -> {ok, [<<"short">>, <<"medium">>, <<"long">>]}.

barrel_mcp:reg_completion(
    {prompt, <<"summarize">>, <<"length">>},
    my_completions, suggest_lengths, #{}).
```

Handlers are arity 2: `(PartialValue, Ctx)`. Return one of:

- `{ok, [Suggestion]}` — full list.
- `{ok, [Suggestion], #{has_more => true}}` — more available; the
  client can issue another `completion/complete` to drill in.

The `completions` capability is advertised in `initialize` as soon
as at least one completion handler is registered.

## Tasks (long-running operations)

The `barrel_mcp_tasks` module backs the `tasks/list`, `tasks/get`,
and `tasks/cancel` MCP methods, plus the
`notifications/tasks/changed` notifications.

You don't usually call this module directly: registering a tool
with `long_running => true` (see above) wires the lifecycle for
you. The collector process records the worker's eventual outcome
as a task transition (`running` → `success | error | cancelled`)
and emits the matching notification on the session's SSE channel.

Hosts that drive their own long-running operations outside the
tool path can use the public API:

```erlang
{ok, TaskId} = barrel_mcp_tasks:create(SessionId, <<"reindex">>, #{}),
%% later:
ok = barrel_mcp_tasks:finish(SessionId, TaskId, #{<<"reindexed">> => 12000}).
```

Tasks are evicted from memory one hour after they reach a terminal
state (success / error / cancelled).

## Server → client notifications

Every notification the server can emit goes through the session's
SSE channel:

| Notification | Façade |
| --- | --- |
| `notifications/resources/updated` | `barrel_mcp:notify_resource_updated/1,2` |
| `notifications/tools/list_changed`<br>`notifications/resources/list_changed`<br>`notifications/prompts/list_changed` | `barrel_mcp:notify_list_changed/1` (tool, resource, prompt). `reg_tool/4`/`unreg_tool/1` and friends emit it automatically; call the façade if you mutate the catalogue out of band. |
| `notifications/progress` | `barrel_mcp:notify_progress/3,4` (or via `Ctx` from an arity-2 tool handler). |
| `notifications/tasks/changed` | Emitted by `barrel_mcp_tasks` on every status transition. |
| `notifications/message` (logging) | Emitted by `barrel_mcp_session` when a host calls `logger`-style helpers. |

## Handler Best Practices

### 1. Validate Input

```erlang
my_tool(Args) ->
    case maps:find(<<"required_field">>, Args) of
        {ok, Value} when is_binary(Value), Value =/= <<>> ->
            process(Value);
        _ ->
            error({invalid_input, <<"required_field is mandatory">>})
    end.
```

### 2. Handle Errors Gracefully

```erlang
my_tool(Args) ->
    try
        do_risky_operation(Args)
    catch
        error:Reason ->
            %% Log for debugging
            logger:error("Tool failed: ~p", [Reason]),
            %% Return user-friendly error
            error({tool_error, <<"Operation failed, please try again">>})
    end.
```

### 3. Use Authentication Info

```erlang
my_tool(Args) ->
    case maps:get(<<"_auth">>, Args, undefined) of
        #{subject := UserId, scopes := Scopes} ->
            case lists:member(<<"admin">>, Scopes) of
                true -> admin_operation(UserId, Args);
                false -> user_operation(UserId, Args)
            end;
        undefined ->
            public_operation(Args)
    end.
```

### 4. Return Consistent Types

Pick one return type per tool and document it:

```erlang
%% @doc Always returns a map with status and data
my_tool(Args) ->
    case process(Args) of
        {ok, Data} ->
            #{<<"status">> => <<"success">>, <<"data">> => Data};
        {error, Reason} ->
            #{<<"status">> => <<"error">>, <<"message">> => Reason}
    end.
```
