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

-module(esockd_acceptor_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

all() -> esockd_ct:all(?MODULE).

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(esockd),
    Config.

end_per_suite(_Config) ->
    application:stop(esockd).

%%--------------------------------------------------------------------
%% End-to-end: connection-rate limiter
%%--------------------------------------------------------------------

%% A client aborts the connection (RST) while the acceptor is suspended
%% (token exhausted), i.e. while the connection sits in the kernel accept
%% backlog.  The aborted socket is still handed out by accept() on Linux
%% and macOS alike, but its peer is already gone: start_connection's
%% peername fails with {error, enotconn}/{error, einval} and the socket is
%% discarded without consuming a connection-rate token, otherwise reconnect
%% storms get throttled by dead sockets.
t_dead_socket_consumes_no_token(_) ->
    Port = 12110,
    Opts = [{max_conn_rate, 1}, {acceptors, 1}],
    {ok, _} = esockd:open(echo, Port, Opts, {echo_server, start_link, []}),
    timer:sleep(100),
    %% first live connection spends the only token; the acceptor then
    %% suspends for ~1s and stops accepting
    {ok, C1} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(C1, <<"a">>),
    {ok, <<"a">>} = gen_tcp:recv(C1, 0, 2000),
    gen_tcp:close(C1),
    %% while the acceptor is suspended, a client connects and aborts (RST):
    %% the connection dies while queued in the kernel backlog
    {ok, C2} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    ok = inet:setopts(C2, [{linger, {true, 0}}]),
    ok = gen_tcp:close(C2),
    %% the acceptor resumes ~1s later and accepts the dead socket: it must
    %% be discarded without spending the refilled token
    timer:sleep(1500),
    ?assertEqual(1, listener_tokens(Port)),
    ?assertEqual(2, listener_stat(Port, accepted)),
    ?assertEqual(1, listener_stat(Port, discarded)),
    %% the discard reason is recorded for online troubleshooting
    %% (enotconn on Linux, einval on macOS)
    ?assertEqual(1, dead_sock_error_count(Port)),
    %% the next live connection is not throttled by the dead one:
    %% with max_conn_rate=1 a wasted token would stall it for ~1s
    {ok, C3} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(C3, <<"hello">>),
    {ok, <<"hello">>} = gen_tcp:recv(C3, 0, 500),
    gen_tcp:close(C3),
    ok = esockd:close(echo, Port).

%% Regression: live connections still consume tokens and get throttled.
t_live_socket_consumes_token(_) ->
    Port = 12111,
    Opts = [{max_conn_rate, 1}, {acceptors, 1}],
    {ok, _} = esockd:open(echo, Port, Opts, {echo_server, start_link, []}),
    timer:sleep(100),
    %% first connection spends the only token
    {ok, C1} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(C1, <<"a">>),
    {ok, <<"a">>} = gen_tcp:recv(C1, 0, 2000),
    gen_tcp:close(C1),
    %% the second connection has to wait for the next refill (~1s)
    T0 = erlang:monotonic_time(millisecond),
    {ok, C2} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(C2, <<"b">>),
    {ok, <<"b">>} = gen_tcp:recv(C2, 0, 5000),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ct:pal("throttled second connection took ~pms", [Elapsed]),
    ?assert(Elapsed >= 500),
    gen_tcp:close(C2),
    ?assertEqual(2, listener_stat(Port, accepted)),
    ?assertEqual(0, listener_stat(Port, discarded)),
    ?assertEqual([], sock_errors(Port)),
    ok = esockd:close(echo, Port).

%% A socket that fails the tune step was never handed to a connection
%% process: no rate-limit token should be spent on it either.
t_tune_failure_consumes_no_token(_) ->
    Port = 12112,
    Opts = [{max_conn_rate, 1}, {acceptors, 1}, {tune_buffer, true}],
    {ok, _} = esockd:open(echo, Port, Opts, {echo_server, start_link, []}),
    timer:sleep(100),
    Tokens0 = listener_tokens(Port),
    Accepted0 = listener_stat(Port, accepted),
    ok = meck:new(esockd_transport, [non_strict, passthrough, no_history]),
    ok = meck:expect(esockd_transport, getopts, fun(_S, _O) -> {error, enotconn} end),
    try
        {ok, C} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
        ok = gen_tcp:send(C, <<"x">>),
        timer:sleep(300),
        %% the acceptor closed the socket (tune failed)
        ?assertMatch({error, _}, gen_tcp:recv(C, 0, 1000)),
        %% but it did not consume a token for it
        ?assertEqual(Tokens0, listener_tokens(Port)),
        ?assertEqual(Accepted0 + 1, listener_stat(Port, accepted)),
        ?assertEqual(1, listener_stat(Port, discarded)),
        %% and the tune failure reason is recorded for online troubleshooting
        ?assertEqual(1, proplists:get_value(enotconn, sock_errors(Port), 0))
    after
        catch meck:unload(esockd_transport)
    end,
    ok = esockd:close(echo, Port).

%% Regression: a connection MFA returning ignore must neither crash the
%% acceptor (case_clause) nor spend a connection-rate token.
t_ignore_start_connection(_) ->
    Port = 12114,
    Opts = [{max_conn_rate, 1}, {acceptors, 1}],
    {ok, _} = esockd:open(echo, Port, Opts, {echo_server, start_link, []}),
    timer:sleep(100),
    ok = meck:new(echo_server, [non_strict, passthrough, no_history]),
    ok = meck:expect(echo_server, start_link, fun(_Transport, _Sock) -> ignore end),
    try
        {ok, C1} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
        timer:sleep(300),
        %% the acceptor closed the socket and did not spend a token on it
        ?assertMatch({error, _}, gen_tcp:recv(C1, 0, 1000)),
        ?assertEqual(1, listener_tokens(Port))
    after
        catch meck:unload(echo_server)
    end,
    %% the acceptor did not crash: a live connection still works
    {ok, C2} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}]),
    ok = gen_tcp:send(C2, <<"hello">>),
    {ok, <<"hello">>} = gen_tcp:recv(C2, 0, 2000),
    gen_tcp:close(C2),
    ok = esockd:close(echo, Port).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

listener_tokens(Port) ->
    case esockd_limiter:lookup({listener, echo, Port}) of
        undefined -> undefined;
        Info -> maps:get(tokens, Info)
    end.

listener_stat(Port, Metric) ->
    proplists:get_value(Metric, esockd_server:get_stats({echo, Port}), 0).

%% sock-error counters are part of the listener stats, keyed
%% {sock_error, Reason} (see esockd_server:get_stats/1)
sock_errors(Port) ->
    [{Reason, Count} || {{sock_error, Reason}, Count}
                        <- esockd_server:get_stats({echo, Port})].

%% count of discarded sockets whose peer was already gone at accept time
%% ({error, enotconn} on Linux, {error, einval} on macOS)
dead_sock_error_count(Port) ->
    Errs = sock_errors(Port),
    proplists:get_value(enotconn, Errs, 0) + proplists:get_value(einval, Errs, 0).
