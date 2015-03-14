%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2014-2015, Feng Lee <feng@emqtt.io>
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
%%% esockd access control.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_access).

-type rule() :: {allow, all} |
                {allow, cidr()} |
                {deny,  all} |
                {deny,  cidr()}.

-type cidr() :: {string(), pos_integer(), pos_integer()}.

-export([rule/1, match/2, range/1]).

rule({allow, all}) ->
    {allow, all};
rule({allow, CIDR}) when is_list(CIDR) ->
    rule(allow, CIDR);
rule({deny, CIDR}) when is_list(CIDR) ->
    rule(deny, CIDR);
rule({deny, all}) ->
    {deny, all}.

rule(Type, CIDR) when is_list(CIDR) ->
    {ok, Start, End} = range(CIDR),
    {Type, {CIDR, Start, End}}.

range(CIDR) ->
    case string:tokens(CIDR, "/") of
        [Addr] ->
            {ok, IP} = inet:getaddr(Addr, inet),
            {ok, atoi(IP), atoi(IP)};
        [Addr, Mask] ->
            {ok, IP} = inet:getaddr(Addr, inet),
            subnet(IP, list_to_integer(Mask))
    end.

subnet(IP, Mask) when Mask >= 0, Mask =< 32 ->
    {atoi(IP), atoi(IP)}.

%%------------------------------------------------------------------------------
%% @doc
%% Match IpAddr with access rules.
%%
%% @end
%%------------------------------------------------------------------------------
-spec match(inet:ip_address(), [rule()]) -> {matched, allow} | {matched, deny} | nomatch.
match(_Addr, _Rules) ->
    nomatch.


atoi(S) when is_list(S) ->
    {ok, Addr} = inet:parse_ipv4_address(S),
    atoi(Addr);
atoi({A, B, C, D}) ->
    (A bsl 24) + (B bsl 16) + C bsl 8 + D.
    



