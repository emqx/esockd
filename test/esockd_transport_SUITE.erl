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

-module(esockd_transport_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("esockd.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(TCP_OPTS, [{backlog, 1024}, {reuseaddr, true}]).


all() -> esockd_ct:all(?MODULE).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(esockd),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd).

t_type(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    tcp = esockd_transport:type(LSock),
    ssl = esockd_transport:type(#ssl_socket{}),
    proxy = esockd_transport:type(#proxy_socket{}),
    ok = esockd_transport:close(LSock).

t_is_ssl(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    false = esockd_transport:is_ssl(LSock),
    true = esockd_transport:is_ssl(SslSock = #ssl_socket{tcp = LSock}),
    false = esockd_transport:is_ssl(#proxy_socket{socket = LSock}),
    true = esockd_transport:is_ssl(#proxy_socket{socket = SslSock}),
    ok = esockd_transport:close(LSock).

t_wait_and_ready(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    esockd_transport:ready(self(), LSock, [{fun(Sock, []) -> {ok, Sock} end, [[]]}]),
    {ok, LSock} = esockd_transport:wait(LSock),
    ok = esockd_transport:close(LSock).

t_listen(_) ->
    {ok, Sock} = esockd_transport:listen(0, [binary, {active, false}]),
    ?assert(is_port(Sock)).

t_controlling_process(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    ok = esockd_transport:controlling_process(LSock, self()),
    %%ok = esockd_transport:controlling_process(#ssl_socket{ssl = SslSock}, self()),
    ok = esockd_transport:close(LSock).

t_close_tcp(_) ->
    {ok, LSock} = gen_tcp:listen(3000, [{reuseaddr, true}]),
    ok = esockd_transport:close(LSock).

t_close_ssl(Config) ->
    {ok, SslLSock} = ssl:listen(8883, [binary, {reuseaddr, true},
                                       {certfile, esockd_ct:certfile(Config)},
                                       {keyfile, esockd_ct:keyfile(Config)}
                                      ]),
    ok = esockd_transport:close(#ssl_socket{ssl = SslLSock}).

t_close_proxy(_) ->
    {ok, LSock} = gen_tcp:listen(4000, [{reuseaddr, true}]),
    ok = esockd_transport:close(#proxy_socket{socket = LSock}).

t_send_recv_tcp(_) ->
    {ok, _} = esockd:open(echo, 3000, [{tcp_options, ?TCP_OPTS}], {echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 3000, [binary, {active, false}]),
    ok = esockd_transport:send(Sock, <<"Hello">>),
    {ok, <<"Hello">>} = esockd_transport:recv(Sock, 0),
    ok = esockd:close(echo, 3000).

t_send_ssl(Config) ->
    ssl:start(),
    SslOpts = [{certfile, esockd_ct:certfile(Config)},
               {keyfile, esockd_ct:keyfile(Config)}],
    {ok, _} = esockd:open(echo, 8883, [{ssl_options, SslOpts}], {echo_server, start_link, []}),
    {ok, SslSock} = ssl:connect({127,0,0,1}, 8883, [], 3000),
    ok = esockd_transport:send(#ssl_socket{ssl = SslSock}, <<"Hello">>),
    ok = esockd_transport:close(#ssl_socket{ssl = SslSock}),
    ok = esockd:close(echo, 8883).

t_send_ssl_gc_after_handshake(Config) ->
    ssl:start(),
    SslOpts = [{certfile, esockd_ct:certfile(Config)},
               {keyfile, esockd_ct:keyfile(Config)},
               {gc_after_handshake, true}],
    {ok, _} = esockd:open(echo, 8883, [{ssl_options, SslOpts}], {echo_server, start_link, []}),
    {ok, SslSock} = ssl:connect({127,0,0,1}, 8883, [], 3000),
    ok = esockd_transport:send(#ssl_socket{ssl = SslSock}, <<"Hello">>),
    ok = esockd_transport:close(#ssl_socket{ssl = SslSock}),
    ok = esockd:close(echo, 8883).

t_send_proxy(_) ->
    {ok, _} = esockd:open(echo, 5000, [{tcp_options, [binary]},
                                       proxy_protocol,
                                       {proxy_protocol_timeout, 3000}
                                      ],
                          {echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 5000, [binary, {active, false}]),
    ok = gen_tcp:send(Sock, <<"PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n">>),
    ok = esockd_transport:send(Sock, <<"Hello">>),
    {ok, <<"Hello">>} = esockd_transport:recv(Sock, 0),
    ok = esockd_transport:close(Sock),
    ok = esockd:close(echo, 5000).

t_async_send(_) ->
    {ok, _} = esockd:open(echo, 3000, [{tcp_options, ?TCP_OPTS}], {echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 3000, [binary, {active, false}]),
    ok = esockd_transport:async_send(Sock, <<"Hello">>),
    {ok, <<"Hello">>} = esockd_transport:recv(Sock, 0),
    ok = esockd_transport:close(Sock),
    ok = esockd:close(echo, 3000).

t_async_recv(_) ->
    {ok, _} = esockd:open(echo, 3000, [{tcp_options, ?TCP_OPTS}], {async_echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 3000, [binary, {active, false}]),
    ok = esockd_transport:async_send(Sock, <<"Hello">>),
    {ok, <<"Hello">>} = esockd_transport:recv(Sock, 0),
    ok =esockd_transport:close(Sock),
    ok = esockd:close(echo, 3000).

t_get_setopts(_) ->
    {ok, _} = esockd:open(echo, 3000, [{tcp_options, ?TCP_OPTS}], {echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 3000, [binary, {active, false}]),
    ok = esockd_transport:setopts(Sock, [{active, true}]),
    {ok, [{active, true}]} = esockd_transport:getopts(Sock, [active]),
    ok = esockd_transport:close(Sock),
    ok = esockd:close(echo, 3000).

t_getstat(_) ->
    {ok, _} = esockd:open(echo, 3000, [{tcp_options, ?TCP_OPTS}], {echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 3000, [{active, false}]),
    {ok, [{recv_oct, 0}, {recv_cnt, 0}, {send_oct, 0}, {send_cnt, 0}]}
      = esockd_transport:getstat(Sock, [recv_oct, recv_cnt, send_oct, send_cnt]),
    ok = esockd_transport:close(Sock),
    ok = esockd:close(echo, 3000).

t_sockname(_) ->
    {ok, LSock} = esockd_transport:listen(3000, [{reuseaddr, true}]),
    {ok, {{0,0,0,0}, 3000}} = esockd_transport:sockname(LSock),
    ok = esockd_transport:close(LSock).

t_peername(_) ->
    {ok, _} = esockd:open(echo, 3000, [{tcp_options, ?TCP_OPTS}], {echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 3000, [{active, false}]),
    {ok, {{127,0,0,1}, 3000}} = esockd_transport:peername(Sock),
    {ok, {{127,0,0,1}, 3000}} = esockd_transport:ensure_ok_or_exit(peername, [Sock]),
    {ok, Sockname} = esockd_transport:sockname(Sock),
    {ok, Sockname} = esockd_transport:ensure_ok_or_exit(sockname, [Sock]),
    ok = esockd_transport:close(Sock),
    ok = esockd:close(echo, 3000).

t_peercert(_) ->
    {ok, LSock} = esockd_transport:listen(3000, [{reuseaddr, true}]),
    nossl = esockd_transport:peercert(LSock),
    ok = esockd_transport:close(LSock).

t_peer_cert_subject(_) ->
    {ok, LSock} = esockd_transport:listen(3000, [{reuseaddr, true}]),
    undefined = esockd_transport:peer_cert_subject(LSock),
    ok = esockd_transport:close(LSock).

t_peer_cert_common_name(_) ->
    {ok, LSock} = esockd_transport:listen(3000, [{reuseaddr, true}]),
    undefined = esockd_transport:peer_cert_common_name(LSock),
    ok = esockd_transport:close(LSock).

t_shutdown(_) ->
    {ok, _} = esockd:open(echo, 3000, [{tcp_options, ?TCP_OPTS}], {echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 3000, [{active, false}]),
    ok = esockd_transport:shutdown(Sock, read_write),
    ok = esockd:close(echo, 3000).

t_gc(_) ->
    {ok, LSock} = esockd_transport:listen(3000, [{reuseaddr, true}]),
    ok = esockd_transport:gc(LSock),
    ok = esockd_transport:close(LSock).

t_proxy_upgrade_fun(_) ->
    {Fun, [1000]} = esockd_transport:proxy_upgrade_fun([{proxy_protocol_timeout, 1000}]),
    ?assert(is_function(Fun)).

t_ssl_upgrade_fun(_) ->
    {Fun0, [[], #{timeout := 1000, gc_after_handshake := false}]}
        = esockd_transport:ssl_upgrade_fun([{handshake_timeout, 1000}]),
    ?assert(is_function(Fun0, 3)),
    {Fun1, [[], #{timeout := 1000, gc_after_handshake := true}]}
        = esockd_transport:ssl_upgrade_fun([{handshake_timeout, 1000},
                                            {gc_after_handshake, true}]),
    ?assert(is_function(Fun1, 3)),
    ok.

t_fast_close(_) ->
    {ok, LSock} = esockd_transport:listen(3000, [{reuseaddr, true}]),
    ok = esockd_transport:fast_close(LSock),
    ok = esockd_transport:close(LSock).

%% An upgrade fun that fails because the peer disappeared (closed-class
%% reasons) must make the connection process exit with the pre-establishment
%% marker, so esockd_connection_sup can refund the connection-rate token.
t_upgrade_marks_closed_class_failures(_) ->
    lists:foreach(
      fun(Reason) ->
              {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
              UpgradeFuns = [{fun(_Sock) -> {error, Reason} end, []}],
              {'EXIT', {shutdown, {pre_establishment, Reason}}} =
                  (catch esockd_transport:upgrade(LSock, UpgradeFuns))
      end,
      [closed, einval, enotconn]),
    %% ssl_upgrade/3 wraps unexpected handshake exceptions in
    %% {ssl_failure, Reason}: einval/enotconn from a dead socket are still
    %% marked
    lists:foreach(
      fun(Reason) ->
              {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
              UpgradeFuns = [{fun(_Sock) -> {error, {ssl_failure, Reason}} end, []}],
              {'EXIT', {shutdown, {pre_establishment, Reason}}} =
                  (catch esockd_transport:upgrade(LSock, UpgradeFuns))
      end,
      [einval, enotconn]),
    ok.

%% Failures that mean the client responded (or is still alive) must NOT be
%% marked: the error is returned as before.
t_upgrade_does_not_mark_responded_failures(_) ->
    {error, timeout} = upgrade_with_fun(fun(_Sock) -> {error, timeout} end),
    {error, {ssl_error, {tls_alert, unknown_ca}}} =
        upgrade_with_fun(fun(_Sock) -> {error, {ssl_error, {tls_alert, unknown_ca}}} end),
    {error, {ssl_failure, {tls_alert, unknown_ca}}} =
        upgrade_with_fun(fun(_Sock) -> {error, {ssl_failure, {tls_alert, unknown_ca}}} end),
    ok.

%% A chain of upgrade funs: a successful fun hands the socket to the next one,
%% and a closed-class failure in any fun marks the exit.
t_upgrade_chain(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    UpgradeFuns = [{fun(Sock) -> {ok, Sock} end, []},
                   {fun(Sock) -> {ok, Sock} end, []}],
    {ok, LSock} = esockd_transport:upgrade(LSock, UpgradeFuns),
    ok = esockd_transport:close(LSock),
    %% second fun fails with closed -> marked
    {ok, LSock2} = esockd_transport:listen(0, [binary, {active, false}]),
    UpgradeFuns2 = [{fun(Sock) -> {ok, Sock} end, []},
                    {fun(_Sock) -> {error, closed} end, []}],
    {'EXIT', {shutdown, {pre_establishment, closed}}} =
        (catch esockd_transport:upgrade(LSock2, UpgradeFuns2)),
    ok.

%% upgrade/2 with no upgrade funs is a pass-through.
t_upgrade_empty_funs(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    {ok, LSock} = esockd_transport:upgrade(LSock, []),
    ok = esockd_transport:close(LSock).

%% wait_with_first_data/1: first bytes already available are returned with
%% the socket, so the caller can process them without activating first.
t_wait_with_first_data_returns_available_data(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    {ok, {_, Port}} = esockd_transport:sockname(LSock),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    {ok, Sock} = gen_tcp:accept(LSock),
    ok = gen_tcp:send(Client, <<"hello">>),
    timer:sleep(50),
    esockd_transport:ready(self(), Sock, []),
    {ok, Sock, <<"hello">>} = esockd_transport:wait_with_first_data(Sock),
    ok = esockd_transport:close(Client),
    ok = esockd_transport:close(LSock).

%% wait_with_first_data/1 after an upgrade fun chain: the fun runs first, then
%% the probe sees the data.
t_wait_with_first_data_after_upgrade_funs(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    {ok, {_, Port}} = esockd_transport:sockname(LSock),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    {ok, Sock} = gen_tcp:accept(LSock),
    ok = gen_tcp:send(Client, <<"hello">>),
    timer:sleep(50),
    esockd_transport:ready(self(), Sock, [{fun(S) -> {ok, S} end, []}]),
    {ok, Sock, <<"hello">>} = esockd_transport:wait_with_first_data(Sock),
    ok = esockd_transport:close(Client),
    ok = esockd_transport:close(LSock).

%% wait_with_first_data/1: a peer that already FIN'd before sending anything
%% makes the connection process exit with the pre-establishment marker.
t_wait_with_first_data_closed_exits_marked(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    {ok, {_, Port}} = esockd_transport:sockname(LSock),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    {ok, Sock} = gen_tcp:accept(LSock),
    ok = gen_tcp:close(Client),         %% FIN before any data
    timer:sleep(50),
    esockd_transport:ready(self(), Sock, []),
    {'EXIT', {shutdown, {pre_establishment, tcp_closed}}} =
        (catch esockd_transport:wait_with_first_data(Sock)),
    ok = esockd_transport:close(LSock).

%% wait_with_first_data/1: a peer that already RST'd is marked too.
t_wait_with_first_data_rst_exits_marked(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    {ok, {_, Port}} = esockd_transport:sockname(LSock),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    {ok, Sock} = gen_tcp:accept(LSock),
    ok = inet:setopts(Client, [{linger, {true, 0}}]),
    ok = gen_tcp:close(Client),         %% RST
    timer:sleep(50),
    esockd_transport:ready(self(), Sock, []),
    {'EXIT', {shutdown, {pre_establishment, _}}} =
        (catch esockd_transport:wait_with_first_data(Sock)),
    ok = esockd_transport:close(LSock).

%% wait_with_first_data/1: a silent but alive peer returns the socket alone.
t_wait_with_first_data_silent(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    {ok, {_, Port}} = esockd_transport:sockname(LSock),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    {ok, Sock} = gen_tcp:accept(LSock),
    esockd_transport:ready(self(), Sock, []),
    {ok, Sock} = esockd_transport:wait_with_first_data(Sock),
    ok = esockd_transport:close(Client),
    ok = esockd_transport:close(LSock).

%% wait_with_first_data/1: proxy-protocol sockets (raw TCP underneath) are
%% probed on the inner socket.
t_wait_with_first_data_proxy(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    {ok, {_, Port}} = esockd_transport:sockname(LSock),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    {ok, Sock} = gen_tcp:accept(LSock),
    ok = gen_tcp:send(Client, <<"mqtt-data">>),
    timer:sleep(50),
    ProxySock = #proxy_socket{socket = Sock},
    esockd_transport:ready(self(), ProxySock, []),
    {ok, ProxySock, <<"mqtt-data">>} = esockd_transport:wait_with_first_data(ProxySock),
    ok = esockd_transport:close(Client),
    ok = esockd_transport:close(LSock).

%% wait_with_first_data/1: TLS sockets are not probed - the handshake already
%% engaged the client - the socket is returned as-is.
t_wait_with_first_data_tls_not_probed(_) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    SslSock = #ssl_socket{tcp = LSock},
    esockd_transport:ready(self(), SslSock, []),
    {ok, SslSock} = esockd_transport:wait_with_first_data(SslSock),
    ok = esockd_transport:close(LSock).

upgrade_with_fun(Fun) ->
    {ok, LSock} = esockd_transport:listen(0, [binary, {active, false}]),
    esockd_transport:upgrade(LSock, [{Fun, []}]).
