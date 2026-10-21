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
    {ok, LSock} = esockd_transport:listen(0, []),
    tcp = esockd_transport:type(LSock),
    ssl = esockd_transport:type(#ssl_socket{}),
    proxy = esockd_transport:type(#proxy_socket{}),
    ok = esockd_transport:close(LSock).

t_is_ssl(_) ->
    {ok, LSock} = esockd_transport:listen(0, []),
    false = esockd_transport:is_ssl(LSock),
    true = esockd_transport:is_ssl(SslSock = #ssl_socket{tcp = LSock}),
    false = esockd_transport:is_ssl(#proxy_socket{socket = LSock}),
    true = esockd_transport:is_ssl(#proxy_socket{socket = SslSock}),
    ok = esockd_transport:close(LSock).

t_wait_and_ready(_) ->
    {ok, LSock} = esockd_transport:listen(0, []),
    esockd_transport:ready(self(), LSock, [{fun(Sock, []) -> {ok, Sock} end, [[]]}]),
    {ok, LSock} = esockd_transport:wait(LSock),
    ok = esockd_transport:close(LSock).

t_listen(_) ->
    {ok, Sock} = esockd_transport:listen(0, []),
    ?assert(is_port(Sock)).

t_controlling_process(_) ->
    {ok, LSock} = esockd_transport:listen(0, []),
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
    {ok, LSock} = gen_tcp:listen(4001, [{reuseaddr, true}]),
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
               {keyfile, esockd_ct:keyfile(Config)},
               {verify, verify_none}
              ],
    {ok, _} = esockd:open(echo, 8883, [{ssl_options, SslOpts}], {echo_server, start_link, []}),
    {ok, SslSock} = ssl:connect({127,0,0,1}, 8883, [{verify, verify_none}], 3000),
    ok = esockd_transport:send(#ssl_socket{ssl = SslSock}, <<"Hello">>),
    ok = esockd_transport:close(#ssl_socket{ssl = SslSock}),
    ok = esockd:close(echo, 8883).

t_send_ssl_gc_after_handshake(Config) ->
    ssl:start(),
    SslOpts = [{certfile, esockd_ct:certfile(Config)},
               {keyfile, esockd_ct:keyfile(Config)},
               {gc_after_handshake, true},
               {verify, verify_none}
              ],
    {ok, _} = esockd:open(echo, 8883, [{ssl_options, SslOpts}], {echo_server, start_link, []}),
    {ok, SslSock} = ssl:connect({127,0,0,1}, 8883, [{verify, verify_none}], 3000),
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

-if(?OTP_RELEASE >= 26).
t_async_send_reply(_) ->
    {S, C} = tcp_pair(),
    ok = esockd_transport:async_send(S, <<"Hello">>),
    receive {inet_reply, S, ok, send_async} -> ok
    after 1000 -> ct:fail(no_inet_reply)
    end,
    {ok, <<"Hello">>} = gen_tcp:recv(C, 5, 1000),
    ok = gen_tcp:close(S),
    ok = gen_tcp:close(C).

%% The fallback sends with gen_tcp:send/2 and sends the reply itself.
t_async_send_fallback(_) ->
    persistent_term:put({esockd_transport, send_async_module}, undefined),
    try
        {S, C} = tcp_pair(),
        ok = esockd_transport:async_send(S, <<"Hello">>, [nosuspend]),
        receive {inet_reply, S, ok, send_async} -> ok
        after 0 -> ct:fail(no_inet_reply)
        end,
        {ok, <<"Hello">>} = gen_tcp:recv(C, 5, 1000),
        ok = gen_tcp:close(S),
        {error, closed} = esockd_transport:async_send(S, <<"Hello">>),
        ok = gen_tcp:close(C)
    after
        persistent_term:erase({esockd_transport, send_async_module})
    end.

%% With prim_inet:send_async/3, a busy port returns {error, busy} with
%% nosuspend. The replies of the queued sends arrive after the peer
%% reads the data.
t_async_send_prim_inet_send_async(_) ->
    case erlang:function_exported(prim_inet, send_async, 3) of
        false ->
            {skip, no_prim_inet_send_async};
        true ->
            persistent_term:erase({esockd_transport, send_async_module}),
            {S, C} = tcp_pair(),
            ok = inet:setopts(S, [{high_watermark, 4096}, {low_watermark, 1024},
                                  {sndbuf, 4096}]),
            ok = inet:setopts(C, [{recbuf, 4096}]),
            Chunk = binary:copy(<<"x">>, 16384),
            NSent = fill_until_busy(S, Chunk, 0),
            prim_inet = persistent_term:get({esockd_transport, send_async_module}),
            {ok, _} = gen_tcp:recv(C, NSent * byte_size(Chunk), 10000),
            [receive {inet_reply, S, ok, send_async} -> ok
             after 5000 -> ct:fail(no_inet_reply)
             end || _ <- lists:seq(1, NSent)],
            ok = gen_tcp:close(S),
            ok = gen_tcp:close(C)
    end.

fill_until_busy(_S, _Chunk, 1000) ->
    ct:fail(port_never_busy);
fill_until_busy(S, Chunk, N) ->
    case esockd_transport:async_send(S, Chunk, [nosuspend]) of
        ok -> fill_until_busy(S, Chunk, N + 1);
        {error, busy} -> N
    end.

tcp_pair() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}]),
    {ok, Port} = inet:port(L),
    {ok, C} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    {ok, S} = gen_tcp:accept(L, 5000),
    ok = gen_tcp:close(L),
    {S, C}.
-endif.

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

t_peersni_normal(_) ->
    {ok, LSock} = esockd_transport:listen(3000, [{reuseaddr, true}]),
    undefined = esockd_transport:peersni(LSock),
    ok = esockd_transport:close(LSock).

t_peersni_ssl(Config) ->
    ssl:start(),
    ServerName = "Server", %% The Common Name of 'tests/certs/test.crt'
    ServerSslOpts =
        [{certfile, esockd_ct:certfile(Config)},
         {keyfile, esockd_ct:keyfile(Config)},
         %% We must specify this parameter manually, otherwise the
         %% sni will not be retrieved on otp23
         {sni_fun, fun(_sni) -> [] end},
         {gc_after_handshake, true}],
    {ok, _} = esockd:open(
                echo, 8883, [{ssl_options, ServerSslOpts}],
                {?MODULE, start_link_peersni, [ServerName]}
               ),
    ClientSslOpts = [{cacertfile, esockd_ct:cacertfile(Config)},
                     {verify, verify_peer},
                     {server_name_indication, ServerName}
                    ],
    {ok, SslSock} = ssl:connect("localhost", 8883, ClientSslOpts, 3000),
    ok = ssl:send(SslSock, <<"Hello">>),
    receive
        {ssl, _, "Hello"} -> ok
    after 1000 ->
              ct:fail("assert sni failed")
    end,
    ok = ssl:close(SslSock),
    ok = esockd:close(echo, 8883).

t_peersni_ssl_disabled_sni(Config) ->
    ssl:start(),
    SslOpts = [{certfile, esockd_ct:certfile(Config)},
               {keyfile, esockd_ct:keyfile(Config)},
               {gc_after_handshake, true},
               {verify, verify_none}
              ],
    ClientSslOpts = [{server_name_indication, disable}, {verify, verify_none}],
    {ok, _} = esockd:open(echo, 8883, [{ssl_options, SslOpts}], {?MODULE, start_link_peersni, [disable]}),
    {ok, SslSock} = ssl:connect("localhost", 8883, ClientSslOpts, 3000),
    ok = ssl:send(SslSock, <<"Hello">>),
    receive
        {ssl, _, "Hello"} -> ok
    after 1000 ->
              ct:fail("assert sni failed")
    end,
    ok = ssl:close(SslSock),
    ok = esockd:close(echo, 8883).

t_peersni_proxy(_) ->
    <<"localhost">> = esockd_transport:peersni(
                        #proxy_socket{
                           pp2_additional_info = [{pp2_authority, <<"localhost">>}]
                          }).

%% A TCP-passthrough proxy in front of an SSL listener delivers the
%% TLS handshake (and therefore the client certificate) directly to
%% the listener. Proxy V1 has no SSL TLVs, so the proxy header carries
%% no peer-cert info; peercert/peer_cert_* must read from the inner
%% ssl_socket.
t_peercert_proxy_ssl(_Config) ->
    ssl:start(),
    Port = 8884,
    {ServerBase, ClientBase} = mtls_chain(),
    ServerSslOpts =
        ServerBase ++
        [{verify, verify_peer},
         {fail_if_no_peer_cert, true},
         {sni_fun, fun(_SNI) -> [] end}],
    Self = self(),
    {ok, _} = esockd:open(
        echo, Port,
        [proxy_protocol,
         {proxy_protocol_timeout, 3000},
         {ssl_options, ServerSslOpts}],
        {?MODULE, start_link_peercert_proxy_ssl, [Self]}),
    %% Raw TCP connect, send PP V1 header, then upgrade to TLS with
    %% a client cert. This mirrors a TCP-passthrough proxy in front
    %% of an SSL listener.
    {ok, TcpSock} = gen_tcp:connect(
        {127,0,0,1}, Port,
        [binary, {active, false}, {packet, raw}], 3000),
    ok = gen_tcp:send(
        TcpSock,
        <<"PROXY TCP4 192.168.1.1 192.168.1.2 4321 ", (integer_to_binary(Port))/binary, "\r\n">>),
    ClientSslOpts =
        ClientBase ++
        [{verify, verify_peer},
         {server_name_indication, disable},
         {active, false}],
    {ok, SslSock} = ssl:connect(TcpSock, ClientSslOpts, 5000),
    ok = ssl:send(SslSock, <<"Hello">>),
    {ok, <<"Hello">>} = ssl:recv(SslSock, 0, 2000),
    %% Wait for the connection process's peercert assertion result.
    receive
        {peercert_check, ok} -> ok;
        {peercert_check, {fail, Why}} -> ct:fail({peercert_check_failed, Why})
    after 2000 ->
              ct:fail(no_peercert_check_result)
    end,
    ok = ssl:close(SslSock),
    ok = esockd:close(echo, Port).

%% Generate a fresh CA + server peer + client peer chain at runtime so
%% the suite carries no static client-cert fixtures. Returns ssl
%% option lists ready to be merged into server/client opts.
mtls_chain() ->
    KeySpec = [{digest, sha256}, {key, {rsa, 2048, 65537}}],
    #{server_config := ServerConf, client_config := ClientConf} =
        public_key:pkix_test_data(
          #{server_chain => #{root => KeySpec,
                              intermediates => [],
                              peer => KeySpec},
            client_chain => #{root => KeySpec,
                              intermediates => [],
                              peer => KeySpec}}),
    {ServerConf, ClientConf}.

