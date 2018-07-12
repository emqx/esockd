%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(esockd_SUITE).

-include("esockd.hrl").

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-compile(export_all).
-compile(nowarn_export_all).

all() ->
    [{group, esockd},
     {group, cidr},
     {group, access},
     {group, udp},
     {group, dtls},
     {group, proxy_protocol}].

groups() ->
    [{esockd, [sequence],
      [esockd_child_spec,
       esockd_open_close,
       esockd_reopen,
       esockd_reopen1,
       esockd_reopen_fail,
       esockd_listeners,
       esockd_get_stats,
       esockd_get_acceptors,
       esockd_getset_max_clients,
       esockd_get_shutdown_count,
       esockd_get_access_rules,
       esockd_fixaddr,
       esockd_to_string]},
     {cidr, [parallel],
      [parse_ipv4_cidr,
       parse_ipv6_cidr,
       cidr_to_string,
       ipv4_address_count,
       ipv6_address_count,
       ipv4_cidr_match,
       ipv6_cidr_match]},
     {access, [parallel],
      [access_match,
       access_match_localhost,
       access_match_allow,
       access_ipv6_match]},
     {udp, [sequence],
      [udp_server]},
     {dtls, [sequence],
      [dtls_server]},
     {proxy_protocol, [sequence],
      [parse_proxy_info_v1,
       parse_proxy_info_v2,
       parse_proxy_pp2_tlv,
       parse_proxy_info_v2_additional_info,
       new_connection_tcp4,
       new_connection_tcp6,
       new_connection_v2,
       unknow_data,
       garbage_date,
       reuse_socket]}
    ].

init_per_suite(Config) ->
    ok = esockd:start(),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd).

%%--------------------------------------------------------------------
%% esockd
%%--------------------------------------------------------------------

esockd_child_spec(_) ->
    Spec = esockd:child_spec(echo, 5000, [binary, {packet, raw}], echo_mfa()),
    ?assertEqual({listener_sup, {echo, 5000}}, element(1, Spec)).

esockd_open_close(_) ->
    {ok, _LSup} = esockd:open(echo, {"127.0.0.1", 3000},
                              [binary, {packet, raw}], echo_mfa()),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", 3000, []),
    ok = gen_tcp:send(Sock, <<"Hello">>),
    ok = esockd:close(echo, {"127.0.0.1", 3000}).

esockd_reopen(_) ->
    {ok, _LSup} = esockd:open(echo, {"127.0.0.1", 3000},
                              [binary, {packet, raw}], echo_mfa()),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", 3000, []),
    ok = gen_tcp:send(Sock, <<"Hello">>),
    timer:sleep(10),
    {ok, _RSup} = esockd:reopen({echo, {"127.0.0.1", 3000}}),
    {ok, ReopnSock} = gen_tcp:connect("127.0.0.1", 3000, []),
    ok = gen_tcp:send(ReopnSock, <<"Hello1">>),
    timer:sleep(10),
    esockd:close(echo, {"127.0.0.1", 3000}).

esockd_reopen1(_) ->
    {ok, _LSup} = esockd:open(echo, 7000, [{max_clients, 4},
                                           {acceptors, 4}], echo_mfa()),
    timer:sleep(10),
    {ok, _ReopnLSup} = esockd:reopen({echo, 7000}),
    ?assertEqual(4, esockd:get_max_clients({echo, 7000})),
    ?assertEqual(4, esockd:get_acceptors({echo, 7000})),
    esockd:close(echo, 7000).

esockd_reopen_fail(_) ->
    {ok, _LSup} = esockd:open(echo, {"127.0.0.1", 4000},
                              [{acceptors, 4}], echo_mfa()),
    {error, _Reson} = esockd:reopen({echo, 4000}),
    ?assertEqual(4, esockd:get_acceptors({echo, {"127.0.0.1", 4000}})),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", 4000, []),
    ok = gen_tcp:send(Sock, <<"Hello">>),
    timer:sleep(10),
    esockd:close(echo, {"127.0.0.1", 4000}).

