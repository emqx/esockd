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

-module(esockd_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("esockd.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

all() -> esockd_ct:all(?MODULE).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(esockd),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd).

t_open_close(_) ->
    {ok, _LSup} = esockd:open(echo, {"127.0.0.1", 3000},
                              [binary, {packet, raw}, {connection_mfargs, echo_server}]),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", 3000, [binary, {active, false}]),
    ok = gen_tcp:send(Sock, <<"Hello">>),
    {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0),
    ok = esockd:close(echo, {"127.0.0.1", 3000}).

t_reopen(_) ->
    {ok, _LSup} = esockd:open(echo, {"127.0.0.1", 3000},
                              [binary, {packet, raw}, {connection_mfargs, echo_server}]),
    {ok, Sock1} = gen_tcp:connect("127.0.0.1", 3000, [{active, false}]),
    ok = gen_tcp:send(Sock1, <<"Hello">>),
    timer:sleep(10),
    ok = esockd:reopen({echo, {"127.0.0.1", 3000}}),
    {ok, Sock2} = gen_tcp:connect("127.0.0.1", 3000, [{active, false}]),
    ok = gen_tcp:send(Sock2, <<"Hello">>),
    timer:sleep(10),
    ok = esockd:close(echo, {"127.0.0.1", 3000}).

t_reopen_1(_) ->
    {ok, _LSup} = esockd:open(echo, 7000,
                              [{max_connections, 4}, {acceptors, 4},
                               {connection_mfargs, echo_server}]),
    timer:sleep(10),
    ok = esockd:reopen({echo, 7000}),
    ?assertEqual(4, esockd:get_max_connections({echo, 7000})),
    ?assertEqual(4, esockd:get_acceptors({echo, 7000})),
    ok = esockd:close(echo, 7000).

t_reopen_fail(_) ->
    LPort = 4001,
    {ok, _LSup} = esockd:open(echo, LPort,
                              [{acceptors, 4}, {connection_mfargs, {echo_server, start_link}}]),
    {error, not_found} = esockd:reopen({echo, 5000}),
    ?assertEqual(4, esockd:get_acceptors({echo, LPort})),
    {ok, Sock} = gen_tcp:connect({127,0,0,1}, LPort, [binary, {active, false}]),
    ok = gen_tcp:send(Sock, <<"Hello">>),
    {ok, <<"Hello">>} = gen_tcp:recv(Sock, 0),
    ok = esockd:close(echo, LPort).

t_open_udp(_) ->
    {ok, _} = esockd:open_udp(echo, 5678,
                              [{connection_mfargs, {udp_echo_server, start_link}}]),
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    ok = gen_udp:send(Sock, {127,0,0,1}, 5678, <<"Hi">>),
    {ok, {_Addr, 5678, <<"Hi">>}} = gen_udp:recv(Sock, 0),
    ok = esockd:close(echo, 5678).

t_udp_child_spec(_) ->
    MFA = {udp_echo_server, start_link, []},
    Spec = esockd:udp_child_spec(echo, 5000, [{connection_mfargs, MFA}]),
    Spec = esockd:udp_child_spec(echo, 5000, [], MFA),
    #{id := {listener_sup,{echo,5000}},
      modules := [esockd_udp],
      restart := transient,
      shutdown := 5000,
      type := worker
     } = Spec.

t_open_dtls(Config) ->
    DtlsOpts = [{certfile, esockd_ct:certfile(Config)},
                {keyfile,  esockd_ct:keyfile(Config)},
                {verify, verify_none}
               ],
    {ok, _} = esockd:open_dtls(echo, 5000,
                               [{dtls_options, DtlsOpts},
                                {connection_mfargs, dtls_echo_server}]),
    {ok, Sock} = ssl:connect({127,0,0,1}, 5000, [binary,
                                                 {protocol, dtls},
                                                 {active, false},
                                                 {verify, verify_none}
                                                ], 5000),
    ok = ssl:send(Sock, <<"Hi">>),
    {ok, <<"Hi">>} = ssl:recv(Sock, 0, 3000),
    ok = ssl:close(Sock),
    ok = esockd:close(echo, 5000).