start_link_peercert_proxy_ssl(Transport, RawSock, ReportTo) ->
    {ok, spawn_link(?MODULE, peercert_proxy_ssl_init,
                    [Transport, RawSock, ReportTo])}.

peercert_proxy_ssl_init(Transport, RawSock, ReportTo) ->
    case Transport:wait(RawSock) of
        {ok, Sock} ->
            Result = check_peercert(Transport, Sock),
            ReportTo ! {peercert_check, Result},
            peercert_proxy_ssl_loop(Transport, Sock);
        {error, Reason} ->
            ReportTo ! {peercert_check, {fail, {wait, Reason}}}
    end.

check_peercert(Transport, Sock) ->
    %% peercert/1 must return the DER-encoded client cert (not [] from
    %% the empty pp2_additional_info, and not undefined).
    case Transport:peercert(Sock) of
        Cert when is_binary(Cert) ->
            CN = Transport:peer_cert_common_name(Sock),
            Subject = Transport:peer_cert_subject(Sock),
            case is_binary(CN) andalso is_binary(Subject) of
                true -> ok;
                false -> {fail, {unexpected_subject, CN, Subject}}
            end;
        Other ->
            {fail, {unexpected_peercert, Other}}
    end.

peercert_proxy_ssl_loop(Transport, Sock) ->
    case Transport:recv(Sock, 0) of
        {ok, Data} ->
            Transport:send(Sock, Data),
            peercert_proxy_ssl_loop(Transport, Sock);
        {error, _} ->
            ok
    end.