esockd_listeners(_) ->
    {ok, LSup} = esockd:open(echo, 6000, [], echo_mfa()),
    [{{echo, 6000}, LSup}] = esockd:listeners(),
    ?assertEqual(LSup, esockd:listener({echo, 6000})),
    esockd:close(echo, 6000),
    [] = esockd:listeners(),
    ?assertEqual(undefined, esockd:listener({echo, 6000})).

esockd_get_stats(_) ->
    {ok, _LSup} = esockd:open(echo, 6000, [], echo_mfa()),
    {ok, Sock1} = gen_tcp:connect("127.0.0.1", 6000, []),
    {ok, Sock2} = gen_tcp:connect("127.0.0.1", 6000, []),
    timer:sleep(10),
    [{accepted, 2}] = esockd:get_stats({echo, 6000}),
    gen_tcp:close(Sock1),
    gen_tcp:close(Sock2),
    esockd:close(echo, 6000).

esockd_get_acceptors(_) ->
    {ok, _LSup} = esockd:open(echo, {{127,0,0,1}, 6000},
                              [{acceptors, 4}], echo_mfa()),
    ?assertEqual(4, esockd:get_acceptors({echo, {{127,0,0,1}, 6000}})),
    esockd:close(echo, 6000).

esockd_getset_max_clients(_) ->
    {ok, _LSup} = esockd:open(echo, 7000, [{max_clients, 4}], echo_mfa()),
    ?assertEqual(4, esockd:get_max_clients({echo, 7000})),
    esockd:set_max_clients({echo, 7000}, 16),
    ?assertEqual(16, esockd:get_max_clients({echo, 7000})),
    esockd:close(echo, 7000).

esockd_get_shutdown_count(_) ->
    {ok, _LSup} = esockd:open(echo, 7000, [], echo_mfa()),
    {ok, Sock1} = gen_tcp:connect("127.0.0.1", 7000, []),
    {ok, Sock2} = gen_tcp:connect("127.0.0.1", 7000, []),
    gen_tcp:close(Sock1),
    gen_tcp:close(Sock2),
    timer:sleep(10),
    ?assertEqual([{closed, 2}], esockd:get_shutdown_count({echo, 7000})),
    esockd:close(echo, 7000).

esockd_get_access_rules(_) ->
    AccessRules = [{allow, "192.168.1.0/24"}],
    {ok, _LSup} = esockd:open(echo, 7000, [{access_rules, AccessRules}], echo_mfa()),
    ?assertEqual([{allow, "192.168.1.0/24"}], esockd:get_access_rules({echo, 7000})),
    ok = esockd:allow({echo, 7000}, "10.10.0.0/16"),
    ?assertEqual([{allow, "10.10.0.0/16"},
                  {allow, "192.168.1.0/24"}],
                 esockd:get_access_rules({echo, 7000})),
    ok = esockd:deny({echo, 7000}, "172.16.1.1/16"),
    ?assertEqual([{deny,  "172.16.0.0/16"},
                  {allow, "10.10.0.0/16"},
                  {allow, "192.168.1.0/24"}],
                 esockd:get_access_rules({echo, 7000})),
    esockd:close(echo, 7000).

esockd_fixaddr(_) ->
    ?assertEqual({{127,0,0,1}, 9000}, esockd:fixaddr({"127.0.0.1", 9000})),
    ?assertEqual({{10,10,10,10}, 9000}, esockd:fixaddr({{10,10,10,10}, 9000})),
    ?assertEqual({{0,0,0,0,0,0,0,1}, 9000}, esockd:fixaddr({"::1", 9000})).

esockd_to_string(_) ->
    ?assertEqual("9000", esockd:to_string(9000)),
    ?assertEqual("127.0.0.1:9000", esockd:to_string({"127.0.0.1", 9000})),
    ?assertEqual("192.168.1.10:9000", esockd:to_string({{192,168,1,10}, 9000})),
    ?assertEqual("::1:9000", esockd:to_string({{0,0,0,0,0,0,0,1}, 9000})).

echo_mfa() -> {echo_server, start_link, []}.
pp_mfa() -> {pp_server, start_link, []}.

%%--------------------------------------------------------------------
%% CIDR
%%--------------------------------------------------------------------

