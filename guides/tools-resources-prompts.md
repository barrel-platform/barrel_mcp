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

Tools can return different types:

```erlang
%% Binary - returned as text content
text_tool(_Args) ->
    <<"Hello, World!">>.

%% Map - automatically JSON encoded
json_tool(_Args) ->
    #{<<"key">> => <<"value">>, <<"count">> => 42}.

%% List of content blocks - for multiple outputs
multi_tool(_Args) ->
    [
        #{<<"type">> => <<"text">>, <<"text">> => <<"First result">>},
        #{<<"type">> => <<"text">>, <<"text">> => <<"Second result">>}
    ].

%% Image content
image_tool(_Args) ->
    ImageData = base64:encode(read_image_file()),
    #{
        <<"type">> => <<"image">>,
        <<"data">> => ImageData,
        <<"mimeType">> => <<"image/png">>
    }.
```

### Error Handling

Return errors for graceful failure:

```erlang
safe_divide(Args) ->
    A = maps:get(<<"a">>, Args),
    B = maps:get(<<"b">>, Args),
    case B of
        0 -> error(division_by_zero);
        _ -> #{<<"result">> => A / B}
    end.
```

Errors are caught and returned as MCP error responses.

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
