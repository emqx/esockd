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

-module(esockd_proxy_protocol_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("esockd.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> [{group, gen_tcp},
          {group, socket},
          {group, parser},
          {group, integration}].

groups() ->
    SocketTCs = [t_recv_ppv1,
                 t_recv_ppv1_unknown,
                 t_recv_ppv2,
                 t_recv_pp_invalid,
                 t_recv_pp_partial,
                 t_recv_socket_error],
    [{gen_tcp, [sequence], SocketTCs},
     {socket, [sequence], SocketTCs},
     {parser, [sequence], [t_parse_v1,
                           t_parse_v2,
                           t_parse_pp2_additional,
                           t_parse_pp2_ssl,
                           t_parse_pp2_tlv]},
     {integration, [sequence], [t_ppv1_tcp4_connect,
                               t_ppv1_tcp6_connect,
                               t_ppv2_connect,
                               t_ppv2_connect_first_marker_timeout,
                               t_ppv2_connect_header_timeout,
                               t_ppv2_connect_proxy_info_timeout,
                               t_ppv1_unknown,
                               t_ppv1_garbage_data]}].

%%--------------------------------------------------------------------
%% CT callbacks
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(esockd),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd).

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% Test cases for recv
%%--------------------------------------------------------------------

t_recv_ppv1(Config) ->
    with_tcp_server(Config, fun(Backend, ServerSide, ClientSide) ->
        ok = gen_tcp:send(ClientSide, <<"PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n">>),
        ok = gen_tcp:send(ClientSide, <<"Hello">>),
        
        {ok, ProxySocket} =
            esockd_proxy_protocol:recv(Backend, ServerSide, 1000),
        ?assertEqual(
            #{proxy_protocol => inet4,
              proxy_src_addr => {192,168,1,1}, proxy_dst_addr => {192,168,1,2},
              proxy_src_port => 80, proxy_dst_port => 81,
              proxy_pp2_info => []},
            esockd_proxy_protocol:get_proxy_attrs(ProxySocket)
        ),
        
        {ok, <<"Hello">>} = recv(Backend, ServerSide, 0)
    end).

t_recv_ppv1_unknown(Config) ->
    with_tcp_server(Config, fun(Backend, ServerSide, ClientSide) ->
        ok = gen_tcp:send(ClientSide, <<"PROXY UNKNOWN\r\n">>),
        ok = gen_tcp:send(ClientSide, <<"Hello">>),
        
        {ok, Sock} = esockd_proxy_protocol:recv(Backend, ServerSide, 1000),
        case Backend of
            esockd_transport ->
                ?assert(is_port(Sock));
            esockd_socket ->
                ?assertMatch(#{}, socket:info(Sock))
        end,
        
        {ok, <<"Hello">>} = recv(Backend, ServerSide, 0)
    end).

t_recv_ppv2(Config) ->
    with_tcp_server(Config, fun(Backend, ServerSide, ClientSide) ->
        ok = gen_tcp:send(ClientSide, <<13,10,13,10,0,13,10,81,85,73,84,10,33,17,0,
                                        12,127,50,210,1,210,21,16,142,250,32,1,181>>),
        ok = gen_tcp:send(ClientSide, <<"Hello">>),
        
        {ok, ProxySocket} =
            esockd_proxy_protocol:recv(Backend, ServerSide, 1000),
        ?assertEqual(
            #{proxy_protocol => inet4,
              proxy_src_addr => {127,50,210,1}, proxy_dst_addr => {210,21,16,142},
              proxy_src_port => 64032, proxy_dst_port => 437,
              proxy_pp2_info => []},
            esockd_proxy_protocol:get_proxy_attrs(ProxySocket)
        ),
        
        {ok, <<"Hello">>} = recv(Backend, ServerSide, 0)
    end).

