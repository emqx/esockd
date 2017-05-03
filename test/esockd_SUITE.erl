%%--------------------------------------------------------------------
%% Copyright (c) 2016-2017 Feng Lee <feng@emqtt.io>.
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
%%--------------------------------------------------------------------

-module(esockd_SUITE).

-include_lib("eunit/include/eunit.hrl").

-include_lib("common_test/include/ct.hrl").

%% Common Test
-compile(export_all).

all() ->
    [{group, esockd}, {group, cidr}, {group, access}, {group, udp}, {group, proxy_protocol}].

groups() ->
    [{esockd, [sequence],
      [esockd_child_spec,
       esockd_open_close,
       esockd_listeners,
       esockd_get_stats,
       esockd_get_acceptors,
       esockd_getset_max_clients,
       esockd_get_shutdown_count,
       esockd_get_access_rules,
       esockd_fixaddr,
       esockd_to_string
      ]},
     {cidr, [],
      [parse_ipv4_cidr,
       parse_ipv6_cidr,
       cidr_to_string,
       ipv4_address_count,
       ipv6_address_count,
       ipv4_cidr_match,
       ipv6_cidr_match]},
     {access, [],
      [access_match,
       access_match_localhost,
       access_match_allow,
       access_ipv6_match]},
     {udp, [sequence],
      [esockd_udp_server]},
     {proxy_protocol, [sequence],
      [new_connection_tcp4,
       new_connection_tcp6,
       new_connection_v2,
       unknow_data,
       garbage_date,
       reuse_socket
       ]}
    ].

init_per_suite(Config) ->
    application:start(lager),
    application:start(gen_logger),
    esockd:start(),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd).

%%------------------------------------------------------------------------------
%% eSockd
%%------------------------------------------------------------------------------

esockd_child_spec(_) ->
    Spec = esockd:child_spec(echo, 5000, [binary, {packet, raw}], echo_mfa()),
    ?assertEqual({listener_sup, {echo, 5000}}, element(1, Spec)).

esockd_open_close(_) ->
    {ok, _LSup} = esockd:open(echo, {"127.0.0.1", 5000}, [binary, {packet, raw}], echo_mfa()),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", 5000, []),
    ok = gen_tcp:send(Sock, <<"Hello">>),
    esockd:close(echo, {"127.0.0.1", 5000}).

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
    {ok, _LSup} = esockd:open(echo, {{127,0,0,1}, 6000}, [{acceptors, 4}], echo_mfa()),
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
    {ok, _LSup} = esockd:open(echo, 7000, [{access, [{allow, "192.168.1.0/24"}]}], echo_mfa()),
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
 
%%------------------------------------------------------------------------------
%% CIDR
%%------------------------------------------------------------------------------

parse_ipv4_cidr(_) ->
	?assert(esockd_cidr:parse("192.168.0.0") == {{192,168,0,0}, {192,168,0,0}, 32}),
	?assert(esockd_cidr:parse("1.2.3.4") == {{1,2,3,4}, {1,2,3,4}, 32}),
	?assert(esockd_cidr:parse("192.168.0.0/0", true) == {{0,0,0,0}, {255,255,255,255}, 0}),
	?assert(esockd_cidr:parse("192.168.0.0/8", true) == {{192,0,0,0}, {192,255,255,255}, 8}),
	?assert(esockd_cidr:parse("192.168.0.0/15", true) == {{192,168,0,0}, {192,169,255,255}, 15}),
	?assert(esockd_cidr:parse("192.168.0.0/16") == {{192,168,0,0}, {192,168,255,255}, 16}),
	?assert(esockd_cidr:parse("192.168.0.0/17") == {{192,168,0,0}, {192,168,127,255}, 17}),
	?assert(esockd_cidr:parse("192.168.0.0/18") == {{192,168,0,0}, {192,168,63,255}, 18}),
	?assert(esockd_cidr:parse("192.168.0.0/19") == {{192,168,0,0}, {192,168,31,255}, 19}),
	?assert(esockd_cidr:parse("192.168.0.0/20") == {{192,168,0,0}, {192,168,15,255}, 20}),
	?assert(esockd_cidr:parse("192.168.0.0/21") == {{192,168,0,0}, {192,168,7,255}, 21}),
	?assert(esockd_cidr:parse("192.168.0.0/22") == {{192,168,0,0}, {192,168,3,255}, 22}),
	?assert(esockd_cidr:parse("192.168.0.0/23") == {{192,168,0,0}, {192,168,1,255}, 23}),
	?assert(esockd_cidr:parse("192.168.0.0/24") == {{192,168,0,0}, {192,168,0,255}, 24}),
	?assert(esockd_cidr:parse("192.168.0.0/31") == {{192,168,0,0}, {192,168,0,1}, 31}),
	?assert(esockd_cidr:parse("192.168.0.0/32") == {{192,168,0,0}, {192,168,0,0}, 32}).

