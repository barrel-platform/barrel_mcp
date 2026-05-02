%%%-------------------------------------------------------------------
%%% @doc Tests for the `barrel_mcp_client_handler' behaviour and the
%%% default no-op implementation.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_handler_tests).

-include_lib("eunit/include/eunit.hrl").

default_handler_test_() ->
    [
     {"init returns ok",
      fun() ->
          {ok, _State} = barrel_mcp_client_handler_default:init([])
      end},
     {"unknown request returns method_not_found",
      fun() ->
          {ok, S} = barrel_mcp_client_handler_default:init([]),
          {error, Code, Msg, _S1} =
              barrel_mcp_client_handler_default:handle_request(
                <<"sampling/createMessage">>, #{}, S),
          ?assertEqual(-32601, Code),
          ?assert(is_binary(Msg))
      end},
     {"notification is ignored",
      fun() ->
          {ok, S} = barrel_mcp_client_handler_default:init([]),
          {ok, S1} = barrel_mcp_client_handler_default:handle_notification(
                       <<"notifications/message">>, #{}, S),
          ?assertEqual(S, S1)
      end}
    ].