t_dtls_child_spec(_) ->
    MFA = {udp_echo_server, start_link, []},
    Spec = esockd:dtls_child_spec(echo, 8883, [{connection_mfargs, MFA}]),
    Spec = esockd:dtls_child_spec(echo, 8883, [], MFA),
     #{id := {listener_sup,{echo,8883}},
       modules := [esockd_listener_sup],
       restart := transient,
       shutdown := infinity,
       type := supervisor
      } = Spec.

t_child_spec(_) ->
    MFA = {udp_echo_server, start_link, []},
    Spec = esockd:child_spec(echo, 5000, [{connection_mfargs, MFA}]),
    Spec = esockd:child_spec(echo, 5000, [], MFA),
    #{id := {listener_sup, {echo,5000}},
      modules := [esockd_listener_sup],
      restart := transient,
      shutdown := infinity,
      type := supervisor
     } = Spec.

t_listeners(_) ->
    {ok, LSup} = esockd:open(echo, 6000, [{connection_mfargs, echo_server}]),
    [{{echo, 6000}, LSup}] = esockd:listeners(),
    ?assertEqual(LSup, esockd:listener({echo, 6000})),
    ok = esockd:close(echo, 6000),
    [] = esockd:listeners(),
    ?assertException(error, not_found, esockd:listener({echo, 6000})).

t_get_stats(_) ->
    {ok, _LSup} = esockd:open(echo, 6000, [{connection_mfargs, echo_server}]),
    {ok, Sock1} = gen_tcp:connect("127.0.0.1", 6000, [{active, false}]),
    {ok, Sock2} = gen_tcp:connect("127.0.0.1", 6000, [{active, false}]),
    timer:sleep(10),
    Cnts = esockd:get_stats({echo, 6000}),
    ?assertEqual(2, proplists:get_value(accepted, Cnts)),
    ?assertEqual(0, proplists:get_value(closed_overloaded, Cnts)),
    gen_tcp:close(Sock1),
    gen_tcp:close(Sock2),
    ok = esockd:close(echo, 6000).

t_get_options(_) ->
    {ok, _LSup} = esockd:open(echo, 6000,
                              [{acceptors, 4},
                               {connection_mfargs, {echo_server, start_link}}]),
    [{acceptors, 4},
     {connection_mfargs, {echo_server, start_link}}] = esockd:get_options({echo, 6000}),
    ok = esockd:close(echo, 6000),
    ?assertException(error, not_found, esockd:get_options({echo, 6000})),

    {ok, _LSup1} = esockd:open_dtls(dtls_echo, 6000,
                                    [{acceptors, 4},
                                     {connection_mfargs, {dtls_echo_server, start_link}}]),
    [{acceptors, 4},
     {connection_mfargs, {dtls_echo_server, start_link}}] = esockd:get_options({dtls_echo, 6000}),
    ok = esockd:close(dtls_echo, 6000),
    ?assertException(error, not_found, esockd:get_options({dtls_echo, 6000})),

    {ok, _LSup2} = esockd:open_udp(udp_echo, 6000,
                                   [{acceptors, 4},
                                    {connection_mfargs, {udp_echo_server, start_link, []}}]),
    [{acceptors, 4},
     {connection_mfargs, {udp_echo_server, start_link, []}}] = esockd:get_options({udp_echo, 6000}),
    ok = esockd:close(udp_echo, 6000),
    ?assertException(error, not_found, esockd:get_options({udp_echo, 6000})).

t_get_acceptors(_) ->
    {ok, _LSup} = esockd:open(echo, 6000,
                              [{acceptors, 4}, {connection_mfargs, echo_server}]),
    ?assertEqual(4, esockd:get_acceptors({echo, 6000})),
    ok = esockd:close(echo, 6000),

    {ok, _LSup1} = esockd:open_dtls(dtls_echo, 6000,
                                    [{acceptors, 4}, {connection_mfargs, dtls_echo_server}]),
    ?assertEqual(4, esockd:get_acceptors({dtls_echo, 6000})),
    ok = esockd:close(dtls_echo, 6000),

    {ok, _LSup2} = esockd:open_udp(udp_echo, 6000,
                                   [{acceptors, 4}, {connection_mfargs, udp_echo_server}]),
    %% fixed 1
    ?assertEqual(1, esockd:get_acceptors({udp_echo, 6000})),
    ok = esockd:close(udp_echo, 6000).

