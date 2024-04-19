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

-module(esockd_udp_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-record(state, {proto, sock, port, rate_limit,
  conn_limiter, limit_timer, max_peers,
  peers, options, access_rules, mfa}).

all() -> esockd_ct:all(?MODULE).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% Test cases for UDP Server
%%--------------------------------------------------------------------

t_udp_server(_) ->
    with_udp_server(
      fun(_Srv, Port) ->
              {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
              ok = udp_send_and_recv(Sock, Port, <<"hello">>),
              ok = udp_send_and_recv(Sock, Port, <<"world">>)
      end).

t_count_peers(_) ->
    with_udp_server(
      fun(Srv, Port) ->
              {ok, Sock1} = gen_udp:open(0, [binary, {active, false}]),
              ok = udp_send_and_recv(Sock1, Port, <<"hello">>),
              {ok, Sock2} = gen_udp:open(0, [binary, {active, false}]),
              ok = udp_send_and_recv(Sock2, Port, <<"world">>),
              ?assertEqual(2, esockd_udp:count_peers(Srv))
      end).

t_peer_down(_) ->
    with_udp_server(
      fun(Srv, Port) ->
              {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
              ok = udp_send_and_recv(Sock, Port, <<"hello">>),
              ?assertEqual(1, esockd_udp:count_peers(Srv)),
              ok = gen_udp:send(Sock, {127,0,0,1}, Port, <<"stop">>),
              timer:sleep(100),
              ?assertEqual(0, esockd_udp:count_peers(Srv))
      end).

t_udp_error(_) ->
  with_udp_server(
    fun(Srv, Port) ->
      process_flag(trap_exit, true),
      {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
      ok = udp_send_and_recv(Sock, Port, <<"hello">>),
      ?assertEqual(1, esockd_udp:count_peers(Srv)),
      #state{sock = SrvSock, peers = Peers} = sys:get_state(Srv),
      ?assertEqual(2, maps:size(Peers)),
      erlang:send(Srv, {udp_error, SrvSock, unknown}),
      receive
        Msg ->
          ?assertMatch({'EXIT', _, {udp_error,unknown}}, Msg)
      after 1000 ->
        throw(udp_error_timeout)
      end,
      ?assertEqual(false, erlang:is_process_alive(Srv)),
      maps:foreach(fun(K, V) ->
        ?assertNot(is_pid(K) andalso erlang:is_process_alive(K)),
        ?assertNot(is_pid(V) andalso erlang:is_process_alive(V))
                   end, Peers)
    end).

udp_send_and_recv(Sock, Port, Data) ->
    ok = gen_udp:send(Sock, {127,0,0,1}, Port, Data),
    {ok, {_Addr, Port, Data}} = gen_udp:recv(Sock, 0),
    ok.

with_udp_server(TestFun) ->
    dbg:tracer(),
    dbg:p(all, c),
    dbg:tpl({emqx_connection_sup, '_', '_'}, x),
    MFA = {?MODULE, udp_echo_init},
    {ok, Srv} = esockd_udp:server(test, {{127,0,0,1}, 6000}, [{connection_mfargs, MFA}]),
    TestFun(Srv, 6000),
    is_process_alive(Srv) andalso (ok = esockd_udp:stop(Srv)).

udp_echo_init(Transport, Peer) ->
    {ok, spawn(fun() -> udp_echo_loop(Transport, Peer) end)}.

udp_echo_loop(Transport, Peer) ->
    receive
        {datagram, _From, <<"stop">>} ->
            exit(normal);
        {datagram, From, Packet} ->
            From ! {datagram, Peer, Packet},
            udp_echo_loop(Transport, Peer)
    end.

t_handle_call(_) ->
    {reply, ignore, state} = esockd_udp:handle_call(req, from, state).

t_handle_cast(_) ->
    {noreply, state} = esockd_udp:handle_cast(msg, state).

t_handle_info(_) ->
  {noreply, state} = esockd_udp:handle_info(info, state).

t_code_change(_) ->
    {ok, state} = esockd_udp:code_change(oldvsn, state, extra).
