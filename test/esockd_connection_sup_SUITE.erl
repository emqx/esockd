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

-module(esockd_connection_sup_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> esockd_ct:all(?MODULE).

t_start_connection(_) ->
    ok = meck_esockd_transport(fun(_, _) ->
                                       timer:sleep(100),
                                       {ok, <<"Hi">>}
                               end),
    with_conn_sup([{max_connections, 1024}],
                  fun(ConnSup) ->
                          {ok, ConnPid} = esockd_connection_sup:start_connection(ConnSup, sock, []),
                          ?assert(is_process_alive(ConnPid))
                  end),
    ok = meck:unload(esockd_transport).

t_shutdown_connection_count(_) ->
    RecvFn = fun(_, _) ->
                     receive
                         {shutdown, Reason} ->
                             {shutdown, Reason}
                     end
             end,
    ok = meck_esockd_transport(RecvFn),
    StartThenShutdown =
        fun(ConnSup, Reason) ->
                {ok, ConnPid} = esockd_connection_sup:start_connection(ConnSup, sock, []),
                ?assert(is_process_alive(ConnPid)),
                _ = monitor(process, ConnPid),
                ConnPid ! {shutdown, Reason},
                ConnPid
        end,
    WaitDown =
        fun(ConnPid, ExpectedReason) ->
                receive
                    {'DOWN', _, _, ConnPid, Reason} ->
                        ?assertEqual({shutdown, ExpectedReason}, Reason)
                    after
                        1000 ->
                            error(timeout)
               end
        end,
    with_conn_sup([{max_connections, 1024}],
                  fun(ConnSup) ->
                          Reason1 = {ssl_error, bar},
                          Reason2 = #{shutdown_count => foo, reason => bar},
                          Pid1 = StartThenShutdown(ConnSup, Reason1),
                          Pid2 = StartThenShutdown(ConnSup, Reason2),
                          WaitDown(Pid1, Reason1),
                          WaitDown(Pid2, Reason2),
                          Counts = esockd_connection_sup:get_shutdown_count(ConnSup),
                          ?assertEqual([{foo, 1}, {ssl_error, 1}], lists:sort(Counts))
                  end),
    ok = meck:unload(esockd_transport).

t_allow_deny(_) ->
    AccessRules = [{allow, "192.168.1.0/24"}],
    with_conn_sup([{access_rules, AccessRules}],
                  fun(ConnSup) ->
                          ?assertEqual([{allow, "192.168.1.0/24"}],
                                       esockd_connection_sup:access_rules(ConnSup)),
                          ok = esockd_connection_sup:allow(ConnSup, "10.10.0.0/16"),
                          ok = esockd_connection_sup:deny(ConnSup, "172.16.1.1/16"),
                          ?assertEqual([{deny,  "172.16.0.0/16"},
                                        {allow, "10.10.0.0/16"},
                                        {allow, "192.168.1.0/24"}
                                       ], esockd_connection_sup:access_rules(ConnSup))
                  end).

t_get_shutdown_count(_) ->
    with_conn_sup([{max_connections, 1024}],
                  fun(ConnSup) ->
                          ?assertEqual([], esockd_connection_sup:get_shutdown_count(ConnSup))
                  end).

t_count_connections(_) ->
    with_conn_sup([{max_connections, 1024}],
                  fun(ConnSup) ->
                          ?assertEqual(0, esockd_connection_sup:count_connections(ConnSup))
                  end).

t_get_set_max_connections(_) ->
    with_conn_sup([{max_connections, 100}],
                  fun(ConnSup) ->
                          ?assertEqual(100, esockd_connection_sup:get_max_connections(ConnSup)),
                          ok = esockd_connection_sup:set_options(ConnSup, [{max_connections, 200}]),
                          ?assertEqual(200, esockd_connection_sup:get_max_connections(ConnSup))
                  end).

t_handle_unexpected(_) ->
    {reply, ignore, state} = esockd_connection_sup:handle_call(req, from, state),
    {noreply, state} = esockd_connection_sup:handle_cast(msg, state),
    {noreply, state} = esockd_connection_sup:handle_info(info, state).

with_conn_sup(Opts, Fun) ->
    {ok, ConnSup} = esockd_connection_sup:start_link(Opts, {echo_server, start_link, []}),
    Fun(ConnSup),
    ok = esockd_connection_sup:stop(ConnSup).

meck_esockd_transport(RecvFn) ->
    ok = meck:new(esockd_transport, [non_strict, passthrough, no_history]),
    ok = meck:expect(esockd_transport, peername, fun(_Sock) -> {ok, {{127,0,0,1}, 3456}} end),
    ok = meck:expect(esockd_transport, wait, fun(Sock) -> {ok, Sock} end),
    ok = meck:expect(esockd_transport, recv, RecvFn),
    ok = meck:expect(esockd_transport, send, fun(_Sock, _Data) -> ok end),
    ok = meck:expect(esockd_transport, controlling_process, fun(_Sock, _ConnPid) -> ok end),
    ok = meck:expect(esockd_transport, ready, fun(_ConnPid, _Sock, []) -> ok end),
    ok.

