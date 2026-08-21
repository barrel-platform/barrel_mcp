%%%-------------------------------------------------------------------
%%% @doc A client handler for multi round-trip tests.
%%%
%%% `sync' answers elicitation immediately; `async' defers, sending the
%%% tag to the process that started the client so the test can decide
%%% when to reply.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_test_handler).

-behaviour(barrel_mcp_client_handler).

-export([init/1, handle_request/3, handle_notification/3]).

%% The owner is passed in rather than taken from `self()': init/1 runs
%% inside the client process, so `self()' here is the client, not
%% whoever started it.
init(#{mode := _} = Args) ->
    {ok, Args}.

handle_request(<<"elicitation/create">>, _Params, #{mode := sync} = S) ->
    {reply, #{<<"action">> => <<"accept">>, <<"content">> => #{<<"name">> => <<"ada">>}}, S};
handle_request(<<"elicitation/create">>, _Params, #{mode := async, owner := Owner} = S) ->
    Tag = make_ref(),
    Owner ! {deferred, Tag},
    {async, Tag, S};
%% Never answers, so the round stays open and the shared deadline is
%% what ends the call.
handle_request(<<"elicitation/create">>, _Params, #{mode := never} = S) ->
    {async, make_ref(), S};
handle_request(_Method, _Params, S) ->
    {error, -32601, <<"Method not found">>, S}.

handle_notification(_Method, _Params, S) ->
    {ok, S}.
