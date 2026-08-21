%%%-------------------------------------------------------------------
%%% @doc barrel_mcp application module.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% Application callbacks
%%====================================================================

start(_StartType, _StartArgs) ->
    %% Seed the MRTR signing key before any request can need it, so
    %% concurrent requests never race to generate an ephemeral one.
    _ = barrel_mcp_request_state:ensure_key(),
    barrel_mcp_sup:start_link().

stop(_State) ->
    ok.
