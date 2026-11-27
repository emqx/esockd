%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc A test mock of the peer host part of `emqx_banned' in EMQX.
%%
%% It keeps the same record, the same `who' keys (`{peerhost, IP}' and
%% `{peerhost_net, CIDR}'), the same `until' check, and the same
%% `check/1' on a client info map, in an ETS table instead of mnesia.
%% `ip_check/1' is the `ip_check' listener callback built on top of it.
-module(esockd_banned_mock).

-export([init/0, create/1, ban/1, delete/1, check/1]).

%% ip_check callbacks
-export([ip_check/1, crash/1, bad_return/1]).

-record(banned, {
    who :: {peerhost, inet:ip_address()} | {peerhost_net, esockd_cidr:cidr()},
    by :: binary(),
    reason :: binary(),
    at :: integer(),
    until :: integer() | infinity
}).

-define(TAB, ?MODULE).

%% @doc Create the table, or empty it. The calling process owns it.
init() ->
    case ets:info(?TAB, name) of
        undefined ->
            _ = ets:new(?TAB, [named_table, public, set,
                               {keypos, #banned.who},
                               {read_concurrency, true}]),
            ok;
        _ ->
            true = ets:delete_all_objects(?TAB),
            ok
    end.

create(#banned{} = Banned) ->
    true = ets:insert(?TAB, Banned),
    ok.

%% @doc Ban `Who' with no expiry. A CIDR string is parsed as EMQX does.
ban({peerhost_net, CIDR}) when is_list(CIDR) ->
    ban({peerhost_net, esockd_cidr:parse(CIDR, true)});
ban(Who) ->
    Now = erlang:system_time(second),
    create(#banned{who = Who, by = <<"test">>, reason = <<"test">>,
                   at = Now, until = infinity}).

delete({peerhost_net, CIDR}) when is_list(CIDR) ->
    delete({peerhost_net, esockd_cidr:parse(CIDR, true)});
delete(Who) ->
    true = ets:delete(?TAB, Who),
    ok.

-spec check(map()) -> boolean().
check(ClientInfo) ->
    do_check({peerhost, maps:get(peerhost, ClientInfo, undefined)}) orelse
        do_check_rules(ClientInfo).

%% @doc The `ip_check' callback: deny a banned peer.
ip_check(IP) ->
    case check(#{peerhost => IP}) of
        true -> deny;
        false -> allow
    end.

crash(_IP) ->
    error(oops).

bad_return(_IP) ->
    unknown.

do_check({_, undefined}) ->
    false;
do_check(Who) ->
    case ets:lookup(?TAB, Who) of
        [] -> false;
        [#banned{until = Until}] -> Until > erlang:system_time(second)
    end.

do_check_rules(#{peerhost := Peerhost}) ->
    Now = erlang:system_time(second),
    Rules = ets:match_object(?TAB, #banned{who = {peerhost_net, '_'}, _ = '_'}),
    lists:any(
      fun(#banned{who = {peerhost_net, CIDR}, until = Until}) ->
              Until > Now andalso esockd_cidr:match(Peerhost, CIDR)
      end, Rules);
do_check_rules(#{}) ->
    false.
