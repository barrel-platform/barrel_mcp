%%%-------------------------------------------------------------------
%%% @doc Tests for `barrel_mcp_client_egress': which addresses the OAuth
%%% client may connect to, and that a refused URL never opens a socket.
%%% @end
%%%-------------------------------------------------------------------
-module(barrel_mcp_client_egress_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Address decision
%%====================================================================

blocks_special_purpose_addresses_test() ->
    lists:foreach(
        fun(Ip) ->
            ?assertEqual(
                {error, {blocked_address, Ip}},
                barrel_mcp_client_egress:check_addresses([Ip], #{}),
                Ip
            )
        end,
        [
            {0, 0, 0, 0},
            {10, 1, 2, 3},
            {100, 64, 0, 1},
            {127, 0, 0, 1},
            {169, 254, 169, 254},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 0, 0, 1},
            {192, 0, 2, 1},
            {192, 168, 1, 1},
            {198, 18, 0, 1},
            {198, 51, 100, 1},
            {203, 0, 113, 1},
            {224, 0, 0, 1},
            {255, 255, 255, 255},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {16#100, 0, 0, 0, 0, 0, 0, 1},
            {16#2001, 16#db8, 0, 0, 0, 0, 0, 1},
            {16#fd00, 16#ec2, 0, 0, 0, 0, 0, 16#254},
            {16#fe80, 0, 0, 0, 0, 0, 0, 1},
            {16#ff02, 0, 0, 0, 0, 0, 0, 1}
        ]
    ).

allows_public_addresses_test() ->
    ?assertEqual(
        ok,
        barrel_mcp_client_egress:check_addresses(
            [{8, 8, 8, 8}, {172, 32, 0, 1}, {16#2606, 16#4700, 0, 0, 0, 0, 0, 16#1111}], #{}
        )
    ).

%% IPv4-mapped, NAT64 and 6to4 addresses are judged on the IPv4 they carry.
judges_embedded_ipv4_test() ->
    Mapped = {0, 0, 0, 0, 0, 16#ffff, 16#a9fe, 16#a9fe},
    Nat64 = {16#64, 16#ff9b, 0, 0, 0, 0, 16#7f00, 1},
    SixToFour = {16#2002, 16#c0a8, 16#0101, 0, 0, 0, 0, 1},
    lists:foreach(
        fun(Ip) ->
            ?assertEqual(
                {error, {blocked_address, Ip}},
                barrel_mcp_client_egress:check_addresses([Ip], #{}),
                Ip
            )
        end,
        [Mapped, Nat64, SixToFour]
    ),
    ?assertEqual(
        ok,
        barrel_mcp_client_egress:check_addresses([{0, 0, 0, 0, 0, 16#ffff, 16#0808, 16#0808}], #{})
    ).

%% The connection could use any address of the answer.
refuses_a_mixed_answer_test() ->
    ?assertEqual(
        {error, {blocked_address, {10, 0, 0, 5}}},
        barrel_mcp_client_egress:check_addresses([{8, 8, 8, 8}, {10, 0, 0, 5}], #{})
    ).

allowed_networks_exempt_test() ->
    Opts = #{oauth_allowed_networks => [<<"10.20.0.0/16">>]},
    ?assertEqual(ok, barrel_mcp_client_egress:check_addresses([{10, 20, 3, 4}], Opts)),
    ?assertEqual(
        {error, {blocked_address, {10, 21, 0, 1}}},
        barrel_mcp_client_egress:check_addresses([{10, 21, 0, 1}], Opts)
    ).

%% The test-only flag opens loopback, and nothing else.
insecure_flag_allows_only_loopback_test() ->
    Opts = #{allow_insecure_oauth => true},
    ?assertEqual(ok, barrel_mcp_client_egress:check_addresses([{127, 0, 0, 1}], Opts)),
    ?assertEqual(
        ok, barrel_mcp_client_egress:check_addresses([{0, 0, 0, 0, 0, 0, 0, 1}], Opts)
    ),
    ?assertEqual(
        {error, {blocked_address, {192, 168, 0, 1}}},
        barrel_mcp_client_egress:check_addresses([{192, 168, 0, 1}], Opts)
    ).

%%====================================================================
%% Pinning
%%====================================================================

%% A numeric spelling either resolves to the address it names, which is
%% then judged, or does not resolve at all; resolvers differ on which.
%% Neither lets the request through.
refuses_encoded_loopback_hosts_test() ->
    lists:foreach(
        fun(Host) ->
            case barrel_mcp_client_egress:pin(<<"https://", Host/binary, "/x">>, #{}) of
                {error, {blocked_address, {127, 0, 0, 1}}} -> ok;
                {error, {unresolved, Host, _}} -> ok;
                Other -> ?assertEqual(refused, {Host, Other})
            end
        end,
        [<<"0x7f.1">>, <<"2130706433">>, <<"017700000001">>, <<"127.1">>]
    ),
    ?assertEqual(
        {error, {blocked_address, {127, 0, 0, 1}}},
        barrel_mcp_client_egress:pin(<<"https://localhost/x">>, #{})
    ).

ip_literal_is_not_rewritten_test() ->
    ?assertEqual(
        {ok, #{url => <<"https://8.8.8.8/x">>, host => undefined, sni => undefined}},
        barrel_mcp_client_egress:pin(<<"https://8.8.8.8/x">>, #{})
    ),
    ?assertEqual(
        {error, {blocked_address, {0, 0, 0, 0, 0, 0, 0, 1}}},
        barrel_mcp_client_egress:pin(<<"https://[::1]:8443/x">>, #{})
    ).

hostname_is_pinned_to_the_checked_address_test() ->
    ?assertEqual(
        {ok, #{
            url => <<"http://127.0.0.1:8080/x?a=1">>,
            host => <<"localhost:8080">>,
            sni => undefined
        }},
        barrel_mcp_client_egress:pin(
            <<"http://localhost:8080/x?a=1">>, #{allow_insecure_oauth => true}
        )
    ).

unresolvable_host_test() ->
    ?assertMatch(
        {error, {unresolved, <<"no-such-host.invalid">>, _}},
        barrel_mcp_client_egress:pin(<<"https://no-such-host.invalid/x">>, #{})
    ).

%%====================================================================
%% Through the OAuth client
%%====================================================================

%% A server naming the cloud metadata address is refused by name, with
%% no request sent.
refuses_metadata_address_in_discovery_test() ->
    ?assertMatch(
        {error, {refused_url, _, {blocked_address, {169, 254, 169, 254}}}},
        barrel_mcp_client_auth_oauth:discover_protected_resource(
            <<"https://169.254.169.254/.well-known/oauth-protected-resource">>, #{}
        )
    ).

%% A refused URL opens no socket; the same URL with its network allowed
%% does. The pair shows the block sits before the connection.
refused_url_opens_no_connection_test() ->
    {ok, _} = application:ensure_all_started(hackney),
    {ok, Listen} = gen_tcp:listen(0, [binary, {ip, {127, 0, 0, 1}}, {active, false}]),
    {ok, Port} = inet:port(Listen),
    Self = self(),
    Acceptor = spawn_link(fun() -> count_accepts(Listen, Self) end),
    Url = <<"https://127.0.0.1:", (integer_to_binary(Port))/binary, "/.well-known/x">>,
    try
        ?assertMatch(
            {error, {refused_url, Url, {blocked_address, {127, 0, 0, 1}}}},
            barrel_mcp_client_auth_oauth:discover_protected_resource(Url, #{})
        ),
        ?assertEqual(0, accepts(Acceptor)),
        _ = barrel_mcp_client_auth_oauth:discover_protected_resource(Url, #{
            oauth_allowed_networks => [<<"127.0.0.1/32">>]
        }),
        ?assertEqual(1, accepts(Acceptor))
    after
        unlink(Acceptor),
        exit(Acceptor, kill),
        gen_tcp:close(Listen)
    end.

count_accepts(Listen, Owner) ->
    count_accepts(Listen, Owner, 0).

count_accepts(Listen, Owner, N) ->
    case gen_tcp:accept(Listen, 50) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            count_accepts(Listen, Owner, N + 1);
        {error, timeout} ->
            receive
                {count, From} ->
                    From ! {accepts, N},
                    count_accepts(Listen, Owner, N)
            after 0 ->
                count_accepts(Listen, Owner, N)
            end
    end.

accepts(Acceptor) ->
    Acceptor ! {count, self()},
    receive
        {accepts, N} -> N
    after 2000 -> error(no_count)
    end.
