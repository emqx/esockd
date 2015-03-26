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

-import(esockd_access, [atoi/1, itoa/1, rule/1, range/1, match/2, mask/1]).

atoi_test() ->
    IpList = [{192,168,1,1}, {10,10,10,10}, {8, 8, 8,8}, {255,255,255,0}],
    [?assertEqual(Ip, itoa(atoi(Ip))) || Ip <- IpList].

mask_test() ->
    ?assertEqual(16#FF000000, mask(8)),
    ?assertEqual(16#FFFF0000, mask(16)),
    ?assertEqual(16#FFFFFF00, mask(24)),
    ?assertEqual(16#FFFF8000, mask(17)),
    ?assertEqual(16#FFFFFF80, mask(25)).

range_test() ->
    {Start, End} = range("192.168.1.0/24"),
    ?assertEqual({192,168,1,0}, itoa(Start)),
    ?assertEqual({192,168,1,255}, itoa(End)),
    {Start1, End1} = range("10.10.0.0/16"),
    ?assertEqual({10,10,0,0}, itoa(Start1)),
    ?assertEqual({10,10,255,255}, itoa(End1)).

match_test() ->
    Rules = [rule({deny,  "192.168.1.1"}),
             rule({allow, "192.168.1.0/24"}),
             rule({deny,  all})],
    ?assertEqual({matched, deny}, match({192,168,1,1}, Rules)),
    ?assertEqual({matched, allow}, match({192,168,1,4}, Rules)),
    ?assertEqual({matched, allow}, match({192,168,1,60}, Rules)),
    ?assertEqual({matched, deny}, match({10,10,10,10}, Rules)).

match_local_test() ->
    Rules = [rule({allow, "127.0.0.1"}), rule({deny, all})],
    ?assertEqual({matched, allow}, match({127,0,0,1}, Rules)),
    ?assertEqual({matched, deny}, match({192,168,0,1}, Rules)).

match_allow_test() ->
    Rules = [rule({deny, "10.10.0.0/16"}), rule({allow, all})],
    ?assertEqual({matched, deny}, match({10,10,0,10}, Rules)),
    ?assertEqual({matched, allow}, match({127,0,0,1}, Rules)),
    ?assertEqual({matched, allow}, match({192,168,0,1}, Rules)).

-endif.


