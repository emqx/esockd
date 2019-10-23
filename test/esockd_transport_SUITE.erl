%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_transport_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> esockd_ct:all(?MODULE).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

t_type(_) ->
    error('TODO').

t_is_ssl(_) ->
    error('TODO').

t_wait(_) ->
    error('TODO').

t_close(_) ->
    error('TODO').

t_send(_) ->
    error('TODO').

t_async_send(_) ->
    error('TODO').

t_recv(_) ->
    error('TODO').

t_async_recv(_) ->
    error('TODO').

t_getopts(_) ->
    error('TODO').

t_setopts(_) ->
    error('TODO').

t_getstat(_) ->
    error('TODO').

t_sockname(_) ->
    error('TODO').

t_peercert(_) ->
    error('TODO').

t_peer_cert_subject(_) ->
    error('TODO').

t_peer_cert_common_name(_) ->
    error('TODO').

t_shutdown(_) ->
    error('TODO').

t_ensure_ok_or_exit(_) ->
    error('TODO').

t_gc(_) ->
    error('TODO').

t_proxy_upgrade_fun(_) ->
    error('TODO').

t_ssl_upgrade_fun(_) ->
    error('TODO').

t_fast_close(_) ->
    error('TODO').

t_listen(_) ->
    error('TODO').

t_peername(_) ->
    error('TODO').

t_ready(_) ->
    error('TODO').

t_controlling_process(_) ->
    error('TODO').