t_get_set_max_connections(_) ->
    {ok, _LSup} = esockd:open(echo, 7000,
                              [{max_connections, 4}, {connection_mfargs, echo_server}]),
    ?assertEqual(4, esockd:get_max_connections({echo, 7000})),
    {ok, _Sock1} = gen_tcp:connect("localhost", 7000, [{active, false}]),
    {ok, _Sock2} = gen_tcp:connect("localhost", 7000, [{active, false}]),
    esockd:set_max_connections({echo, 7000}, 2),
    ?assertEqual(2, esockd:get_max_connections({echo, 7000})),
    {ok, Sock3} = gen_tcp:connect("localhost", 7000, [{active, false}]),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock3, 0)),
    ok = esockd:close(echo, 7000),

    {ok, _LSup1} = esockd:open_dtls(dtls_echo, 7000,
                                    [{max_connections, 4},
                                     {connection_mfargs, dtls_echo_server}]),
    ?assertEqual(4, esockd:get_max_connections({dtls_echo, 7000})),
    esockd:set_max_connections({dtls_echo, 7000}, 16),
    ?assertEqual(16, esockd:get_max_connections({dtls_echo, 7000})),
    ok = esockd:close(dtls_echo, 7000),

    {ok, _LSup2} = esockd:open_udp(udp_echo, 7000,
                                   [{max_connections, 4},
                                    {connection_mfargs, udp_echo_server}]),
    ?assertEqual(4, esockd:get_max_connections({udp_echo, 7000})),
    esockd:set_max_connections({udp_echo, 7000}, 16),
    ?assertEqual(16, esockd:get_max_connections({udp_echo, 7000})),
    ok = esockd:close(udp_echo, 7000).

t_get_set_invalid_max_connections(_) ->
    MaxFd = esockd:ulimit(),
    MaxProcs = erlang:system_info(process_limit),
    Max = min(MaxFd, MaxProcs),
    Invalid = Max + 1,
    {ok, _LSup} = esockd:open(echo, 7000, [{connection_mfargs, echo_server}]),
    ?assertEqual(Max, esockd:get_max_connections({echo, 7000})),
    ?assertEqual(ok, esockd:set_max_connections({echo, 7000}, 2)),
    ?assertEqual(2, esockd:get_max_connections({echo, 7000})),
    ?assertEqual(ok, esockd:set_max_connections({echo, 7000}, Invalid)),
    ?assertEqual(Max, esockd:get_max_connections({echo, 7000})),
    ?assertEqual(ok, esockd:set_max_connections({echo, 7000}, Max)),
    ?assertEqual(Max, esockd:get_max_connections({echo, 7000})),
    ?assertEqual(ok, esockd:set_max_connections({echo, 7000}, infinity)),
    ?assertEqual(Max, esockd:get_max_connections({echo, 7000})),
    ok = esockd:close(echo, 7000).

