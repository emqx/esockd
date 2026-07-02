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

-module(esockd_udp_proxy_legacy_conn).

-export([initialize/1, find_or_create/4, get_connection_id/4, dispatch/3, close/2]).

initialize(Opts) ->
    #{parent => maps:get(test_parent, Opts)}.

get_connection_id(_Transport, _Peer, State, Data) ->
    {ok, Data, Data, State#{last_cid => Data}}.

find_or_create(CId, _Transport, _Peer, _Opts) ->
    Pid = spawn(fun connection_loop/0),
    test_parent() ! {find_or_create, CId, CId, Pid},
    {ok, Pid}.

dispatch(Pid, State, {_Transport, _Data, Packet}) ->
    maps:get(parent, State) ! {dispatch, Pid, Packet},
    Pid ! {packet, Packet},
    ok.

close(Pid, State) ->
    maps:get(parent, State) ! {close, Pid},
    Pid ! close,
    ok.

test_parent() ->
    persistent_term:get({?MODULE, test_parent}).

connection_loop() ->
    receive
        close ->
            ok;
        _Msg ->
            connection_loop()
    end.
