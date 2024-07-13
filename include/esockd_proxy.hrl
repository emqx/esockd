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

-ifndef(ESOCKD_PROXY_HRL).
-define(ESOCKD_PROXY_HRL, true).

-define(SSL_TRANSPORT, esockd_transport).
-define(PROXY_TRANSPORT, esockd_udp_proxy).

-type proxy_id() :: pid().
-type socket_packet() :: binary().
-type socket() :: inet:socket() | ssl:sslsocket().

-type transport() :: {udp, pid(), socket()} | ?SSL_TRANSPORT.
-type proxy_transport() :: {?PROXY_TRANSPORT, pid(), socket()}.
-type address() :: {inet:ip_address(), inet:port_number()}.
-type peer() :: socket() | address().

-type connection_module() :: atom().
-type connection_state() :: term().
-type connection_packet() :: term().

-type connection_id() ::
    peer()
    | integer()
    | string()
    | binary().

-type proxy_packet() ::
    {?PROXY_TRANSPORT, proxy_id(), binary(), connection_packet()}.

%% Routing information search results

%% send raw socket packet
-type get_connection_id_result() ::
    %% send decoded packet
    {ok, connection_id(), connection_packet(), connection_state()}
    | {error, binary()}
    | invalid.

-type connection_options() :: #{
    esockd_proxy_opts := proxy_options(),
    atom() => term()
}.

-type proxy_options() :: #{
    connection_mod := connection_module(),
    heartbeat => non_neg_integer()
}.

-endif.
