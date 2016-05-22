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

%% Common Test
-compile(export_all).

all() ->
    [{group, esockd}, {group, cidr}, {group, access}].

groups() ->
    [{esockd, [sequence],
      [open_close]},
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
       access_ipv6_match]}].

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

open_close(_) ->
    MFA = {echo_server, start_link, []},
    {ok, _LSup} = esockd:open(echo, {"127.0.0.1", 5000}, [binary, {packet, raw}], MFA),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", 5000, []),
    ok = gen_tcp:send(Sock, <<"Hello">>),
    esockd:close(echo, {"127.0.0.1", 5000}).
 
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