%% A proxy that terminates mTLS and re-encrypts the hop to this listener
%% forwards the client's details in the PROXY V2 SSL TLVs. The inner
%% handshake is one-way, so the inner ssl_socket has no peer certificate
%% and the TLVs are the only source. Counterpart to t_peercert_proxy_ssl/1,
%% which covers the TCP-passthrough proxy where the inner socket is the
%% only source. Both must keep working.
t_peercert_proxy_ssl_pp2_fallback(_Config) ->
    ssl:start(),
    Port = 8885,
    CN = <<"client-cn-from-pp2">>,
    {ServerBase, _ClientBase} = mtls_chain(),
    %% One-way TLS on the inner hop: the proxy already did the client-cert
    %% check, so this listener asks for no client certificate.
    ServerSslOpts =
        ServerBase ++
        [{verify, verify_none},
         {sni_fun, fun(_SNI) -> [] end}],
    Self = self(),
    {ok, _} = esockd:open(
        echo, Port,
        [proxy_protocol,
         {proxy_protocol_timeout, 3000},
         {ssl_options, ServerSslOpts}],
        {?MODULE, start_link_pp2_fallback, [Self, CN]}),
    {ok, TcpSock} = gen_tcp:connect(
        {127,0,0,1}, Port,
        [binary, {active, false}, {packet, raw}], 3000),
    ok = gen_tcp:send(TcpSock, pp2_header_with_ssl_cn(CN, Port)),
    %% No client certificate: this is the re-encrypted hop.
    ClientSslOpts = [{verify, verify_none},
                     {server_name_indication, disable},
                     {active, false}],
    {ok, SslSock} = ssl:connect(TcpSock, ClientSslOpts, 5000),
    ok = ssl:send(SslSock, <<"Hello">>),
    {ok, <<"Hello">>} = ssl:recv(SslSock, 0, 2000),
    receive
        {peercert_check, ok} -> ok;
        {peercert_check, {fail, Why}} -> ct:fail({peercert_check_failed, Why})
    after 2000 ->
              ct:fail(no_peercert_check_result)
    end,
    ok = ssl:close(SslSock),
    ok = esockd:close(echo, Port).

