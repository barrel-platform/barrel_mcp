%%%-------------------------------------------------------------------
%%% @doc Cursor-based pagination walker for MCP `*/list' methods.
%%%
%%% Every MCP `*/list' response may include a `nextCursor' that the
%%% client passes back as `cursor' on the next call until the server
%%% omits it. This module turns that loop into a single function call.
%%%
%%% Usage from the client:
%%%
%%% ```
%%% barrel_mcp_pagination:walk(
%%%     fun(Cursor) -> barrel_mcp_client:list_tools(Pid, #{cursor => Cursor, want_cursor => true}) end).
%%% '''
%%%
%%% Returns `{ok, AllItems}' or `{error, Reason}' on the first error.
%%% A `MaxPages' guard prevents accidental runaway pagination.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_pagination).

-export([walk/1, walk/2]).

-type fetch_fun() ::
    fun((undefined | binary()) ->
        {ok, [term()], undefined | binary()} |
        {ok, [term()]} |
        {error, term()}).

-export_type([fetch_fun/0]).

%% @doc Walk pagination starting from no cursor, with a 1000-page cap.
-spec walk(fetch_fun()) -> {ok, [term()]} | {error, term()}.
walk(Fetch) ->
    walk(Fetch, 1000).

%% @doc Walk pagination with an explicit page cap. The cap stops the
%% loop with `{error, max_pages}' before exhausting memory if a server
%% never stops returning a cursor.
-spec walk(fetch_fun(), pos_integer()) ->
    {ok, [term()]} | {error, term()}.
walk(Fetch, MaxPages) when is_function(Fetch, 1), MaxPages > 0 ->
    walk_loop(Fetch, undefined, [], MaxPages).

walk_loop(_Fetch, _Cursor, _Acc, 0) ->
    {error, max_pages};
walk_loop(Fetch, Cursor, Acc, Remaining) ->
    case Fetch(Cursor) of
        {ok, Items, undefined} ->
            {ok, lists:append(lists:reverse([Items | Acc]))};
        {ok, Items} ->
            {ok, lists:append(lists:reverse([Items | Acc]))};
        {ok, Items, NextCursor} when is_binary(NextCursor), NextCursor =/= <<>> ->
            walk_loop(Fetch, NextCursor, [Items | Acc], Remaining - 1);
        {ok, Items, _} ->
            {ok, lists:append(lists:reverse([Items | Acc]))};
        {error, _} = Err ->
            Err
    end.
