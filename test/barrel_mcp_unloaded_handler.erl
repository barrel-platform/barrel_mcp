%%%-------------------------------------------------------------------
%%% @doc A handler in a module the registry has to load itself.
%%%
%%% Nothing else references it, so a test can unload it and register
%%% against it the way an application registering a handler it has never
%%% called does.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_unloaded_handler).

-export([a_tool/2]).

a_tool(_Args, Ctx) ->
    maps:get(tool_name, Ctx, <<"no tool_name">>).