parse_ipv4_cidr(_) ->
	?assertEqual({{192,168,0,0}, {192,168,0,0}, 32}, esockd_cidr:parse("192.168.0.0")),
	?assertEqual({{1,2,3,4}, {1,2,3,4}, 32}, esockd_cidr:parse("1.2.3.4")),
	?assertEqual({{0,0,0,0}, {255,255,255,255}, 0}, esockd_cidr:parse("192.168.0.0/0", true)),
	?assertEqual({{192,0,0,0}, {192,255,255,255}, 8}, esockd_cidr:parse("192.168.0.0/8", true)),
	?assertEqual({{192,168,0,0}, {192,169,255,255}, 15}, esockd_cidr:parse("192.168.0.0/15", true)),
	?assertEqual({{192,168,0,0}, {192,168,255,255}, 16}, esockd_cidr:parse("192.168.0.0/16")),
	?assertEqual({{192,168,0,0}, {192,168,127,255}, 17}, esockd_cidr:parse("192.168.0.0/17")),
	?assertEqual({{192,168,0,0}, {192,168,63,255}, 18}, esockd_cidr:parse("192.168.0.0/18")),
	?assertEqual({{192,168,0,0}, {192,168,31,255}, 19}, esockd_cidr:parse("192.168.0.0/19")),
	?assertEqual({{192,168,0,0}, {192,168,15,255}, 20}, esockd_cidr:parse("192.168.0.0/20")),
	?assertEqual({{192,168,0,0}, {192,168,7,255}, 21}, esockd_cidr:parse("192.168.0.0/21")),
	?assertEqual({{192,168,0,0}, {192,168,3,255}, 22}, esockd_cidr:parse("192.168.0.0/22")),
	?assertEqual({{192,168,0,0}, {192,168,1,255}, 23}, esockd_cidr:parse("192.168.0.0/23")),
	?assertEqual({{192,168,0,0}, {192,168,0,255}, 24}, esockd_cidr:parse("192.168.0.0/24")),
	?assertEqual({{192,168,0,0}, {192,168,0,1}, 31}, esockd_cidr:parse("192.168.0.0/31")),
	?assertEqual({{192,168,0,0}, {192,168,0,0}, 32}, esockd_cidr:parse("192.168.0.0/32")).

parse_ipv6_cidr(_) ->
	?assertEqual({{0, 0, 0, 0, 0, 0, 0, 0}, {65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535}, 0},
                esockd_cidr:parse("2001:abcd::/0", true)),
	?assertEqual({{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 65535, 65535, 65535, 65535, 65535, 65535}, 32},
                esockd_cidr:parse("2001:abcd::/32")),
	?assertEqual({{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 32767, 65535, 65535, 65535, 65535, 65535}, 33},
                esockd_cidr:parse("2001:abcd::/33")),
	?assertEqual({{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 16383, 65535, 65535, 65535, 65535, 65535}, 34},
                 esockd_cidr:parse("2001:abcd::/34")),
	?assertEqual({{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 8191, 65535, 65535, 65535, 65535, 65535}, 35},
                esockd_cidr:parse("2001:abcd::/35")),
	?assertEqual({{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 4095, 65535, 65535, 65535, 65535, 65535}, 36},
                esockd_cidr:parse("2001:abcd::/36")),
	?assertEqual({{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 0, 0, 0, 0, 0, 0}, 128},
                esockd_cidr:parse("2001:abcd::/128")).

cidr_to_string(_) ->
    ?assertEqual("192.168.0.0/16", esockd_cidr:to_string({{192,168,0,0}, {192,168,255,255}, 16})),
	?assertEqual("2001:abcd::/32", esockd_cidr:to_string({{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 65535, 65535, 65535, 65535, 65535, 65535}, 32})).

ipv4_address_count(_) ->
	?assertEqual(4294967296, esockd_cidr:count(esockd_cidr:parse("192.168.0.0/0", true))),
	?assertEqual(65536, esockd_cidr:count(esockd_cidr:parse("192.168.0.0/16", true))),
	?assertEqual(32768, esockd_cidr:count(esockd_cidr:parse("192.168.0.0/17", true))),
	?assertEqual(256, esockd_cidr:count(esockd_cidr:parse("192.168.0.0/24", true))),
	?assertEqual(1, esockd_cidr:count(esockd_cidr:parse("192.168.0.0/32", true))).

