%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_socket_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

-define(FAST_ENOUGH_MS, 25).

all() -> esockd_ct:all(?MODULE).

init_per_suite(Config) ->
    Host = os:getenv("ESOCKD_CT_TCPTEST_HOST"),
    Port = os:getenv("ESOCKD_CT_TCPTEST_PORT"),
    TCUrl = os:getenv("ESOCKD_CT_TC_URL"),
    TCContainer = os:getenv("ESOCKD_CT_TC_ID_TCPTEST"),
    case Host =/= false andalso Port =/= false of
        true ->
            [{tcptest_host, Host},
             {tcptest_port, list_to_integer(Port)},
             {tc_url, TCUrl},
             {tc_container, TCContainer}
            | Config];
        false ->
            {skip, "Remote TCP test server not running"}
    end.

end_per_suite(_Config) ->
    ok.

init_per_testcase(t_fast_close_lost_network, Config) ->
    case proplists:get_value(tc_url, Config) of
        false ->
            {skip, "Docker Traffic Control not running"};
        _ ->
            Config
    end;
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(t_fast_close_lost_network, Config) ->
    traffic_control_stop(Config);
end_per_testcase(_TestCase, _Config) ->
    ok.

%%

t_fast_close(Config) ->
    Sock = connect_tcptest(Config),
    T0 = erlang:monotonic_time(millisecond),
    ok = esockd_socket:fast_close(Sock),
    TD = erlang:monotonic_time(millisecond) - T0,
    ?assert(TD < ?FAST_ENOUGH_MS, TD).

t_fast_close_send_buffers(Config) ->
    Sock = connect_tcptest(Config),
    ok = socket:send(Sock, esockd_tcptest:command({sleep, 10_000})),
    _Select = send_until_select(Sock, 1),
    T0 = erlang:monotonic_time(millisecond),
    ok = esockd_socket:fast_close(Sock),
    TD = erlang:monotonic_time(millisecond) - T0,
    ?assert(TD < ?FAST_ENOUGH_MS, TD).

t_fast_close_lost_network(Config) ->
    Sock = connect_tcptest(Config),
    ok = socket:send(Sock, esockd_tcptest:command(echo)),
    ok = socket:send(Sock, <<"Hello!">>),
    ?assertEqual({ok, <<"Hello!">>}, socket:recv(Sock, 0, 5_000)),
    %% Turn on complete 100% packet loss:
    ok = traffic_control_set([{"loss", "100%"}], Config),
    %% Stuff the send buffer full:
    _Select = send_until_select(Sock, 1),
    %% Close is still expected to be fast:
    T0 = erlang:monotonic_time(millisecond),
    ok = esockd_socket:fast_close(Sock),
    TD = erlang:monotonic_time(millisecond) - T0,
    ?assert(TD < ?FAST_ENOUGH_MS, TD).

%%

connect_tcptest(Config) ->
    Host = proplists:get_value(tcptest_host, Config),
    Port = proplists:get_value(tcptest_port, Config),
    Addr = case inet:parse_address(Host) of
               {ok, X} -> X;
               {error, einval} ->
                   {ok, X} = inet:getaddr(Host, inet),
                   X
           end,
    {ok, Sock} = socket:open(inet, stream, tcp),
    ok = esockd_socket:setopts(Sock, [{{otp, rcvbuf}, 2048},
                                      {{socket, rcvbuf}, 2048},
                                      {{socket, sndbuf}, 2048}]),
    ok = socket:connect(Sock, #{family => inet,
                                addr => Addr,
                                port => Port}),
    Sock.

send_until_select(Sock, N) ->
    case socket:send(Sock, binary:copy(<<N:32>>, 200), nowait) of
        ok ->
            send_until_select(Sock, N + 1);
        {select, _} = Select ->
            Select;
        {error, closed} ->
            ct:fail("Socket closed unexpectedly")
    end.

traffic_control_set(Policy, Config) ->
    TCContainer = proplists:get_value(tc_container, Config),
    TCUrl = proplists:get_value(tc_url, Config),
    Request = {TCUrl ++ "/" ++ TCContainer,
               [],
               _ContentType = "application/x-www-form-urlencoded",
               uri_string:compose_query(Policy)},
    {ok, {{_HTTP, 200, _OK}, _Headers, ""}} =
        httpc:request(post, Request, [], []),
    ok.

traffic_control_stop(Config) ->
    TCContainer = proplists:get_value(tc_container, Config),
    TCUrl = proplists:get_value(tc_url, Config),
    Request = {TCUrl ++ "/" ++ TCContainer, []},
    {ok, {{_HTTP, 200, _OK}, _Headers, ""}} =
        httpc:request(delete, Request, [], []),
    ok.
