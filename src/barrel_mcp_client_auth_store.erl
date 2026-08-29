%%%-------------------------------------------------------------------
%%% @doc Persistence for what an OAuth client handle learns: the
%%% client it registered (or was given) and the tokens it holds.
%%%
%%% Without a store both live in the handle and die with the client
%%% process. A host that wants them to survive a restart gives the
%%% `{oauth, Config}' a `store => {Module, Arg}' implementing this
%%% behaviour. Keys are `client' and `tokens'; values are maps the
%%% handle owns the shape of.
%%%
%%% Deleting matters as much as writing: when the resource's
%%% authorization server changes, the handle drops both and registers
%%% again, and a store that ignored the delete would hand the old
%%% credential back on the next start.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_auth_store).

-export([get/3, put/3, delete/2]).

-type key() :: client | tokens.
-type store() :: {module(), term()} | undefined.

-export_type([key/0, store/0]).

-callback get(key(), Arg :: term()) -> {ok, map()} | undefined.
-callback put(key(), map(), Arg :: term()) -> ok.
-callback delete(key(), Arg :: term()) -> ok.

%% @doc Read `Key' from `Store', `Default' without one or when unset.
-spec get(store(), key(), map() | undefined) -> map() | undefined.
get(undefined, _Key, Default) ->
    Default;
get({Mod, Arg}, Key, Default) ->
    case Mod:get(Key, Arg) of
        {ok, Value} when is_map(Value) -> Value;
        _ -> Default
    end.

-spec put(store(), key(), map()) -> ok.
put(undefined, _Key, _Value) ->
    ok;
put({Mod, Arg}, Key, Value) ->
    Mod:put(Key, Value, Arg).

-spec delete(store(), key()) -> ok.
delete(undefined, _Key) ->
    ok;
delete({Mod, Arg}, Key) ->
    Mod:delete(Key, Arg).
