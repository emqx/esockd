%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2016 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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
%%% eSockd Access Control.
%%%
%%% CIDR: Classless Inter-Domain Routing
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_access).

-author("Feng Lee <feng@emqtt.io>").

-type(cidr_string() :: string()).

-type(raw_rule()  :: {allow, all}
                   | {allow, cidr_string()}
                   | {deny,  all}
                   | {deny,  cidr_string()}).

-type(cidr_rule() :: {allow, all}
                   | {allow, esockd_cidr:cidr()}
                   | {deny,  all}
                   | {deny,  esockd_cidr:cidr()}).

-export_type([raw_rule/0, cidr_rule/0]).

-export([compile/1, match/2]).

%%------------------------------------------------------------------------------
%% @doc Build CIDR, Compile Rule.
%% @end
%%------------------------------------------------------------------------------
-spec(compile(raw_rule()) -> cidr_rule()).
compile({allow, all}) ->
    {allow, all};
compile({allow, CIDR}) when is_list(CIDR) ->
    compile(allow, CIDR);
compile({deny, CIDR}) when is_list(CIDR) ->
    compile(deny, CIDR);
compile({deny, all}) ->
    {deny, all}.
compile(Type, CIDR) when is_list(CIDR) ->
    {Type, esockd_cidr:parse(CIDR)}.

%%------------------------------------------------------------------------------
%% @doc Match Addr with Access Rules.
%% @end
%%------------------------------------------------------------------------------
-spec(match(inet:ip_address(), [cidr_rule()]) -> {matched, allow} | {matched, deny} | nomatch).
match(Addr, Rules) when is_tuple(Addr) ->
    match2(Addr, Rules).

match2(_Addr, []) ->
    nomatch;
match2(_Addr, [{allow, all} | _]) ->
    {matched, allow};
match2(_Addr, [{deny, all} | _]) ->
    {matched, deny};
match2(Addr, [{Access, CIDR = {_StartAddr, _EndAddr, _Len}}|Rules])
        when Access == allow orelse Access == deny->
    case esockd_cidr:match(Addr, CIDR) of
        true  -> {matched, Access};
        false -> match2(Addr, Rules)
    end.