parse_ipv6_cidr(_) ->
	?assert(esockd_cidr:parse("2001:abcd::/0", true) == {{0, 0, 0, 0, 0, 0, 0, 0}, {65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535}, 0}),
	?assert(esockd_cidr:parse("2001:abcd::/32") == {{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 65535, 65535, 65535, 65535, 65535, 65535}, 32}),
	?assert(esockd_cidr:parse("2001:abcd::/33") == {{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 32767, 65535, 65535, 65535, 65535, 65535}, 33}),
	?assert(esockd_cidr:parse("2001:abcd::/34") == {{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 16383, 65535, 65535, 65535, 65535, 65535}, 34}),
	?assert(esockd_cidr:parse("2001:abcd::/35") == {{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 8191, 65535, 65535, 65535, 65535, 65535}, 35}),
	?assert(esockd_cidr:parse("2001:abcd::/36") == {{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 4095, 65535, 65535, 65535, 65535, 65535}, 36}),
	?assert(esockd_cidr:parse("2001:abcd::/128") == {{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 0, 0, 0, 0, 0, 0}, 128}).

cidr_to_string(_) ->
    ?assertEqual(esockd_cidr:to_string({{192,168,0,0}, {192,168,255,255}, 16}), "192.168.0.0/16"),
	?assertEqual(esockd_cidr:to_string({{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 65535, 65535, 65535, 65535, 65535, 65535}, 32}), "2001:ABCD::/32").

ipv4_address_count(_) ->
	?assert(esockd_cidr:count(esockd_cidr:parse("192.168.0.0/0", true))  == 4294967296),
	?assert(esockd_cidr:count(esockd_cidr:parse("192.168.0.0/16", true)) == 65536),
	?assert(esockd_cidr:count(esockd_cidr:parse("192.168.0.0/17", true)) == 32768),
	?assert(esockd_cidr:count(esockd_cidr:parse("192.168.0.0/24", true)) == 256),
	?assert(esockd_cidr:count(esockd_cidr:parse("192.168.0.0/32", true)) == 1).

ipv6_address_count(_) ->
    ?assert(esockd_cidr:count(esockd_cidr:parse("2001::abcd/0", true)) == math:pow(2, 128)),
	?assert(esockd_cidr:count(esockd_cidr:parse("2001::abcd/64", true)) == math:pow(2, 64)),
	?assert(esockd_cidr:count(esockd_cidr:parse("2001::abcd/128")) == 1).

ipv4_cidr_match(_) ->
    CIDR = esockd_cidr:parse("192.168.0.0/16"),
	?assert(esockd_cidr:match({192,168,0,0}, CIDR) == true),
    ?assert(esockd_cidr:match({192,168,0,1}, CIDR) == true),
    ?assert(esockd_cidr:match({192,168,1,0}, CIDR) == true),
    ?assert(esockd_cidr:match({192,168,0,255}, CIDR) == true),
    ?assert(esockd_cidr:match({192,168,255,0}, CIDR) == true),
    ?assert(esockd_cidr:match({192,168,255,255}, CIDR) == true),
    ?assert(esockd_cidr:match({192,168,255,256}, CIDR) == false),
    ?assert(esockd_cidr:match({192,169,0,0}, CIDR) == false),
    ?assert(esockd_cidr:match({192,167,255,255}, CIDR) == false).

