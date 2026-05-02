%%%-------------------------------------------------------------------
%%% @doc Default no-op handler for `barrel_mcp_client'.
%%%
%%% Replies `method_not_found' to every server-initiated request and
%%% ignores every notification. Hosts that declare no client
%%% capabilities can use this as their handler; hosts that declare
%%% capabilities should provide their own module.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_handler_default).

-behaviour(barrel_mcp_client_handler).

-export([init/1, handle_request/3, handle_notification/3, terminate/2]).

-include("barrel_mcp.hrl").

init(_Args) ->
    {ok, undefined}.

handle_request(Method, _Params, State) ->
    {error, ?JSONRPC_METHOD_NOT_FOUND,
     <<"Method not found: ", Method/binary>>, State}.

handle_notification(_Method, _Params, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.