t_recv_pp_invalid(Config) ->
    with_tcp_server(Config, fun(Backend, ServerSide, ClientSide) ->
        ok = gen_tcp:send(ClientSide, <<"Invalid PROXY\r\n">>),
        ok = gen_tcp:send(ClientSide, <<"Hello">>),
        
        {error, {invalid_proxy_info, <<"In", _/binary>>}} =
            esockd_proxy_protocol:recv(Backend, ServerSide, 1000)
    end).

t_recv_pp_partial(Config) ->
    with_tcp_server(Config, fun(Backend, ServerSide, ClientSide) ->
        ok = gen_tcp:send(ClientSide, <<"PROXY DUMMY\r\n">>),
        ok = gen_tcp:send(ClientSide, <<"Hello">>),
        
        {error, {invalid_proxy_info, <<"PROXY DUMMY", _/binary>>}} =
            esockd_proxy_protocol:recv(Backend, ServerSide, 1000)
    end).

t_recv_socket_error(Config) ->
    with_tcp_server(Config, fun(Backend, ServerSide, ClientSide) ->
        %% Close the client socket to simulate connection error
        gen_tcp:close(ClientSide),
        timer:sleep(10), % Give time for the close to propagate
        
        {error, proxy_proto_close} =
            esockd_proxy_protocol:recv(Backend, ServerSide, 1000)
    end).

recv(esockd_transport, Sock, Len) ->
    esockd_transport:recv(Sock, Len);
recv(esockd_socket, Sock, Len) ->
    socket:recv(Sock, Len).

%%--------------------------------------------------------------------
%% Test cases for parse
%%--------------------------------------------------------------------