ipv6_address_count(_) ->
    ?assert(esockd_cidr:count(esockd_cidr:parse("2001::abcd/0", true)) == math:pow(2, 128)),
	?assert(esockd_cidr:count(esockd_cidr:parse("2001::abcd/64", true)) == math:pow(2, 64)),
	?assert(esockd_cidr:count(esockd_cidr:parse("2001::abcd/128")) == 1).

ipv4_cidr_match(_) ->
    CIDR = esockd_cidr:parse("192.168.0.0/16"),
	?assert(esockd_cidr:match({192,168,0,0}, CIDR)),
    ?assert(esockd_cidr:match({192,168,0,1}, CIDR)),
    ?assert(esockd_cidr:match({192,168,1,0}, CIDR)),
    ?assert(esockd_cidr:match({192,168,0,255}, CIDR)),
    ?assert(esockd_cidr:match({192,168,255,0}, CIDR)),
    ?assert(esockd_cidr:match({192,168,255,255}, CIDR)),
    ?assertNot(esockd_cidr:match({192,168,255,256}, CIDR)),
    ?assertNot(esockd_cidr:match({192,169,0,0}, CIDR)),
    ?assertNot(esockd_cidr:match({192,167,255,255}, CIDR)).

ipv6_cidr_match(_) ->
	CIDR = {{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 8191, 65535, 65535, 65535, 65535, 65535}, 35},
    ?assert(esockd_cidr:match({8193, 43981, 0, 0, 0, 0, 0, 0}, CIDR)),
    ?assert(esockd_cidr:match({8193, 43981, 0, 0, 0, 0, 0, 1}, CIDR)),
    ?assert(esockd_cidr:match({8193, 43981, 8191, 65535, 65535, 65535, 65535, 65534}, CIDR)),
    ?assert(esockd_cidr:match({8193, 43981, 8191, 65535, 65535, 65535, 65535, 65535}, CIDR)),
    ?assertNot(esockd_cidr:match({8193, 43981, 8192, 65535, 65535, 65535, 65535, 65535}, CIDR)),
    ?assertNot(esockd_cidr:match({65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535}, CIDR)).

%%--------------------------------------------------------------------
%% Access
%%--------------------------------------------------------------------

access_match(_) ->
    Rules = [esockd_access:compile({deny,  "192.168.1.1"}),
             esockd_access:compile({allow, "192.168.1.0/24"}),
             esockd_access:compile({deny,  all})],
    ?assertEqual({matched, deny}, esockd_access:match({192,168,1,1}, Rules)),
    ?assertEqual({matched, allow}, esockd_access:match({192,168,1,4}, Rules)),
    ?assertEqual({matched, allow}, esockd_access:match({192,168,1,60}, Rules)),
    ?assertEqual({matched, deny}, esockd_access:match({10,10,10,10}, Rules)).

access_match_localhost(_) ->
    Rules = [esockd_access:compile({allow, "127.0.0.1"}),
             esockd_access:compile({deny, all})],
    ?assertEqual({matched, allow}, esockd_access:match({127,0,0,1}, Rules)),
    ?assertEqual({matched, deny}, esockd_access:match({192,168,0,1}, Rules)).

access_match_allow(_) ->
    Rules = [esockd_access:compile({deny, "10.10.0.0/16"}),
             esockd_access:compile({allow, all})],
    ?assertEqual({matched, deny}, esockd_access:match({10,10,0,10}, Rules)),
    ?assertEqual({matched, allow}, esockd_access:match({127,0,0,1}, Rules)),
    ?assertEqual({matched, allow}, esockd_access:match({192,168,0,1}, Rules)).