%% When the proxy terminates mTLS and also presents its own certificate on
%% the re-encrypted hop, both sources hold a certificate. The TLVs come from
%% the hop closest to the client and describe the client; the inner one is
%% the proxy's. The TLVs win.
t_peercert_proxy_ssl_pp2_wins_over_inner(_Config) ->
    ssl:start(),
    Port = 8886,
    CN = <<"client-cn-from-pp2">>,
    {ServerBase, ClientBase} = mtls_chain(),
    %% mTLS on the inner hop as well: the proxy authenticates to the listener.
    ServerSslOpts =
        ServerBase ++
        [{verify, verify_peer},
         {fail_if_no_peer_cert, true},
         {sni_fun, fun(_SNI) -> [] end}],
    Self = self(),
    {ok, _} = esockd:open(
        echo, Port,
        [proxy_protocol,
         {proxy_protocol_timeout, 3000},
         {ssl_options, ServerSslOpts}],
        {?MODULE, start_link_pp2_fallback, [Self, CN]}),
    {ok, TcpSock} = gen_tcp:connect(
        {127,0,0,1}, Port,
        [binary, {active, false}, {packet, raw}], 3000),
    ok = gen_tcp:send(TcpSock, pp2_header_with_ssl_cn(CN, Port)),
    ClientSslOpts =
        ClientBase ++
        [{verify, verify_peer},
         {server_name_indication, disable},
         {active, false}],
    {ok, SslSock} = ssl:connect(TcpSock, ClientSslOpts, 5000),
    ok = ssl:send(SslSock, <<"Hello">>),
    {ok, <<"Hello">>} = ssl:recv(SslSock, 0, 2000),
    receive
        {peercert_check, ok} -> ok;
        {peercert_check, {fail, Why}} -> ct:fail({peercert_check_failed, Why})
    after 2000 ->
              ct:fail(no_peercert_check_result)
    end,
    ok = ssl:close(SslSock),
    ok = esockd:close(echo, Port).

