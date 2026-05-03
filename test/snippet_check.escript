#!/usr/bin/env escript
%%! -noshell
%%
%% snippet_check — extract every ```erlang fenced block from the
%% project's documentation and verify each compiles.
%%
%% Usage:
%%   escript test/snippet_check.escript
%%
%% Conventions:
%%   - Fences with info string `erlang' are compiled.
%%   - Fences with info string `erl' (or any other) are skipped — use
%%     them for illustrative output, REPL transcripts, or fragments
%%     that aren't expected to compile in isolation.
%%   - A snippet that starts with `-module(' is treated as a complete
%%     module and compiled as-is.
%%   - Otherwise the snippet is wrapped in a synthetic module:
%%       -module(snippet_<n>).
%%       -compile([export_all, nowarn_export_all]).
%%       -include_lib("kernel/include/file.hrl").
%%       doc_snippet() ->
%%           <body>.
%%     If the body lacks a trailing dot it is added.
%%
%% Output:
%%   Lists every snippet ("OK" or "FAIL") with file:line. Exits 0 iff
%%   every `erlang'-tagged fence compiled.

main(_) ->
    Files = collect_doc_files(),
    Results = lists:flatmap(fun check_file/1, Files),
    Failures = [R || {fail, _, _, _} = R <- Results],
    case Failures of
        [] ->
            io:format("snippet_check: ~B snippet(s) OK~n", [length(Results)]),
            erlang:halt(0);
        _ ->
            io:format("~nsnippet_check: ~B failure(s):~n", [length(Failures)]),
            lists:foreach(fun({fail, F, L, Reason}) ->
                io:format("  ~s:~B  ~p~n", [F, L, Reason])
            end, Failures),
            erlang:halt(1)
    end.

%%====================================================================
%% Discovery
%%====================================================================

%% New, snippet-tested docs only. Older guides (client.md, http-stream.md,
%% etc.) remain illustrative — port them over when their snippets are
%% rewritten to compile standalone.
collect_doc_files() ->
    Globs = ["guides/building-a-client.md",
             "guides/internals.md",
             "examples/*/README.md"],
    lists:flatmap(fun(G) -> filelib:wildcard(G) end, Globs).

%%====================================================================
%% Per-file extraction
%%====================================================================

check_file(File) ->
    {ok, Bin} = file:read_file(File),
    Lines = binary:split(Bin, <<"\n">>, [global]),
    {Snippets, _} = extract_snippets(Lines, 1, [], undefined),
    [check_snippet(File, Snip) || Snip <- lists:reverse(Snippets)].

%% State machine: outside a fence, look for ```erlang start; inside,
%% accumulate until the closing ```. Other fence types are skipped.
extract_snippets([], _, Acc, _) ->
    {Acc, undefined};
extract_snippets([Line | Rest], LineNo, Acc, undefined) ->
    case fence_open(Line) of
        {erlang, _Tag} ->
            extract_snippets(Rest, LineNo + 1, Acc, {LineNo, []});
        {skip, _Tag} ->
            extract_snippets(Rest, LineNo + 1, Acc, skip);
        none ->
            extract_snippets(Rest, LineNo + 1, Acc, undefined)
    end;
extract_snippets([Line | Rest], LineNo, Acc, skip) ->
    case is_fence_close(Line) of
        true -> extract_snippets(Rest, LineNo + 1, Acc, undefined);
        false -> extract_snippets(Rest, LineNo + 1, Acc, skip)
    end;
extract_snippets([Line | Rest], LineNo, Acc, {Start, Buf}) ->
    case is_fence_close(Line) of
        true ->
            Body = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Buf))),
            extract_snippets(Rest, LineNo + 1,
                             [{Start, Body} | Acc], undefined);
        false ->
            extract_snippets(Rest, LineNo + 1, Acc, {Start, [Line | Buf]})
    end.

fence_open(Line) ->
    Trim = string:trim(Line),
    case Trim of
        <<"```erlang", _/binary>> -> {erlang, <<"erlang">>};
        <<"```erl">> -> {skip, <<"erl">>};
        <<"```erl ", _/binary>> -> {skip, <<"erl">>};
        <<"```", Rest/binary>> when Rest =/= <<>> -> {skip, Rest};
        <<"```">> -> {skip, <<>>};
        _ -> none
    end.

is_fence_close(Line) ->
    case string:trim(Line) of
        <<"```">> -> true;
        _ -> false
    end.

%%====================================================================
%% Per-snippet compile
%%====================================================================

check_snippet(File, {Line, Body}) ->
    case classify(Body) of
        skip ->
            io:format("SKIP ~s:~B (empty)~n", [File, Line]),
            {ok, File, Line};
        {module, Forms} ->
            try_compile(File, Line, Forms);
        {expression, Forms} ->
            try_compile(File, Line, Forms)
    end.

classify(Body) ->
    case string:trim(Body) of
        <<>> -> skip;
        Trimmed ->
            case binary:match(Trimmed, <<"-module(">>) of
                {0, _} -> {module, Trimmed};
                _ ->
                    case looks_like_function_defs(Trimmed) of
                        true -> {module, wrap_module(Trimmed)};
                        false -> {expression, wrap_expr(Trimmed)}
                    end
            end
    end.

%% A snippet is treated as one or more function definitions when it
%% starts with `name(...) ->'. Anything else is wrapped as the body of
%% a synthetic `doc_snippet/0' function.
looks_like_function_defs(Body) ->
    case re:run(Body, "^[a-z_][a-zA-Z0-9_]*\\s*\\(.*?\\)\\s*->",
                [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

wrap_module(Body) ->
    Body1 = ensure_trailing_dot(Body),
    iolist_to_binary([
        <<"-module(">>, synthetic_module_atom(),
        <<").\n-compile([export_all, nowarn_export_all]).\n">>,
        Body1
    ]).

wrap_expr(Body) ->
    Body1 = case binary:last(Body) of
        $. -> binary:part(Body, 0, byte_size(Body) - 1);
        _ -> Body
    end,
    iolist_to_binary([
        <<"-module(">>, synthetic_module_atom(),
        <<").\n-compile([export_all, nowarn_export_all]).\n">>,
        <<"doc_snippet() ->\n">>,
        Body1, <<".\n">>
    ]).

ensure_trailing_dot(Body) ->
    case binary:last(Body) of
        $. -> Body;
        _ -> <<Body/binary, ".">>
    end.

synthetic_module_atom() ->
    list_to_binary("snippet_" ++
                   integer_to_list(erlang:unique_integer([positive]))).

try_compile(File, Line, Source) ->
    Module = synthetic_module_name(),
    SrcFile = "/tmp/" ++ Module ++ ".erl",
    case file:write_file(SrcFile, Source) of
        ok ->
            case compile:file(SrcFile, [binary, return_errors, return_warnings,
                                        {warn_format, 0}]) of
                {ok, _, _, _} ->
                    file:delete(SrcFile),
                    io:format("OK   ~s:~B~n", [File, Line]),
                    {ok, File, Line};
                {ok, _, _} ->
                    file:delete(SrcFile),
                    io:format("OK   ~s:~B~n", [File, Line]),
                    {ok, File, Line};
                {error, Errors, Warnings} ->
                    file:delete(SrcFile),
                    io:format("FAIL ~s:~B~n", [File, Line]),
                    {fail, File, Line, {Errors, Warnings}}
            end;
        Err ->
            {fail, File, Line, {write_failed, Err}}
    end.

synthetic_module_name() ->
    "snippet_" ++ integer_to_list(erlang:unique_integer([positive])).