access_ipv6_match(_) ->
    Rules = [esockd_access:compile({deny, "2001:abcd::/64"}),
             esockd_access:compile({allow, all})],
    {ok, Addr1} = inet:parse_address("2001:abcd::10"),
    {ok, Addr2} = inet:parse_address("2001::10"),
    ?assertEqual({matched, deny}, esockd_access:match(Addr1, Rules)),
    ?assertEqual({matched, allow}, esockd_access:match(Addr2, Rules)).

%%--------------------------------------------------------------------
%% UDP Server
%%--------------------------------------------------------------------

udp_server(_) ->
    {ok, Srv} = esockd_udp:server(test, 9876, [], {?MODULE, udp_echo_init, []}),
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    ok = gen_udp:send(Sock, {127,0,0,1}, 9876, <<"hello">>),
    {ok, {_Addr, _Port, <<"hello">>}} = gen_udp:recv(Sock, 5, 3000),
    ok = gen_udp:send(Sock, {127,0,0,1}, 9876, <<"world">>),
    {ok, {_Addr, _Port, <<"world">>}} = gen_udp:recv(Sock, 5, 3000),
    ok = esockd_udp:stop(Srv).

udp_echo_init(Transport, Peer) ->
    {ok, spawn(fun() -> udp_echo_loop(Transport, Peer) end)}.

udp_echo_loop(Transport, Peer) ->
    receive
        {datagram, {udp, From, Sock}, Packet} ->
            From ! {datagram, Peer, Packet},
            udp_echo_loop(Transport, Peer)
    end.

%%--------------------------------------------------------------------
%% DTLS Server
%%--------------------------------------------------------------------

dtls_server(Config) ->
    DataDir = proplists:get_value(data_dir, Config),
    Opts = [{acceptors, 4}, {max_clients, 1000},
            {dtls_options, [{mode, binary}, {reuseaddr, true},
                            {certfile, filename:join([DataDir, "demo.crt"])},
                            {keyfile, filename:join([DataDir, "demo.key"])}]}],
    {ok, _} = esockd:open_dtls('echo/dtls', 9876, Opts, {?MODULE, dtls_echo_init, []}),
    {ok, Sock} = ssl:connect({127,0,0,1}, 9876, [binary, {protocol, dtls}, {active, false}], 5000),
    ok = ssl:send(Sock, <<"hello">>),
    ?assertEqual({ok, <<"hello">>}, ssl:recv(Sock, 5, 3000)),
    ok = ssl:send(Sock, <<"world">>),
    ?assertEqual({ok, <<"world">>}, ssl:recv(Sock, 5, 3000)),
    ok = esockd:close('echo/dtls', 9876).

dtls_echo_init(Transport, Peer) ->
    {ok, spawn_link(?MODULE, dtls_echo_loop, [Transport, Peer])}.

dtls_echo_loop(Transport, Peer) ->
    receive
        {datagram, {dtls, From, _Sock} = Transport, Packet} ->
            io:format("~s - ~p~n", [esockd_net:format(peername, Peer), Packet]),
            From ! {datagram, Peer, Packet},
            dtls_echo_loop(Transport, Peer)
    end.

