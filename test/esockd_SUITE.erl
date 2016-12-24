%%--------------------------------------------------------------------
%% Copyright (c) 2016 Feng Lee <feng@emqtt.io>.
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
    [{group, esockd}, {group, cidr}, {group, access}, {group, proxy_protocol_v2}].

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
     {proxy_protocol_v2, [],
      [ ppv2_invalid_proxy_msg,
        ppv2_cmd_local,
        ppv2_cmd_proxy_proto_type_unspec,
        ppv2_cmd_proxy_tcp_over_ipv4,
        ppv2_cmd_proxy_tcp_over_ipv6,
        ppv2_cmd_proxy_additional_tlvs,
        ppv2_cmd_unsupported]}
      ].

init_per_suite(Config) ->
    application:start(sasl),
    application:start(lager),
    application:start(gen_logger),
    esockd:start(),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd).

init_per_group(proxy_protocol_v2, Config) ->
    [ {ipaddr, "127.0.0.1"}, {port, 9002}
      | Config].

end_per_group(proxy_protocol_v2, _Config) ->
    ok.

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
%% proxy protocol
%%--------------------------------------------------------------------

%% If an invalid Proxy-Protocol-Msg is Given
%% Then the the connection will be rejected by the proxy server.
ppv2_invalid_proxy_msg(Config) ->
  {ok, _LSup} = proxy_protocol_server:start(?config(port, Config), v2),
  {ok, Sock} = gen_tcp:connect(?config(ipaddr, Config), ?config(port, Config), []),

  InvalidProxyProtoMsg = <<"Incorrect Format Msg">>,
  ok = gen_tcp:send(Sock, InvalidProxyProtoMsg),
  receive
    {tcp_closed, Sock} ->
      ok;
    Msg ->
      throw({wrong_msg, Msg})
  after
    3000 ->
      throw({timeout, 3000})
  end,
  esockd:close(echo, ?config(port, Config)).

%% CMD == LOCAL
ppv2_cmd_local(Config) ->
  {ok, _LSup} = pp_server:start(?config(port, Config), v2),
  {ok, Sock} = gen_tcp:connect(?config(ipaddr, Config), ?config(port, Config), []),
  Prefix = <<16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A>>,
  ProxyProtoMsg = <<Prefix:12/binary, 16#2:4, 16#0:4, 16#0:4, 16#0:4, 0:16>>,
  ok = gen_tcp:send(Sock, ProxyProtoMsg),
  ok = gen_tcp:send(Sock, <<"Hello?">>),
  receive
    {tcp,Sock, "Hello?"} ->
      ok;
    Msg ->
      throw({wrong_msg, Msg})
  after
    3000 ->
      throw({timeout, 3000})
  end,
  esockd:close(echo, ?config(port, Config)).

%% CMD == PROXY, proto type unspecified
ppv2_cmd_proxy_proto_type_unspec(Config) ->
  {ok, _LSup} = pp_server:start(?config(port, Config), v2),
  {ok, Sock} = gen_tcp:connect(?config(ipaddr, Config), ?config(port, Config), []),
  Prefix = <<16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A>>,
  ProxyProtoMsg = <<Prefix:12/binary, 16#2:4, 16#1:4, 16#0:4, 16#0:4, 0:16>>,
  ok = gen_tcp:send(Sock, ProxyProtoMsg),
  ok = gen_tcp:send(Sock, <<"Hello?">>),
  receive
    {tcp,Sock, "Hello?"} ->
      ok;
    Msg ->
      throw({wrong_msg, Msg})
  after
    3000 ->
      throw({timeout, 3000})
  end,
  esockd:close(echo, ?config(port, Config)).

