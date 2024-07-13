%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_udp_proxy_connection).

-include("include/esockd_proxy.hrl").

-export([
    initialize/2,
    find_or_create/5,
    get_connection_id/5,
    dispatch/4,
    close/3
]).

-export_type([connection_id/0, connection_module/0]).

%%--------------------------------------------------------------------
%%- Callbacks
%%--------------------------------------------------------------------
-callback initialize(connection_options()) -> connection_state().

%% Create new connection
-callback find_or_create(connection_id(), proxy_transport(), peer(), connection_options()) ->
    gen_server:start_ret().

%% Find routing information
-callback get_connection_id(
    proxy_transport(), peer(), connection_state(), socket_packet()
) ->
    get_connection_id_result().

%% Dispacth message
-callback dispatch(pid(), connection_state(), proxy_packet()) -> ok.

%% Close Connection
-callback close(pid(), connection_state()) -> ok.

%%--------------------------------------------------------------------
%%- API
%%--------------------------------------------------------------------
initialize(Mod, Opts) ->
    Mod:initialize(Opts).

find_or_create(Mod, CId, Transport, Peer, Opts) ->
    Mod:find_or_create(CId, Transport, Peer, Opts).

get_connection_id(Mod, Transport, Peer, State, Data) ->
    Mod:get_connection_id(Transport, Peer, State, Data).

dispatch(Mod, Pid, State, Packet) ->
    Mod:dispatch(Pid, State, Packet).

close(Mod, Pid, State) ->
    Mod:close(Pid, State).