parse_proxy_info_v1(_Config) ->
    ?assertEqual({ok, #proxy_socket{src_addr = {192,168,1,30}, src_port = 45420,
                                    dst_addr = {192,168,1,2}, dst_port = 1883}},
                 esockd_proxy_protocol:parse_v1(<<"192.168.1.30 192.168.1.2 45420 1883\r\n">>,
                                                #proxy_socket{})),
    ?assertEqual({ok, #proxy_socket{src_addr = {255,255,255,255}, src_port = 65535,
                                    dst_addr = {255,255,255,255}, dst_port = 65535}},
                 esockd_proxy_protocol:parse_v1(<<"255.255.255.255 255.255.255.255 65535 65535\r\n">>,
                                                #proxy_socket{})).

parse_proxy_info_v2(_Config) ->
    ?assertEqual({ok, #proxy_socket{src_addr = {104,199,189,98}, src_port = 6000,
                                    dst_addr = {106,185,34,253}, dst_port = 8883,
                                    inet = inet4}},
                 esockd_proxy_protocol:parse_v2(16#1, 16#1, <<104,199,189,98,106,185,34,253,6000:16,8883:16>>,
                                             #proxy_socket{inet = inet4})),
    ?assertEqual({ok, #proxy_socket{src_addr = {0,0,0,0,0,0,0,1}, src_port = 6000,
                                    dst_addr = {0,0,0,0,0,0,0,1}, dst_port = 5000,
                                    inet = inet6}},
                 esockd_proxy_protocol:parse_v2(16#1, 16#1, <<1:128, 1:128, 6000:16, 5000:16>>,
                                                #proxy_socket{inet = inet6})).

parse_proxy_pp2_tlv(_Config) ->
    Bin = <<01,00,05,"29zka",02,00,06,"219a3k",16#30,00,07,"abc.com",16#20,00,05,03,00,00,00,01>>,
    ?assertEqual([{1, <<"29zka">>}, {2, <<"219a3k">>}, {16#30, <<"abc.com">>}, {16#20, <<3,0,0,0,1>>}],
                 esockd_proxy_protocol:parse_pp2_tlv(fun(E) -> E end, Bin)).

parse_proxy_info_v2_additional_info(_Config) ->
    AdditionalInfo = [{pp2_alpn, <<"29zka">>},
                      {pp2_authority, <<"219a3k">>},
                      {pp2_netns, <<"abc.com">>},
                      {pp2_ssl,
                       [{pp2_ssl_client, true},
                        {pp2_ssl_client_cert_conn, true},
                        {pp2_ssl_client_cert_sess, true},
                        {pp2_ssl_verify, success}]
                      }],
    ?assertEqual({ok, #proxy_socket{src_addr = {104,199,189,98}, src_port = 6000,
                                    dst_addr = {106,185,34,253}, dst_port = 8883,
                                    inet = inet4, pp2_additional_info = AdditionalInfo}},
                 esockd_proxy_protocol:parse_v2(16#1, 16#1, <<104,199,189,98,106,185,34,253,6000:16,8883:16,
                                                              01,00,05,"29zka",02,00,06,"219a3k",16#30,00,07,"abc.com",
                                                              16#20,00,05,07,00,00,00,00>>,
                                                #proxy_socket{inet = inet4})).

new_connection_tcp4(_) ->
    {ok, _LSup} = proxy_protocol_server:start(5000),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Sock, "PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n"),
    ok = gen_tcp:send(Sock, <<"v1 tcp4">>),
    receive {tcp, Sock, Data} -> ?assertEqual("v1 tcp4", Data) end.

new_connection_tcp6(_) ->
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Sock, <<"PROXY TCP4 ::1 ::1 6000 50000\r\n">>),
    ok = gen_tcp:send(Sock, <<"v1 tcp6">>),
    receive {tcp, Sock, Data} -> ?assertEqual("v1 tcp6", Data) end.

new_connection_v2(_) ->
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 5000, []),
    Bin = <<13,10,13,10,0,13,10,81,85,73,84,10,33,17,0,12,127,
            50,210,1,210,21,16,142,250,32,1,181>>,
    ok = gen_tcp:send(Sock, Bin),
    ok = gen_tcp:send(Sock, <<"v2">>),
    receive {tcp, Sock, Data} -> ?assertEqual("v2", Data) end.

unknow_data(_) ->
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Sock, "PROXY UNKNOWN\r\n"),
    ok = gen_tcp:send(Sock, <<"unknown">>),
    receive {tcp, Sock, Data} -> ?assertEqual("unknown", Data) end.

garbage_date(_) ->
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Sock, "************\r\n"),
    ok = gen_tcp:send(Sock, <<"garbage_date">>).

reuse_socket(_) ->
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Sock, "PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n"),
    ok = gen_tcp:send(Sock, <<"m1">>),
    receive {tcp, _Sock1, Data} -> ?assertEqual("m1", Data) end,
    esockd_transport:close(Sock),
    {ok, Sock1} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Sock1, "PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n"),
    ok = gen_tcp:send(Sock1, <<"m2">>),
    receive
        {tcp, _Sock2, Data1} ->
            ?assertEqual("m2", Data1)
    after 1000 ->
          ok
    end,
    esockd_transport:close(Sock1).

