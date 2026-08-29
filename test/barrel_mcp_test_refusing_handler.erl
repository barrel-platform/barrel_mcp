%%%-------------------------------------------------------------------
%%% @doc A client handler whose `init/1' refuses once told to, so a
%%% supervised restart fails synchronously and the supervisor sits in
%%% its `restarting' state for the test to observe.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_test_refusing_handler).

-behaviour(barrel_mcp_client_handler).

-export([init/1, handle_request/3, handle_notification/3]).
-export([refuse/1]).

-define(KEY, {?MODULE, refuse}).

%% @doc Make every following `init/1' fail (`true') or succeed.
-spec refuse(boolean()) -> ok.
refuse(Bool) ->
    persistent_term:put(?KEY, Bool).

init(_Args) ->
    case persistent_term:get(?KEY, false) of
        true ->
            %% Ten instant refusals exhaust the supervisor's intensity
            %% (10 in 60 s); pacing them keeps the window open ~1 s.
            timer:sleep(100),
            {error, refused};
        false ->
            {ok, #{}}
    end.

handle_request(Method, _Params, State) ->
    {error, {method_not_found, Method}, State}.

handle_notification(_Method, _Params, State) ->
    {ok, State}.
