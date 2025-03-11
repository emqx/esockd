%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(const_udp_server).

-export([start_link/3]).

-export([init/3, loop/3]).

start_link(Transport, Peer, Resp) ->
	{ok, spawn_link(?MODULE, init, [Transport, Peer, Resp])}.

init(Transport, Peer, Resp) ->
    loop(Transport, Peer, Resp).

loop(Transport, Peer, Resp) ->
    receive
        {datagram, _From, <<"stop">>} ->
            exit(normal);
        {datagram, From, _Packet} ->
            From ! {datagram, Peer, Resp},
            loop(Transport, Peer, Resp)
    end.
