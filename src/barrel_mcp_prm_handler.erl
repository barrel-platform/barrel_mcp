%%%-------------------------------------------------------------------
%%% @doc Cowboy handler for `/.well-known/oauth-protected-resource'.
%%%
%%% Returns the OAuth Protected Resource Metadata document
%%% ([RFC 9728]) as JSON. Configured via the `resource_metadata'
%%% option on `barrel_mcp_http_stream:start/1' /
%%% `barrel_mcp_http:start/1'.
%%%
%%% This is the server-side counterpart of
%%% `barrel_mcp_client_auth_oauth:discover_protected_resource/1'.
%%% MCP clients hitting an OAuth-protected barrel_mcp server
%%% receive a 401 with `WWW-Authenticate: Bearer ...
%%% resource_metadata="<URL>"', follow that URL, and land here.
%%%
%%% [RFC 9728]: https://datatracker.ietf.org/doc/html/rfc9728
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_prm_handler).

-export([init/2]).

init(Req0, Metadata) when is_map(Metadata) ->
    Body = iolist_to_binary(json:encode(Metadata)),
    Req = cowboy_req:reply(200, #{
        <<"content-type">> => <<"application/json">>,
        <<"cache-control">> => <<"public, max-age=300">>
    }, Body, Req0),
    {ok, Req, Metadata}.
