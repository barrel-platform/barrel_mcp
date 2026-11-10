%%%-------------------------------------------------------------------
%%% @author Benoit Chesneau
%%% @copyright 2024-2026 Benoit Chesneau
%%% @doc Where the OAuth client may connect.
%%%
%%% Every URL the OAuth handle fetches can come from a document the MCP
%%% server chose, so the client refuses private and reserved addresses
%%% (MCP security best practices, "Server-Side Request Forgery";
%%% RFC 9728 section 7.7). The decision is made on the resolved address,
%%% never on the host string, and the request then connects to that
%%% same address: {@link pin/2} returns the URL rewritten to it, with
%%% the original host kept for the `Host' header and TLS SNI, so a name
%%% cannot resolve to a public address for the check and a private one
%%% for the connection.
%%%
%%% Options, read from the same map as `allow_insecure_oauth':
%%% <ul>
%%%   <li>`oauth_allowed_networks': CIDRs (binaries) exempt from the
%%%       block, for an authorization server on an internal network.</li>
%%%   <li>`allow_insecure_oauth => true': also allows loopback, for
%%%       tests against a local mock. Private ranges stay blocked.</li>
%%% </ul>
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_egress).

-export([pin/2, check_addresses/2]).

-export_type([pinned/0]).

-type pinned() :: #{
    url := binary(),
    host := binary() | undefined,
    sni := string() | undefined
}.

%% IANA IPv4 and IPv6 special-purpose address registries.
-define(BLOCKED_V4, [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4"
]).
-define(BLOCKED_V6, [
    "::/128",
    "::1/128",
    "100::/64",
    "2001:db8::/32",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8"
]).
-define(LOOPBACK, ["127.0.0.0/8", "::1/128"]).

%% @doc Resolve `Url''s host, refuse it unless every address is
%% allowed, and return the URL to connect to. An IP-literal host is
%% checked as is and needs no rewrite.
-spec pin(binary(), map()) ->
    {ok, pinned()}
    | {error, {blocked_address, inet:ip_address()} | {unresolved, binary(), term()}}.
pin(Url, Opts) ->
    #{host := Host} = Parsed = uri_string:parse(Url),
    HostStr = binary_to_list(Host),
    case inet:parse_strict_address(HostStr) of
        {ok, Ip} ->
            case check_addresses([Ip], Opts) of
                ok -> {ok, #{url => Url, host => undefined, sni => undefined}};
                {error, _} = Err -> Err
            end;
        {error, einval} ->
            case resolve(HostStr) of
                {ok, [Ip | _] = Ips} ->
                    case check_addresses(Ips, Opts) of
                        ok -> {ok, pinned(Parsed, Ip)};
                        {error, _} = Err -> Err
                    end;
                {error, Reason} ->
                    {error, {unresolved, Host, Reason}}
            end
    end.

%% @doc `ok' when every address is allowed. One blocked address refuses
%% the whole answer: the connection could pick any of them.
-spec check_addresses([inet:ip_address()], map()) ->
    ok | {error, {blocked_address, inet:ip_address()}}.
check_addresses(Ips, Opts) ->
    Allowed = allowed_networks(Opts),
    case [Ip || Ip <- Ips, blocked(Ip, Allowed)] of
        [] -> ok;
        [Ip | _] -> {error, {blocked_address, Ip}}
    end.

resolve(Host) ->
    case {inet:getaddrs(Host, inet), inet:getaddrs(Host, inet6)} of
        {{ok, V4}, {ok, V6}} -> {ok, V4 ++ V6};
        {{ok, V4}, _} -> {ok, V4};
        {_, {ok, V6}} -> {ok, V6};
        {{error, Reason}, _} -> {error, Reason}
    end.

pinned(#{scheme := Scheme, host := Host} = Parsed, Ip) ->
    HostHeader =
        case Parsed of
            #{port := Port} -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>;
            _ -> Host
        end,
    Sni =
        case Scheme of
            <<"https">> -> binary_to_list(Host);
            _ -> undefined
        end,
    Url = uri_string:recompose(Parsed#{host => list_to_binary(inet:ntoa(Ip))}),
    #{url => Url, host => HostHeader, sni => Sni}.

blocked(Ip, Allowed) ->
    Target = embedded_v4(Ip),
    in_any(Target, blocked_ranges()) andalso not in_any(Target, Allowed).

%% IPv4-mapped, NAT64 and 6to4 addresses reach the IPv4 address they
%% carry, so they are judged as that address.
embedded_v4({0, 0, 0, 0, 0, 16#ffff, Hi, Lo}) -> v4(Hi, Lo);
embedded_v4({16#64, 16#ff9b, 0, 0, 0, 0, Hi, Lo}) -> v4(Hi, Lo);
embedded_v4({16#2002, Hi, Lo, _, _, _, _, _}) -> v4(Hi, Lo);
embedded_v4(Ip) -> Ip.

v4(Hi, Lo) -> {Hi bsr 8, Hi band 255, Lo bsr 8, Lo band 255}.

blocked_ranges() ->
    [hackney_cidr:parse(C) || C <- ?BLOCKED_V4 ++ ?BLOCKED_V6].

allowed_networks(Opts) ->
    Loopback =
        case maps:get(allow_insecure_oauth, Opts, false) of
            true -> ?LOOPBACK;
            _ -> []
        end,
    [hackney_cidr:parse(C) || C <- Loopback ++ maps:get(oauth_allowed_networks, Opts, [])].

in_any(Ip, Ranges) ->
    lists:any(fun(R) -> hackney_cidr:contains(R, Ip) end, Ranges).