t_get_set_max_conn_rate(_) ->
    LimiterOpt = #{module => esockd_limiter, capacity => 100, interval => 1},
    {ok, _LSup} = esockd:open(echo, 7000,
                              [{limiter, LimiterOpt}, {connection_mfargs, echo_server}]),
    ?assertEqual({100, 1}, esockd:get_max_conn_rate({echo, 7000})),
    esockd:set_max_conn_rate({echo, 7000}, LimiterOpt#{capacity := 50, interval := 2}),
    ?assertEqual({50, 2}, esockd:get_max_conn_rate({echo, 7000})),
    ok = esockd:close(echo, 7000),
    ?assertException(error, not_found, esockd:get_max_conn_rate({echo, 7000})),


    {ok, _LSup1} = esockd:open_dtls(dtls_echo, 7000,
                                    [{limiter, LimiterOpt},
                                     {connection_mfargs, dtls_echo_server}]),
    ?assertEqual({100, 1}, esockd:get_max_conn_rate({dtls_echo, 7000})),
    esockd:set_max_conn_rate({dtls_echo, 7000}, LimiterOpt#{capacity := 50, interval := 2}),
    ?assertEqual({50, 2}, esockd:get_max_conn_rate({dtls_echo, 7000})),
    ok = esockd:close(dtls_echo, 7000),
    ?assertException(error, not_found, esockd:get_max_conn_rate({dtls_echo, 7000})),

    {ok, _LSup2} = esockd:open_udp(udp_echo, 7000,
                                   [{limiter, LimiterOpt},
                                    {connection_mfargs, udp_echo_server}]),
    ?assertEqual({100, 1}, esockd:get_max_conn_rate({udp_echo, 7000})),
    esockd:set_max_conn_rate({udp_echo, 7000}, LimiterOpt#{capacity := 50, interval := 2}),
    ?assertEqual({50, 2}, esockd:get_max_conn_rate({udp_echo, 7000})),
    ok = esockd:close(udp_echo, 7000),
    ?assertException(error, not_found, esockd:get_max_conn_rate({udp_echo, 7000})).

t_get_current_connections(Config) ->
    {ok, _LSup} = esockd:open(echo, 7000, [{connection_mfargs, {echo_server, start_link, []}}]),
    {ok, Sock1} = gen_tcp:connect("127.0.0.1", 7000, [{active, false}]),
    {ok, Sock2} = gen_tcp:connect("127.0.0.1", 7000, [{active, false}]),
    timer:sleep(10),
    ?assertEqual(2, esockd:get_current_connections({echo, 7000})),
    ok = gen_tcp:close(Sock1),
    ok = gen_tcp:close(Sock2),
    timer:sleep(10),
    ?assertEqual(0, esockd:get_current_connections({echo, 7000})),
    ok = esockd:close(echo, 7000),

    UdpOpts = [{mode, binary}, {reuseaddr, true}],
    DtlsOpts = [{certfile, esockd_ct:certfile(Config)},
                {keyfile, esockd_ct:keyfile(Config)},
                {verify, verify_none}
               ],
    ClientOpts = [binary, {protocol, dtls}, {verify, verify_none}],
    {ok, _LSup1} = esockd:open_dtls(dtls_echo, 7000,
                                    [{dtls_options, DtlsOpts}, {udp_options, UdpOpts},
                                     {connection_mfargs, dtls_echo_server}]),
    {ok, DtlsSock1} = ssl:connect({127,0,0,1}, 7000, ClientOpts, 5000),
    {ok, DtlsSock2} = ssl:connect({127,0,0,1}, 7000, ClientOpts, 5000),
    timer:sleep(10),
    ?assertEqual(2, esockd:get_current_connections({dtls_echo, 7000})),
    ok = ssl:close(DtlsSock1),
    ok = ssl:close(DtlsSock2),
    ok = esockd:close(dtls_echo, 7000),

    {ok, _LSup2} = esockd:open_udp(udp_echo, 7001, [{connection_mfargs, udp_echo_server}]),
    {ok, UdpSock1} = gen_udp:open(0, [binary, {active, false}]),
    {ok, UdpSock2} = gen_udp:open(0, [binary, {active, false}]),
    gen_udp:send(UdpSock1, {127,0,0,1}, 7001, <<"test">>),
    gen_udp:send(UdpSock2, {127,0,0,1}, 7001, <<"test">>),
    timer:sleep(200),
    ?assertEqual(2, esockd:get_current_connections({udp_echo, 7001})),
    ok = gen_udp:close(UdpSock1),
    ok = gen_udp:close(UdpSock2),
    ok = esockd:close(udp_echo, 7001).

t_get_shutdown_count(Config) ->
    {ok, _LSup} = esockd:open(echo, 7000, [{connection_mfargs, echo_server}]),
    {ok, Sock1} = gen_tcp:connect("127.0.0.1", 7000, [{active, false}]),
    {ok, Sock2} = gen_tcp:connect("127.0.0.1", 7000, [{active, false}]),
    ok = gen_tcp:close(Sock1),
    ok = gen_tcp:close(Sock2),
    timer:sleep(10),
    ?assertEqual([{closed, 2}], esockd:get_shutdown_count({echo, 7000})),
    ok = esockd:close(echo, 7000),

    UdpOpts = [{mode, binary}, {reuseaddr, true}],
    DtlsOpts = [{certfile, esockd_ct:certfile(Config)},
                {keyfile, esockd_ct:keyfile(Config)},
                {verify, verify_none}
               ],
    ClientOpts = [binary, {protocol, dtls}, {verify, verify_none}],
    {ok, _LSup1} = esockd:open_dtls(dtls_echo, 7000,
                                    [{dtls_options, DtlsOpts}, {udp_options, UdpOpts},
                                     {connection_mfargs, dtls_echo_server}]),
    {ok, DtlsSock1} = ssl:connect({127,0,0,1}, 7000, ClientOpts, 5000),
    {ok, DtlsSock2} = ssl:connect({127,0,0,1}, 7000, ClientOpts, 5000),
    ok = ssl:close(DtlsSock1),
    ok = ssl:close(DtlsSock2),
    timer:sleep(200),
    ?assertEqual([], esockd:get_shutdown_count({dtls_echo, 7000})),
    ok = esockd:close(dtls_echo, 7000),

    {ok, _LSup2} = esockd:open_udp(udp_echo, 7001, [{connection_mfargs, udp_echo_server}]),
    {ok, UdpSock1} = gen_udp:open(0, [binary, {active, false}]),
    {ok, UdpSock2} = gen_udp:open(0, [binary, {active, false}]),
    gen_udp:send(UdpSock1, {127,0,0,1}, 7001, <<"test">>),
    gen_udp:send(UdpSock2, {127,0,0,1}, 7001, <<"test">>),
    ok = gen_udp:close(UdpSock1),
    ok = gen_udp:close(UdpSock2),
    timer:sleep(200),
    ?assertEqual([], esockd:get_shutdown_count({udp_echo, 7001})),
    ok = esockd:close(udp_echo, 7001).

t_update_options(_) ->
    {ok, _LSup} = esockd:open(echo, 6000,
                              [{acceptors, 4},
                               {tcp_options, [{backlog, 128}]},
                               {connection_mfargs, echo_server}]),
    ?assertEqual(4, esockd:get_acceptors({echo, 6000})),
    {ok, Sock1} = gen_tcp:connect("127.0.0.1", 6000, [binary, {active, false}]),
    %% Backlog size can not be changed
    ?assertEqual(
        {error, einval},
        esockd:set_options({echo, 6000},
                            [{acceptors, 8},
                             {tcp_options, [{backlog, 256}]}])
    ),
    %% Number of acceptors haven't changed
    ?assertEqual(4, esockd:get_acceptors({echo, 6000})),
    %% Other TCP options are changeable
    ?assertEqual(
        ok,
        esockd:set_options({echo, 6000},
                           [{acceptors, 16},
                            tune_buffer,
                            {tcp_options, [{send_timeout_close, false}]},
                            {connection_mfargs, {const_server, start_link, [<<"HEY">>]}}])
    ),
    {ok, Sock2} = gen_tcp:connect("127.0.0.1", 6000, [binary, {active, false}]),
    ?assertEqual(16, esockd:get_acceptors({echo, 6000})),
    %% Sockets should still be alive
    ok = gen_tcp:send(Sock1, <<"Sock1">>),
    {ok, <<"Sock1">>} = gen_tcp:recv(Sock1, 0),
    ok = gen_tcp:send(Sock2, <<"Sock2">>),
    {ok, <<"HEY">>} = gen_tcp:recv(Sock2, 0),
    ok = esockd:close(echo, 6000).

t_update_options_error(_) ->
    {ok, _LSup} = esockd:open(echo, 6000,
                              [{acceptors, 4}, {connection_mfargs, echo_server}]),
    ?assertEqual(4, esockd:get_acceptors({echo, 6000})),
    {ok, Sock1} = gen_tcp:connect("127.0.0.1", 6000, [binary, {active, false}]),
    ?assertEqual( {error, bad_access_rules}
                , esockd:set_options({echo, 6000}, [ {acceptors, 1}
                                                   , {access_rules, [{allow, "OOPS"}]}])
                ),
    ?assertEqual( {error, einval}
                , esockd:set_options({echo, 6000}, [ {acceptors, 1}
                                                   , {tcp_options, [{backlog, 1}]}])
                ),
    {ok, Sock2} = gen_tcp:connect("127.0.0.1", 6000, [binary, {active, false}]),
    ?assertEqual(4, esockd:get_acceptors({echo, 6000})),
    ok = gen_tcp:send(Sock1, <<"Sock1">>),
    {ok, <<"Sock1">>} = gen_tcp:recv(Sock1, 0),
    ok = gen_tcp:send(Sock2, <<"Sock2">>),
    {ok, <<"Sock2">>} = gen_tcp:recv(Sock2, 0),
    ok = esockd:close(echo, 6000).

t_bad_tls_options(_Config) ->
    LPort = 7001,
    %% must include '{protocol, dtls}',
    %% otherwise invalid because ssl lib defaults to '{protocol, ssl}'
    BadOpts = [{versions, ['dtlsv1.2']}],
    Res = esockd:open(echo_tls, LPort,
                      [{dtls_options, BadOpts},
                       {connection_mfargs, echo_server}]),
    ?assertMatch({error, {{shutdown, {failed_to_start_child, acceptor_sup,
                                      #{error := invalid_ssl_option,
                                        key := dtls_options}}}, _}}, Res),
    ok.

t_update_tls_options(Config) ->
    LPort = 7000,
    SslOpts1 = [ {certfile, esockd_ct:certfile(Config)}
               , {keyfile, esockd_ct:keyfile(Config)}
               , {verify, verify_none}
               ],
    SslOpts2 = [ {certfile, esockd_ct:certfile(Config, "change.crt")}
               , {keyfile, esockd_ct:keyfile(Config, "change.key")}
               , {verify, verify_none}
               ],
    ClientSslOpts = [ binary
                    , {active, false}
                    , {verify, verify_peer}
                    , {cacertfile, esockd_ct:cacertfile(Config)}
                    , {customize_hostname_check, [{match_fun, fun(_, _) -> true end}]}
                    ],
    {ok, _LSup} = esockd:open(echo_tls, LPort,
                              [{ssl_options, SslOpts1}, {connection_mfargs, echo_server}]),
    {ok, Sock1} = ssl:connect("localhost", LPort, ClientSslOpts, 1000),

    ?assertMatch(
       {error, #{error := invalid_ssl_option}},
       esockd:set_options({echo_tls, LPort}, [{ssl_options, [{verify, verify_peer}]}])
    ),

    ok = esockd:set_options({echo_tls, LPort}, [{ssl_options, SslOpts2}]),
    {ok, Sock2} = ssl:connect("localhost", LPort, ClientSslOpts, 1000),

    ok = ssl:send(Sock1, <<"Sock1">>),
    {ok, <<"Sock1">>} = ssl:recv(Sock1, 0, 1000),
    ok = ssl:send(Sock2, <<"Sock2">>),
    {ok, <<"Sock2">>} = ssl:recv(Sock2, 0, 1000),

    {ok, Cert1} = ssl:peercert(Sock1),
    {ok, Cert2} = ssl:peercert(Sock2),

    ?assertEqual(<<"Server">>, esockd_peercert:common_name(Cert1)),
    ?assertEqual(<<"Changed">>, esockd_peercert:common_name(Cert2)),

    ok = esockd:close(echo_tls, LPort).

t_allow_deny(_) ->
    AccessRules = [{allow, "192.168.1.0/24"}],
    {ok, _LSup} = esockd:open(echo, 7000, [{access_rules, AccessRules}]),
    ?assertEqual([{allow, "192.168.1.0/24"}], esockd:get_access_rules({echo, 7000})),
    ok = esockd:allow({echo, 7000}, "10.10.0.0/16"),
    ?assertEqual([{allow, "10.10.0.0/16"},
                  {allow, "192.168.1.0/24"}
                 ], esockd:get_access_rules({echo, 7000})),
    ok = esockd:deny({echo, 7000}, "172.16.1.1/16"),
    ?assertEqual([{deny,  "172.16.0.0/16"},
                  {allow, "10.10.0.0/16"},
                  {allow, "192.168.1.0/24"}
                 ], esockd:get_access_rules({echo, 7000})),
    ok = esockd:close(echo, 7000),

    %% dtls

    {ok, _LSup1} = esockd:open_dtls(dtls_echo, 7000, [{access_rules, AccessRules}]),
    ?assertEqual([{allow, "192.168.1.0/24"}], esockd:get_access_rules({dtls_echo, 7000})),
    ok = esockd:allow({dtls_echo, 7000}, "10.10.0.0/16"),
    ?assertEqual([{allow, "10.10.0.0/16"},
                  {allow, "192.168.1.0/24"}
                 ], esockd:get_access_rules({dtls_echo, 7000})),
    ok = esockd:deny({dtls_echo, 7000}, "172.16.1.1/16"),
    ?assertEqual([{deny,  "172.16.0.0/16"},
                  {allow, "10.10.0.0/16"},
                  {allow, "192.168.1.0/24"}
                 ], esockd:get_access_rules({dtls_echo, 7000})),
    ok = esockd:close(dtls_echo, 7000),

    %% udp

    {ok, _LSup2} = esockd:open_dtls(udp_echo, 7001, [{access_rules, AccessRules}]),
    ?assertEqual([{allow, "192.168.1.0/24"}], esockd:get_access_rules({udp_echo, 7001})),
    ok = esockd:allow({udp_echo, 7001}, "10.10.0.0/16"),
    ?assertEqual([{allow, "10.10.0.0/16"},
                  {allow, "192.168.1.0/24"}
                 ], esockd:get_access_rules({udp_echo, 7001})),
    ok = esockd:deny({udp_echo, 7001}, "172.16.1.1/16"),
    ?assertEqual([{deny,  "172.16.0.0/16"},
                  {allow, "10.10.0.0/16"},
                  {allow, "192.168.1.0/24"}
                 ], esockd:get_access_rules({udp_echo, 7001})),
    ok = esockd:close(udp_echo, 7001).

t_ulimit(_) ->
    ?assert(is_integer(esockd:ulimit())).

t_merge_opts(_) ->
    Opts1 = [ binary, {acceptors, 8}, {tune_buffer, true}
            , {ssl_options, [{keyfile, "key.pem"}, {certfile, "cert.pem"}]}
            ],
    Opts2 = [ binary, {acceptors, 16}
            , {ssl_options, [{keyfile, undefined}]}
            ],
    Result = [ binary, {acceptors, 16}, {tune_buffer, true}
             , {ssl_options, [{certfile, "cert.pem"}]}
             ],
    ?assertEqual(Result, esockd:merge_opts(Opts1, Opts2)).

t_changed_opts(_) ->
    Opts1 = [ binary, {acceptors, 8}, {tune_buffer, true}
            , {ssl_options, [{keyfile, "key.pem"}, {certfile, "cert.pem"}]}
            ],
    Opts2 = [ binary, inet6, {acceptors, 16}
            , {ssl_options, [{keyfile, "key.pem"}, {certfile, "cert.pem"}]}
            ],
    Result = [inet6, {acceptors, 16}],
    ?assertEqual(Result, esockd:changed_opts(Opts2, Opts1)).

t_parse_opt(_) ->
    Opts = [{acceptors, 10}, {tune_buffer, true}, {proxy_protocol, true}, {ssl_options, []}],
    ?assertEqual(Opts, esockd:parse_opt([{badopt1, val1}, {badopt2, val2}|Opts])).

t_fixaddr(_) ->
    ?assertEqual({{127,0,0,1}, 9000}, esockd:fixaddr({"127.0.0.1", 9000})),
    ?assertEqual({{10,10,10,10}, 9000}, esockd:fixaddr({{10,10,10,10}, 9000})),
    ?assertEqual({{0,0,0,0,0,0,0,1}, 9000}, esockd:fixaddr({"::1", 9000})).

t_to_string(_) ->
    ?assertEqual("9000", esockd:to_string(9000)),
    ?assertEqual("127.0.0.1:9000", esockd:to_string({"127.0.0.1", 9000})),
    ?assertEqual("192.168.1.10:9000", esockd:to_string({{192,168,1,10}, 9000})),
    ?assertEqual("::1:9000", esockd:to_string({{0,0,0,0,0,0,0,1}, 9000})).

t_format(_) ->
    ?assertEqual("127.0.0.1:9000", esockd:format({{127,0,0,1}, 9000})),
    ?assertEqual("::1:9000", esockd:format({{0,0,0,0,0,0,0,1}, 9000})).

t_tune_fun_overload(_) ->
    Ret = {error, overloaded},
    LPort = 7003,
    Name = tune_echo_overload,
    {ok, _LSup} = esockd:open(Name, LPort,
                              [{tune_fun, {?MODULE, sock_tune_fun, [Ret]}},
                               {connection_mfargs, {echo_server, start_link, []}}]),
    {ok, Socket} = gen_tcp:connect("127.0.0.1", LPort, [{active, true}]),
    receive
        {tcp_closed, S} ->
            ?assertEqual(Socket, S),
            timer:sleep(10),
            Cnts = esockd_server:get_stats({Name, LPort}),
            ?assertEqual(0, proplists:get_value(accepted, Cnts)),
            ?assertEqual(1, proplists:get_value(closed_overloaded, Cnts)),
            %% Still possible to conenct afterwards
            {ok, _S} = gen_tcp:connect("127.0.0.1", LPort, [{active, true}]),
            ok = esockd:close(Name, LPort)
    after 100 ->
            ok = esockd:close(Name, LPort),
            ct:fail(close_timeout)
    end.

t_tune_fun_ok(_) ->
    Ret = ok,
    LPort = 7004,
    Name = tune_echo_ok,
    {ok, _LSup} = esockd:open(Name, LPort,
                              [{tune_fun, {?MODULE, sock_tune_fun, [Ret]}},
                               {connection_mfargs, echo_server}]),
    {ok, _S} = gen_tcp:connect("127.0.0.1", LPort, [{active, true}]),
    timer:sleep(10),
    Cnts = esockd_server:get_stats({Name, LPort}),
    ?assertEqual(0, proplists:get_value(closed_overloaded, Cnts)),
    ?assertEqual(1, proplists:get_value(accepted, Cnts)),
    ok = esockd:close(Name, LPort).


t_listener_handle_port_exit_tcp(Config) ->
    do_listener_handle_port_exit(Config, false).

t_listener_handle_port_exit_tls(Config) ->
    do_listener_handle_port_exit(Config, true).

do_listener_handle_port_exit(Config, IsTls) ->
    LPort = 7005,
    Name = ?FUNCTION_NAME,
    SslOpts = [{certfile, esockd_ct:certfile(Config)},
               {keyfile, esockd_ct:keyfile(Config)},
               {gc_after_handshake, true},
               {verify, verify_none}
              ],
    OpenOpts = case IsTls of
                   true ->
                       ssl:start(),
                       [{ssl_options, SslOpts}];
                   false -> []
               end,
    %% GIVEN: when listener is started
    {ok, LSup} = esockd:open(Name, LPort, [{connection_mfargs, echo_server} | OpenOpts]),
    {LMod, LPid} = esockd_listener_sup:listener(LSup),
    LState = LMod:get_state(LPid),
    PortInUse = proplists:get_value(listen_port, LState),
    LSock = proplists:get_value(listen_sock, LState),
    ?assertEqual(LPort, proplists:get_value(listen_port, LState)),
    erlang:process_flag(trap_exit, true),
    link(LPid),
    Acceptors = get_acceptors(LSup),
    ?assertNotEqual([], Acceptors),

    case IsTls of
        true ->
            {ok, ClientSock} = ssl:connect("localhost", LPort, [{verify, verify_none}
                                                               ], 1000),
            ssl:close(ClientSock);
        false ->
            {ok, ClientSock} = gen_tcp:connect("localhost", LPort, [], 1000),
            ok = gen_tcp:close(ClientSock)
    end,

    timer:sleep(100),

    %% WHEN: when port is closed
    erlang:port_close(LSock),
    %% THEN: listener process should EXIT, ABNORMALLY
    receive
        {'EXIT', LPid, lsock_closed} ->
            ok
    after 300 ->
            ct:fail(listener_still_alive)
    end,

    %% THEN: listener should be restarted
    {NewLMod, NewLPid} = esockd_listener_sup:listener(LSup),
    ?assertNotEqual(LPid, NewLPid),

    %% THEN: listener should be listening on the same port
    NewLState = NewLMod:get_state(NewLPid),
    ?assertEqual(PortInUse, proplists:get_value(listen_port, NewLState)),
    ?assertMatch({error, eaddrinuse}, gen_tcp:listen(PortInUse, [])),

    %% THEN: New acceptors should be started with new LSock to accept,
    %%      (old acceptors should be terminated due to `closed')
    NewAcceptors = get_acceptors(LSup),
    ?assertNotEqual([], NewAcceptors),
    ?assert(sets:is_empty(sets:intersection(sets:from_list(Acceptors), sets:from_list(NewAcceptors)))),

    ok = esockd:close(Name, LPort).

%% helper
sock_tune_fun(Ret) ->
    Ret.

-spec get_acceptors(supervisor:supervisor()) -> [Acceptor::pid()].
get_acceptors(LSup) ->
    Children = supervisor:which_children(LSup),
    {acceptor_sup, AcceptorSup, _, _} = lists:keyfind(acceptor_sup, 1, Children),
    supervisor:which_children(AcceptorSup).