t_parse_v1(_Config) ->
    {ok, #proxy_socket{src_addr = {192,168,1,30}, src_port = 45420,
                       dst_addr = {192,168,1,2},  dst_port = 1883}}
    = esockd_proxy_protocol:parse_v1(<<"192.168.1.30 192.168.1.2 45420 1883\r\n">>,
                                     #proxy_socket{}),
    {ok, #proxy_socket{src_addr = {255,255,255,255}, src_port = 65535,
                       dst_addr = {255,255,255,255}, dst_port = 65535}}
    = esockd_proxy_protocol:parse_v1(<<"255.255.255.255 255.255.255.255 65535 65535\r\n">>,
                                     #proxy_socket{}).

t_parse_v2(_Config) ->
    {ok, #proxy_socket{src_addr = {104,199,189,98}, src_port = 6000,
                       dst_addr = {106,185,34,253}, dst_port = 8883,
                       inet = inet4}}
    = esockd_proxy_protocol:parse_v2(16#1, 16#1, <<104,199,189,98,106,185,34,253,6000:16,8883:16>>,
                                     #proxy_socket{inet = inet4}),
    {ok, #proxy_socket{src_addr = {0,0,0,0,0,0,0,1}, src_port = 6000,
                       dst_addr = {0,0,0,0,0,0,0,1}, dst_port = 5000,
                       inet = inet6}}
    = esockd_proxy_protocol:parse_v2(16#1, 16#1, <<1:128, 1:128, 6000:16, 5000:16>>,
                                     #proxy_socket{inet = inet6}).

t_parse_pp2_additional(_) ->
    AdditionalInfo = [{pp2_alpn, <<"29zka">>},
                      {pp2_authority, <<"219a3k">>},
                      {pp2_netns, <<"abc.com">>},
                      {pp2_ssl,
                       [{pp2_ssl_client, true},
                        {pp2_ssl_client_cert_conn, true},
                        {pp2_ssl_client_cert_sess, true},
                        {pp2_ssl_verify, success}]}],
    {ok, #proxy_socket{src_addr = {104,199,189,98}, src_port = 6000,
                       dst_addr = {106,185,34,253}, dst_port = 8883,
                       inet = inet4, pp2_additional_info = AdditionalInfo}}
    = esockd_proxy_protocol:parse_v2(16#1, 16#1, <<104,199,189,98,106,185,34,253,6000:16,8883:16,
                                                   01,00,05,"29zka",02,00,06,"219a3k",16#30,00,07,"abc.com",
                                                   16#20,00,05,07,00,00,00,00>>,
                                     #proxy_socket{inet = inet4}).

t_parse_pp2_ssl(_) ->
    Bin = <<01,00,05,"29zka",02,00,06,"219a3k",16#30,00,07,"abc.com",16#20,00,05,03,00,00,00,01>>,
    [{pp2_ssl_client, false},
     {pp2_ssl_client_cert_conn, false},
     {pp2_ssl_client_cert_sess, true},
     {pp2_ssl_verify, success}|_]
    = esockd_proxy_protocol:parse_pp2_ssl(<<0:5, 1:1, 0:1, 0:1, 0:32, Bin/binary>>).

t_parse_pp2_tlv(_) ->
    Bin = <<01,00,05,"29zka",02,00,06,"219a3k",16#30,00,07,"abc.com",16#20,00,05,03,00,00,00,01>>,
    [{1, <<"29zka">>}, {2, <<"219a3k">>}, {16#30, <<"abc.com">>}, {16#20, <<3,0,0,0,1>>}]
    = esockd_proxy_protocol:parse_pp2_tlv(fun(E) -> E end, Bin).

%%--------------------------------------------------------------------
%% Test cases for pp server
%%--------------------------------------------------------------------

t_ppv1_tcp4_connect(_) ->
    with_pp_server(fun(Sock) ->
                           ok = gen_tcp:send(Sock, <<"PROXY TCP4 192.168.1.1 192.168.1.2 80 81\r\n">>),
                           ok = gen_tcp:send(Sock, <<"Hello">>),
                           {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0)
                   end).

t_ppv1_tcp6_connect(_) ->
    with_pp_server(fun(Sock) ->
                           ok = gen_tcp:send(Sock, <<"PROXY TCP6 ::1 ::1 6000 50000\r\n">>),
                           ok = gen_tcp:send(Sock, <<"Hello">>),
                           {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0)
                   end).

t_ppv2_connect(_) ->
    with_pp_server(fun(Sock) ->
                           ok = gen_tcp:send(Sock, <<13,10,13,10,0,13,10,81,85,73,84,10,33,17,0,
                                                     12,127,50,210,1,210,21,16,142,250,32,1,181>>),
                           ok = gen_tcp:send(Sock, <<"Hello">>),
                           {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0)
                   end),
    with_pp_server(fun(Sock) ->
                            ok = gen_tcp:send(Sock, <<13,10,13,10,0,13,10,81,85,73,84,10,33,17,0,
                                                    12,127,50,210,1,210,21,16,142,250,32,1,181>>),
                            ok = gen_tcp:send(Sock, <<"Hello">>),
                            {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0)
                   end,
                   [{proxy_protocol_timeout, infinity}]).

t_ppv2_connect_first_marker_timeout(_) ->
    with_pp_server(
        fun(Sock) ->
            timer:sleep(200),
            {error, closed} = gen_tcp:recv(Sock, 0)
        end,
        [{proxy_protocol_timeout, 100}]),
    with_pp_server(
        fun(Sock) ->
            timer:sleep(400),
            ok = gen_tcp:send(Sock, <<13,10,13,10,0,13,10,81,85,73,84,10,33,17,0,
                                      12,127,50,210,1,210,21,16,142,250,32,1,181>>),
            ok = gen_tcp:send(Sock, <<"Hello">>),
            {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0)
        end,
        [{proxy_protocol_timeout, 500}]).

t_ppv2_connect_header_timeout(_) ->
    with_pp_server(
        fun(Sock) ->
            timer:sleep(200),
            ok = gen_tcp:send(Sock, <<13,10>>),
            timer:sleep(200),
            ok = gen_tcp:send(Sock, <<13,10,0,13,10,81,85,73,84,10,33,17,0,
                                     12,127,50,210,1,210,21,16,142,250,32,1,181>>),
            ok = gen_tcp:send(Sock, <<"Hello">>),
            {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0)
        end,
        [{proxy_protocol_timeout, 500}]),
    with_pp_server(
        fun(Sock) ->
            timer:sleep(200),
            ok = gen_tcp:send(Sock, <<13,10>>),
            timer:sleep(400),
            {error, closed} = gen_tcp:recv(Sock, 0)
        end,
        [{proxy_protocol_timeout, 500}]).

t_ppv2_connect_proxy_info_timeout(_) ->
    with_pp_server(
        fun(Sock) ->
            timer:sleep(100),
            ok = gen_tcp:send(Sock, <<13,10>>),
            timer:sleep(100),
            ok = gen_tcp:send(Sock, <<13,10,0,13,10,81,85,73,84,10,33,17,0,
                                        12,127,50,210,1,210,21,16,142>>),
            timer:sleep(200),
            ok = gen_tcp:send(Sock, <<250,32,1,181>>),
            ok = gen_tcp:send(Sock, <<"Hello">>),
            {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0)
        end,
        [{proxy_protocol_timeout, 500}]),
    with_pp_server(
        fun(Sock) ->
            timer:sleep(100),
            ok = gen_tcp:send(Sock, <<13,10>>),
            timer:sleep(100),
            ok = gen_tcp:send(Sock, <<13,10,0,13,10,81,85,73,84,10,33,17,0,
                                        12,127,50,210,1,210,21,16,142>>),
            timer:sleep(400),
            {error, closed} = gen_tcp:recv(Sock, 0)
        end,
        [{proxy_protocol_timeout, 500}]).

t_ppv1_unknown(_) ->
    with_pp_server(fun(Sock) ->
                           ok = gen_tcp:send(Sock, <<"PROXY UNKNOWN\r\n">>),
                           ok = gen_tcp:send(Sock, <<"Hello">>),
                           {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0)
                   end).

t_ppv1_garbage_data(_) ->
    with_pp_server(fun(Sock) ->
                           ok = gen_tcp:send(Sock, <<"************\r\n">>),
                           ok = gen_tcp:send(Sock, <<"GarbageData">>)
                   end).

%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

with_tcp_server(Config, TestFun) ->
    LPort = 45654,
    TcpOpts = [binary, {active, false}],
    SockMod = group_name(Config),
    case SockMod of
        gen_tcp ->
            Backend = esockd_transport,
            {ok, ServerSock} = gen_tcp:listen(LPort, [{reuseaddr, true} | TcpOpts]);
        socket ->
            Backend = esockd_socket,
            {ok, ServerSock} = socket:open(inet, stream, tcp),
            ok = socket:bind(ServerSock, #{family => inet, addr => {127,0,0,1}, port => LPort}),
            ok = socket:listen(ServerSock, 16)
    end,
    {ok, ClientSide} = gen_tcp:connect({127,0,0,1}, LPort, TcpOpts),
    {ok, ServerSide} = SockMod:accept(ServerSock),
    try TestFun(Backend, ServerSide, ClientSide) after
        gen_tcp:close(ClientSide),
        SockMod:close(ServerSide),
        SockMod:close(ServerSock)
    end.

with_pp_server(TestFun) ->
    PPOpts = [{proxy_protocol_timeout, 3000}],
    with_pp_server(TestFun, PPOpts).

with_pp_server(TestFun, PPOpts) ->
    Opts = PPOpts ++
    [
        {tcp_options, [binary]},
        proxy_protocol
    ],
    {ok, _} = esockd:open(echo, 5000, Opts, {echo_server, start_link, []}),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, 5000, [binary, {active, false}]),
    try TestFun(Sock) after ok = esockd:close(echo, 5000) end.

group_name(Config) ->
    % NOTE: Contains the name of the current test group, if executed as part of a group.
    GroupProps = proplists:get_value(tc_group_properties, Config, []),
    proplists:get_value(name, GroupProps, undefined).