%% Build a PROXY V2 header carrying a PP2_TYPE_SSL TLV whose
%% PP2_SUBTYPE_SSL_CN sub-TLV holds CN. Constants are spelled out here
%% because they are defined in esockd_proxy_protocol.erl, not in a header.
pp2_header_with_ssl_cn(CN, DstPort) ->
    PP2_TYPE_SSL = 16#20,
    PP2_SUBTYPE_SSL_CN = 16#22,
    CnTlv = <<PP2_SUBTYPE_SSL_CN:8, (byte_size(CN)):16, CN/binary>>,
    %% <<Unused:5, CERT_SESS:1, CERT_CONN:1, CLIENT_SSL:1, VERIFY:32, SubTlvs>>
    %% CLIENT_SSL and CERT_CONN set, VERIFY 0 meaning verified successfully.
    SslVal = <<0:5, 0:1, 1:1, 1:1, 0:32, CnTlv/binary>>,
    SslTlv = <<PP2_TYPE_SSL:8, (byte_size(SslVal)):16, SslVal/binary>>,
    Signature = <<13,10,13,10,0,13,10,81,85,73,84,10>>,
    %% 16#21: version 2, PROXY command. 16#11: AF_INET over STREAM.
    Addresses = <<127,0,0,1, 127,0,0,1, 4321:16, DstPort:16>>,
    Body = <<Addresses/binary, SslTlv/binary>>,
    <<Signature/binary, 16#21:8, 16#11:8, (byte_size(Body)):16, Body/binary>>.

start_link_pp2_fallback(Transport, RawSock, ReportTo, CN) ->
    {ok, spawn_link(?MODULE, pp2_fallback_init, [Transport, RawSock, ReportTo, CN])}.

pp2_fallback_init(Transport, RawSock, ReportTo, CN) ->
    case Transport:wait(RawSock) of
        {ok, Sock} ->
            ReportTo ! {peercert_check, check_pp2_fallback(Transport, Sock, CN)},
            peercert_proxy_ssl_loop(Transport, Sock);
        {error, Reason} ->
            ReportTo ! {peercert_check, {fail, {wait, Reason}}}
    end.

check_pp2_fallback(Transport, Sock, CN) ->
    %% The inner handshake produced no peer certificate, so all three must
    %% come from the PROXY V2 SSL TLVs rather than from the inner socket.
    PeerCert = Transport:peercert(Sock),
    GotCN = Transport:peer_cert_common_name(Sock),
    Subject = Transport:peer_cert_subject(Sock),
    case {is_list(PeerCert) andalso proplists:get_value(pp2_ssl_cn, PeerCert),
          GotCN, Subject} of
        {CN, CN, CN} -> ok;
        Other -> {fail, {unexpected, Other, expected, CN}}
    end.

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

%%--------------------------------------------------------------------
%% peersni

start_link_peersni(Transport, RawSock, SNI) ->
    {ok, spawn_link(?MODULE, peersni_conn_init, [Transport, RawSock, SNI])}.

peersni_conn_init(Transport, RawSock, SNI) ->
    case Transport:wait(RawSock) of
        {ok, Sock} ->
            %% assert peersni
            case SNI of
                disable ->
                    undefined = Transport:peersni(Sock);
                _ ->
                    SNI1 = list_to_binary(SNI),
                    SNI1 = Transport:peersni(Sock)
            end,
            peersni_loop(Transport, Sock);
        {error, Reason} ->
            {error, Reason}
    end.

peersni_loop(Transport, Sock) ->
	case Transport:recv(Sock, 0) of
        {ok, Data} ->
            Transport:send(Sock, Data),
            peersni_loop(Transport, Sock);
        {error, Reason} ->
            exit({shutdown, Reason})
	end.