%% CMD == PROXY, TCP over IPv4
ppv2_cmd_proxy_tcp_over_ipv4(Config) ->
  {ok, _LSup} = pp_server:start(?config(port, Config), v2),
  {ok, Sock} = gen_tcp:connect(?config(ipaddr, Config), ?config(port, Config), []),
  Prefix = <<16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A>>,
  ProxyProtoMsg = <<Prefix:12/binary, 16#2:4, 16#1:4, 16#1:4, 16#1:4, 12:16, 2130706434:32, 2130706435:32, 6500:16, 6501:16>>,
  ok = gen_tcp:send(Sock, ProxyProtoMsg),
  ok = gen_tcp:send(Sock, <<"Hello?">>),
  receive
    {tcp,Sock, "Hello?"} ->
      ok;
    Msg ->
      throw({wrong_msg, Msg})
  after
    3000 ->
      throw({timeout, 3000})
  end,
  esockd:close(echo, ?config(port, Config)).

%% CMD == PROXY, TCP over IPv6
ppv2_cmd_proxy_tcp_over_ipv6(Config) ->
  {ok, _LSup} = pp_server:start(?config(port, Config), v2),
  {ok, Sock} = gen_tcp:connect(?config(ipaddr, Config), ?config(port, Config), []),
  Prefix = <<16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A>>,
  ProxyProtoMsg = <<Prefix:12/binary, 16#2:4, 16#1:4, 16#2:4, 16#1:4, 36:16, 1:128, 2:128, 6502:16, 6503:16>>,
  ok = gen_tcp:send(Sock, ProxyProtoMsg),
  ok = gen_tcp:send(Sock, <<"Hello?">>),
  receive
    {tcp,Sock, "Hello?"} ->
      ok;
    Msg ->
      throw({wrong_msg, Msg})
  after
    3000 ->
      throw({timeout, 3000})
  end,
  esockd:close(echo, ?config(port, Config)).

%% CMD == PROXY, TCP over IPv4 with additional TLVs at the end of the packet
%% These TLVs will be disregarded by the receiver, as it doesn't support this feature.
ppv2_cmd_proxy_additional_tlvs(Config) ->
  {ok, _LSup} = pp_server:start(?config(port, Config), v2),
  {ok, Sock} = gen_tcp:connect(?config(ipaddr, Config), ?config(port, Config), []),
  Prefix = <<16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A>>,
  Type = 3,
  Length = 39,
  ProxyProtoMsg = <<Prefix:12/binary, 16#2:4, 16#1:4, 16#1:4, 16#1:4, 12:16, 2130706434:32, 2130706435:32,
    6500:16, 6501:16, Type:8, Length:16, "I am the value at the end of the packet">>,
  ok = gen_tcp:send(Sock, ProxyProtoMsg),
  ok = gen_tcp:send(Sock, <<"Hello?">>),
  receive
    {tcp,Sock, [3,0,39,73,32,97,109,32,116,104,101,32,118,97,
      108,117,101,32,97,116,32,116,104,101,32,101,110,
      100,32,111,102,32,116,104,101,32,112,97,99,107,
      101,116,72,101,108,108,111,63]} -> %% All the TLVs are disregards by the proxy server.
      ok;
    Msg ->
      throw({wrong_msg, Msg})
  after
    3000 ->
      throw({timeout, 3000})
  end,
  esockd:close(echo, ?config(port, Config)).

%% Unsupported CMD, will be rejected by proxy server
ppv2_cmd_unsupported(Config) ->
  {ok, _LSup} = pp_server:start(?config(port, Config), v2),
  {ok, Sock} = gen_tcp:connect(?config(ipaddr, Config), ?config(port, Config), []),
  Prefix = <<16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A>>,
  UnsupportedCMD = 3,
  ProxyProtoMsg = <<Prefix:12/binary, 16#2:4, UnsupportedCMD:4, 16#0:4, 16#0:4, 0:16>>,
  ok = gen_tcp:send(Sock, ProxyProtoMsg),
  receive
    {tcp_closed, Sock} ->
      ok;
    Msg ->
      throw({wrong_msg, Msg})
  after
    3000 ->
      throw({timeout, 3000})
  end,
  esockd:close(echo, ?config(port, Config)).