ipv6_cidr_match(_) ->
	CIDR = {{8193, 43981, 0, 0, 0, 0, 0, 0}, {8193, 43981, 8191, 65535, 65535, 65535, 65535, 65535}, 35},
    ?assert(esockd_cidr:match({8193, 43981, 0, 0, 0, 0, 0, 0}, CIDR) == true),
    ?assert(esockd_cidr:match({8193, 43981, 0, 0, 0, 0, 0, 1}, CIDR) == true),
    ?assert(esockd_cidr:match({8193, 43981, 8191, 65535, 65535, 65535, 65535, 65534}, CIDR) == true),
    ?assert(esockd_cidr:match({8193, 43981, 8191, 65535, 65535, 65535, 65535, 65535}, CIDR) == true),
    ?assert(esockd_cidr:match({8193, 43981, 8192, 65535, 65535, 65535, 65535, 65535}, CIDR) == false),
    ?assert(esockd_cidr:match({65535, 65535, 65535, 65535, 65535, 65535, 65535, 65535}, CIDR) == false).

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
    Rules = [esockd_access:compile({allow, "127.0.0.1"}), esockd_access:compile({deny, all})],
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

esockd_udp_server(_) ->
    {ok, Srv} = esockd_udp:server(test, 9876, [], {?MODULE, udp_echo_server, []}),
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    ok = gen_udp:send(Sock, {127,0,0,1}, 9876, <<"hello">>),
    {ok, {_Addr, _Port, <<"hello">>}} = gen_udp:recv(Sock, 5, 3000),
    ok = gen_udp:send(Sock, {127,0,0,1}, 9876, <<"world">>),
    {ok, {_Addr, _Port, <<"world">>}} = gen_udp:recv(Sock, 5, 3000),
    ok = esockd_udp:stop(Srv).

udp_echo_server(Socket, Peer) ->
    {ok, spawn(fun() -> udp_echo_loop(Socket, Peer) end)}.

udp_echo_loop(Socket, {Address, Port} = Peer) ->
    receive
        {datagram, _Server, Packet} ->
            ok = gen_udp:send(Socket, Address, Port, Packet),
            udp_echo_loop(Socket, Peer);
         _Any ->
            ok
    end.

new_connection_tcp4(Config) ->
    {ok, _LSup} = proxy_protocol_server:start(5000),
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Socket, "PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n"),
    ok = gen_tcp:send(Socket, <<"v1 tcp4">>),
    receive
        {tcp, Sock, Data} ->
            "v1 tcp4" = Data
    end,
    Config.

new_connection_tcp6(Config) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Socket, <<"PROXY TCP4 ::1 ::1 6000 50000\r\n">>),
    ok = gen_tcp:send(Socket, <<"v1 tcp6">>),
    receive
        {tcp, Sock, Data} ->
            "v1 tcp6" = Data
    end,
    Config.


new_connection_v2(Config) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, 5000, []),
    Bin = <<13,10,13,10,0,13,10,81,85,73,84,10,33,17,0,12,127,
            50,210,1,210,21,16,142,250,32,1,181>>,
    ok = gen_tcp:send(Socket, Bin),
    ok = gen_tcp:send(Socket, <<"v2">>),
    receive
        {tcp, Sock, Data} ->
            "v2" = Data
    end,
    Config.

unknow_data(Config) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Socket, "PROXY UNKNOWN\r\n"),
    ok = gen_tcp:send(Socket, <<"unknow">>),
    receive
        {tcp, Sock, Data} ->
            ct:log("Data:~p~n", [Data]),
            "unknow" = Data
    end,
    Config.

garbage_date(Config) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Socket, "************\r\n"),
    ok = gen_tcp:send(Socket, <<"garbage_date">>),
    Config.


reuse_socket(Config) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Socket, "PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n"),
    ok = gen_tcp:send(Socket, <<"m1">>),
    receive
        {tcp, _Sock, Data} ->
            "m1" = Data
    end,
    esockd_transport:close(Socket),
    {ok, Socket1} = gen_tcp:connect({127,0,0,1}, 5000, []),
    ok = gen_tcp:send(Socket1, "PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n"),
    ok = gen_tcp:send(Socket1, <<"m2">>),
    receive
        {tcp, _Sock, Data1} ->
            "m2" = Data1
    after 1000 ->
          ct:log("timeout:~p~n", [timeout]),
          ok
    end,
    esockd_transport:close(Socket1),
    Config.
