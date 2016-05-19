%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% esockd_access tests.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_access_tests).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-import(esockd_access, [compile/1, match/2]).

match_test() ->
    Rules = [compile({deny,  "192.168.1.1"}),
             compile({allow, "192.168.1.0/24"}),
             compile({deny,  all})],
    ?assertEqual({matched, deny}, match({192,168,1,1}, Rules)),
    ?assertEqual({matched, allow}, match({192,168,1,4}, Rules)),
    ?assertEqual({matched, allow}, match({192,168,1,60}, Rules)),
    ?assertEqual({matched, deny}, match({10,10,10,10}, Rules)).

match_local_test() ->
    Rules = [compile({allow, "127.0.0.1"}), compile({deny, all})],
    ?assertEqual({matched, allow}, match({127,0,0,1}, Rules)),
    ?assertEqual({matched, deny}, match({192,168,0,1}, Rules)).

match_allow_test() ->
    Rules = [compile({deny, "10.10.0.0/16"}), compile({allow, all})],
    ?assertEqual({matched, deny}, match({10,10,0,10}, Rules)),
    ?assertEqual({matched, allow}, match({127,0,0,1}, Rules)),
    ?assertEqual({matched, allow}, match({192,168,0,1}, Rules)).

ipv6_match_test() ->
    Rules = [compile({deny, "2001:abcd::/64"}), compile({allow, all})],
    {ok, Addr1} = inet:parse_address("2001:abcd::10"),
    {ok, Addr2} = inet:parse_address("2001::10"),
    ?assertEqual({matched, deny}, match(Addr1, Rules)),
    ?assertEqual({matched, allow}, match(Addr2, Rules)).

-endif.

