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

-module(esockd_acceptor_fsm_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("esockd.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(PORT, 30000 + ?LINE).
-define(COUNTER_ACCEPTED, 1).
-define(COUNTER_OVERLOADED, 2).
-define(COUNTER_RATE_LIMITED, 3).
-define(COUNTER_SYS_LIMIT, 4).
-define(COUNTER_MAX_LIMIT, 5).
-define(COUNTER_OTHER_REASONS, 6).
-define(COUNTER_EARLY, 7).
-define(COUNTER_FORBIDDEN, 8).
-define(COUNTER_RATE_LIMITED_TARPIT, 9).
-define(COUNTER_LAST, 10).

counter_tag_to_index(accepted) -> ?COUNTER_ACCEPTED;
counter_tag_to_index(closed_sys_limit) -> ?COUNTER_SYS_LIMIT;
counter_tag_to_index(closed_max_limit) -> ?COUNTER_MAX_LIMIT;
counter_tag_to_index(closed_overloaded) -> ?COUNTER_OVERLOADED;
counter_tag_to_index(closed_rate_limited) -> ?COUNTER_RATE_LIMITED;
counter_tag_to_index(closed_rate_limited_tarpit) -> ?COUNTER_RATE_LIMITED_TARPIT;
counter_tag_to_index(closed_early) -> ?COUNTER_EARLY;
counter_tag_to_index(closed_forbidden) -> ?COUNTER_FORBIDDEN;
counter_tag_to_index(closed_other_reasons) -> ?COUNTER_OTHER_REASONS.

all() -> 
    [{group, inet}, {group, tcpsocket}].

groups() ->
    [{inet, [sequence], test_cases()},
     {tcpsocket, [sequence], test_cases()}].

test_cases() ->
    esockd_ct:all(?MODULE).

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(inet, Config) ->
    [{accept_mod, esockd_accept_inet} | Config];
init_per_group(tcpsocket, Config) ->
    [{accept_mod, esockd_accept_socket} | Config].

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Counters = counters:new(?COUNTER_LAST, []),
    meck:new(esockd_server, [passthrough, no_history, no_sticky]),
    Listener = self(),
    meck:expect(esockd_server, get_listener_prop,
                fun(_ListenerRef, listener) -> {?MODULE, Listener} end),
    meck:expect(esockd_server, inc_stats,
                fun(_, Tag, Count) ->
                        Index =  counter_tag_to_index(Tag),
                        counters:add(Counters, Index, Count)
                end),
    [{counters, Counters} | Config].

end_per_testcase(_Case, _Config) ->
    meck:unload(esockd_server).

start(PortNumber, Limiter) ->
    start(PortNumber, Limiter, #{}).

start(PortNumber, Limiter, Opts) ->
    start(PortNumber, Limiter, Opts, [{accept_mod, esockd_accept_inet}]).

start(PortNumber, Limiter, Opts, Config) ->
    AcceptMod = proplists:get_value(accept_mod, Config),
    case AcceptMod of
        esockd_accept_inet ->
            SockOpts = [binary,
                        {active, false},
                        {reuseaddr, true},
                        {nodelay, true},
                        {backlog, maps:get(backlog, Opts, 1024)}],
            {ok, LSock} = gen_tcp:listen(PortNumber, SockOpts);
        esockd_accept_socket -> 
            Backlog = maps:get(backlog, Opts, 1024),
            {ok, LSock} = socket:open(inet, stream, tcp),
            ok = socket:setopt(LSock, {socket, reuseaddr}, true),
            ok = socket:bind(LSock, #{family => inet,
                                    addr => any,
                                    port => PortNumber}),
            ok = socket:listen(LSock, Backlog)
    end,
    ListenerRef = {tcp, PortNumber},
    StartConn = {fun ?MODULE:start_connection/3, [Opts]},
    TuneFun = maps:get(tune_fun, Opts, AcceptMod:mk_tune_socket_fun([])),
    AcceptCb = {AcceptMod, TuneFun},
    {Holder, Tarpit} = start_tarpit(maps:get(tarpit, Opts, undefined)),
    {ok, AccPid} = esockd_acceptor_fsm:start_link(
        ListenerRef,
        StartConn,
        AcceptCb,
        _UpgradeFuns = [],
        Limiter,
        Tarpit,
        LSock
    ),
    #{lsock => LSock, acceptor => AccPid, tarpit => Holder}.

start_tarpit(undefined) ->
    {undefined, undefined};
start_tarpit(#{size := Size, delay := Delay}) ->
    {ok, Holder} = esockd_tarpit:start_link(Size, Delay),
    {Holder, esockd_tarpit:handle(Holder)}.

stop(#{lsock := LSock, acceptor := AccPid} = Server) ->
    ok = stop_if_alive(AccPid),
    case maps:get(tarpit, Server, undefined) of
        undefined -> ok;
        Holder -> stop_if_alive(Holder)
    end,
    case is_port(LSock) of
        true -> gen_tcp:close(LSock);
        false -> socket:close(LSock)
    end,
    ok.

connect(Port) ->
    connect(Port, 1000, #{}).

connect(Port, Timeout, Opts0) ->
    Opts = [binary,
            {active, maps:get(active, Opts0, false)},
            {show_econnreset, maps:get(show_econnreset, Opts0, false)},
            {nodelay, true}],
    gen_tcp:connect("localhost", Port, Opts, Timeout).

%% This is the very basic test, if this fails, nothing elese matters.
t_normal(Config) ->
    Port = ?PORT,
    Server = start(Port, no_rate_limit(), #{}, Config),
    {ok, ClientSock} = connect(Port),
    try
        ok = wait_for_counter(Config, ?COUNTER_ACCEPTED, 1, 2000)
    after
        disconnect(ClientSock),
        stop(Server)
    end.

t_rate_limitted(Config) ->
    Port = ?PORT,
    Pause = 200,
    Server = start(Port, pause_then_allow(Pause), #{}, Config),
    try
        Count = 10,
        Socks = lists:map(fun(_) ->
                                  {ok, Sock} = connect(Port, 1000, #{active => true}),
                                  Sock
                          end, lists:seq(1, Count)),
        %% One selective receive for each socket, because the close
        %% notifications do not have to arrive in connect order.
        lists:foreach(fun(Sock) ->
                              receive
                                  {tcp_closed, Sock} ->
                                      ok
                              after
                                  2000 ->
                                      ct:fail({no_tcp_closed, Sock})
                              end
                      end, Socks),
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED, Count, 2000),
        ?assertEqual(0, get_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT)),
        timer:sleep(Pause),
        {ok, Sock2} = connect(Port),
        ok = wait_for_counter(Config, ?COUNTER_ACCEPTED, 1, 2000),
        disconnect(Sock2)
    after
        stop(Server)
    end.

%% A refused socket is held for the tarpit delay, then reset.
t_tarpit_held_then_reset(Config) ->
    Port = ?PORT,
    Delay = 1000,
    Opts = #{tarpit => #{size => 10, delay => Delay}},
    Server = start(Port, pause_then_allow(60000), Opts, Config),
    try
        {ok, Sock} = connect(Port, 1000, #{active => true, show_econnreset => true}),
        T0 = erlang:monotonic_time(millisecond),
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT, 1, 2000),
        ok = assert_no_close(Sock, Delay - 200),
        ok = assert_reset(Sock, 2000),
        ?assert(erlang:monotonic_time(millisecond) - T0 >= Delay - 200),
        ?assertEqual(1, get_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT)),
        ?assertEqual(0, get_counter(Config, ?COUNTER_RATE_LIMITED))
    after
        stop(Server)
    end.

%% A refused socket is closed at once when the tarpit is full.
t_tarpit_full(Config) ->
    Port = ?PORT,
    Opts = #{tarpit => #{size => 1, delay => 60000}},
    #{tarpit := Holder} = Server = start(Port, pause_then_allow(60000), Opts, Config),
    try
        {ok, Sock1} = connect(Port, 1000, #{active => true}),
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT, 1, 2000),
        {ok, Sock2} = connect(Port, 1000, #{active => true}),
        receive
            {tcp_closed, Sock2} -> ok
        after
            2000 -> ct:fail({no_tcp_closed, Sock2})
        end,
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED, 1, 2000),
        ?assertEqual(1, get_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT)),
        ?assertEqual(1, esockd_tarpit:count(esockd_tarpit:handle(Holder))),
        ok = assert_no_close(Sock1, 100)
    after
        stop(Server)
    end.

%% A slot is free again after its socket is released.
t_tarpit_slot_reused(Config) ->
    Port = ?PORT,
    Delay = 300,
    Opts = #{tarpit => #{size => 1, delay => Delay}},
    Server = start(Port, pause_then_allow(60000), Opts, Config),
    try
        {ok, Sock1} = connect(Port, 1000, #{active => true, show_econnreset => true}),
        ok = assert_reset(Sock1, Delay + 2000),
        {ok, Sock2} = connect(Port, 1000, #{active => true, show_econnreset => true}),
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT, 2, 2000),
        ok = assert_no_close(Sock2, Delay div 2),
        ok = assert_reset(Sock2, Delay + 2000)
    after
        stop(Server)
    end.

%% The acceptor owns the held sockets. They close when it stops.
t_tarpit_acceptor_stop(Config) ->
    Port = ?PORT,
    Opts = #{tarpit => #{size => 10, delay => 60000}},
    #{acceptor := Acceptor} = Server = start(Port, pause_then_allow(60000), Opts, Config),
    {ok, Sock} = connect(Port, 1000, #{active => true, show_econnreset => true}),
    try
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT, 1, 2000),
        ok = gen_statem:stop(Acceptor),
        receive
            {tcp_closed, Sock} -> ok;
            {tcp_error, Sock, econnreset} -> ok
        after
            1000 -> ct:fail({not_closed, Sock})
        end
    after
        stop(Server)
    end.

%% Stopping the holder resets the held sockets.
t_tarpit_holder_stop(Config) ->
    Port = ?PORT,
    Opts = #{tarpit => #{size => 10, delay => 60000}},
    #{tarpit := Holder} = Server = start(Port, pause_then_allow(60000), Opts, Config),
    {ok, Sock} = connect(Port, 1000, #{active => true, show_econnreset => true}),
    try
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT, 1, 2000),
        %% The hold message is sent before the counter is updated.
        ok = gen_server:stop(Holder),
        ok = assert_reset(Sock, 1000)
    after
        stop(Server)
    end.

%% emfile/enfile resets the held sockets to free their fds.
t_tarpit_sys_limit(Config) ->
    AcceptMod = proplists:get_value(accept_mod, Config),
    Port = ?PORT,
    Opts = #{tarpit => #{size => 10, delay => 60000}},
    Server = start(Port, pause_then_allow(60000), Opts, Config),
    try
        {ok, Sock1} = connect(Port, 1000, #{active => true, show_econnreset => true}),
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT, 1, 2000),
        %% The next accept after Sock2 fails with emfile.
        meck:new(AcceptMod, [passthrough, no_history]),
        meck:expect(AcceptMod, async_accept, fun(_) -> {error, emfile} end),
        {ok, Sock2} = connect(Port, 1000, #{active => true, show_econnreset => true}),
        ok = assert_reset(Sock1, 2000),
        ok = assert_reset(Sock2, 2000),
        ?assertEqual(2, get_counter(Config, ?COUNTER_RATE_LIMITED_TARPIT)),
        ?assert(get_counter(Config, ?COUNTER_SYS_LIMIT) >= 1)
    after
        meck:unload(AcceptMod),
        stop(Server)
    end.

%% The holder may reset a socket that is already closed, for example after
%% its acceptor exited. That must not crash the holder.
t_tarpit_reset_closed_socket(Config) ->
    AcceptMod = proplists:get_value(accept_mod, Config),
    Sock = closed_socket(AcceptMod),
    Was = application:get_env(esockd, socket_fast_close_method),
    try
        lists:foreach(
          fun(Method) ->
                  ok = application:set_env(esockd, socket_fast_close_method, Method),
                  ?assertEqual(ok, AcceptMod:reset_close(Sock))
          end,
          [default, nolinger])
    after
        case Was of
            {ok, V} -> application:set_env(esockd, socket_fast_close_method, V);
            undefined -> application:unset_env(esockd, socket_fast_close_method)
        end
    end.

closed_socket(esockd_accept_inet) ->
    {ok, Sock} = gen_tcp:listen(0, []),
    ok = gen_tcp:close(Sock),
    Sock;
closed_socket(esockd_accept_socket) ->
    {ok, Sock} = socket:open(inet, stream, tcp),
    ok = socket:close(Sock),
    Sock.

t_tarpit_auto_size(_Config) ->
    ?assertEqual(500, esockd_tarpit:auto_size(100, 5000)),
    %% Rounded up: 0.1 connection/s for 5 s.
    ?assertEqual(1, esockd_tarpit:auto_size(0.1, 5000)),
    ?assertEqual(0, esockd_tarpit:auto_size(0, 5000)),
    Cap = esockd:ulimit() div 10,
    ?assertEqual(Cap, esockd_tarpit:auto_size(Cap * 10, 1000)),
    ?assertError(function_clause, esockd_tarpit:auto_size(-1, 5000)),
    ?assertError(function_clause, esockd_tarpit:auto_size(100, 0)).

t_tarpit_check_options(_Config) ->
    Check = fun(Opts) -> esockd_acceptor_sup:check_options(tcp, Opts) end,
    ok = Check([]),
    ok = Check([{tarpit, #{size => 0, delay => 1}}]),
    ok = Check([{tarpit, #{size => 100, delay => 5000}}]),
    lists:foreach(
      fun(Bad) ->
              ?assertMatch({error, #{error := invalid_tarpit}},
                           Check([{tarpit, Bad}]))
      end,
      [#{size => 1}, #{delay => 1}, #{size => -1, delay => 1},
       #{size => 1, delay => 0}, #{size => 1, delay => 1, x => 1}, {1, 1}]),
    ?assertMatch({error, #{error := invalid_tarpit}},
                 esockd_acceptor_sup:check_options(
                   tcpsocket, [{tarpit, #{size => 1}}])).

%% Failed to spawn new connection process
t_error_when_spawn(Config) ->
    Port = ?PORT,
    Opts = #{start_connection_result => {error, overloaded}},
    Server = start(Port, no_rate_limit(), Opts, Config),
    {ok, Sock1} = connect(Port),
    try
        ok = wait_for_counter(Config, ?COUNTER_OVERLOADED, 1, 2000),
        disconnect(Sock1)
    after
        stop(Server)
    end.

%% Failed to tune the socket opts
t_einval(Config) ->
    Port = ?PORT,
    Opts = #{tune_fun => {fun(_, _) -> {error, einval} end, []}},
    Server = start(Port, no_rate_limit(), Opts, Config),
    {ok, Sock1} = connect(Port),
    try
        ok = wait_for_counter(Config, ?COUNTER_EARLY, 1, 2000),
        ?assertEqual(0, get_counter(Config, ?COUNTER_OTHER_REASONS)),
        disconnect(Sock1)
    after
        stop(Server)
    end.

%% Failed to tune the socket opts for a reason that is not a socket error
t_tune_fun_other_error(Config) ->
    Port = ?PORT,
    Opts = #{tune_fun => {fun(_, _) -> {error, unknown} end, []}},
    Server = start(Port, no_rate_limit(), Opts, Config),
    {ok, Sock1} = connect(Port),
    try
        ok = wait_for_counter(Config, ?COUNTER_OTHER_REASONS, 1, 2000),
        ?assertEqual(0, get_counter(Config, ?COUNTER_EARLY)),
        disconnect(Sock1)
    after
        stop(Server)
    end.

%% The socket is closed before the connection process is started
t_closed_early(Config) ->
    lists:foreach(
      fun(Reason) ->
              Port = ?PORT,
              Opts = #{start_connection_result => {error, Reason}},
              Server = start(Port, no_rate_limit(), Opts, Config),
              {ok, Sock1} = connect(Port),
              try
                  ok = wait_for_counter(Config, ?COUNTER_EARLY, 1, 2000),
                  ?assertEqual(0, get_counter(Config, ?COUNTER_OTHER_REASONS)),
                  disconnect(Sock1)
              after
                  stop(Server),
                  reset_counter(Config, ?COUNTER_EARLY)
              end
      end, [econnreset, enotconn, einval, closed]).

%% The peer address is denied by the access rules
t_forbidden(Config) ->
    Port = ?PORT,
    Opts = #{start_connection_result => {error, forbidden}},
    Server = start(Port, no_rate_limit(), Opts, Config),
    {ok, Sock1} = connect(Port),
    try
        ok = wait_for_counter(Config, ?COUNTER_FORBIDDEN, 1, 2000),
        ?assertEqual(0, get_counter(Config, ?COUNTER_OTHER_REASONS)),
        disconnect(Sock1)
    after
        stop(Server)
    end.

%% It not possible to trigger a real emfile error while keeping
%% the Erlang VM healthy (test case may need to write files etc),
%% so we use meck to simulate one.
t_sys_limit(Config) ->
    AcceptMod = proplists:get_value(accept_mod, Config),
    meck:new(AcceptMod, [passthrough, no_history]),
    meck:expect(AcceptMod, async_accept, fun(_) -> {error, emfile} end),
    Port = ?PORT,
    Server = start(Port, no_rate_limit(), #{}, Config),
    try
        %% acceptor to enter suspending state after started
        %% because async_accept always returns {error, emfile}
        ok = wait_for_counter(Config, ?COUNTER_SYS_LIMIT, {'>', 1}, 2000),
        %% now unload the mock
        meck:unload(AcceptMod),
        %% this one is closed immediately because acceptor is still in suspending state
        {ok, Sock1} = connect(Port),
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED, 1, 2000),
        ok = assert_socket_disconnected(Sock1),
        %% allow acceptor to exit from suspending state
        timer:sleep(1000),
        {ok, Sock2} = connect(Port),
        ok = wait_for_counter(Config, ?COUNTER_ACCEPTED, 1, 2000),
        ok = assert_socket_connected(Sock2),
        disconnect(Sock2)
    after
        stop(Server)
    end.

%% Failed to spawn new connection process
t_max_limit(Config) ->
    Port = ?PORT,
    Opts = #{start_connection_result => {error, ?ERROR_MAXLIMIT}},
    Server = start(Port, no_rate_limit(), Opts, Config),
    {ok, Sock1} = connect(Port),
    try
        ok = wait_for_counter(Config, ?COUNTER_MAX_LIMIT, 1, 2000),
        disconnect(Sock1)
    after
        stop(Server)
    end.

t_close_listener_socket_cause_acceptor_stop(Config) ->
    Port = ?PORT,
    AcceptMod = proplists:get_value(accept_mod, Config),
    #{acceptor := Acceptor, lsock := LSock} = start(Port, no_rate_limit(), #{}, Config),
    Mref = monitor(process, Acceptor),
    unlink(Acceptor),
    {ok, Sock1} = connect(Port),
    ok = assert_socket_connected(Sock1),
    AcceptMod:fast_close(LSock),
    receive
        {'DOWN', Mref, process, Acceptor, Reason} ->
            ?assertEqual(normal, Reason)
    after
        1000 ->
            error("Acceptor process did not terminate in time")
    end,
    %% A closed listen socket is not a closed client socket.
    ?assertEqual(0, get_counter(Config, ?COUNTER_EARLY)),
    ?assertEqual(0, get_counter(Config, ?COUNTER_OTHER_REASONS)),
    receive
        {listen_socket_closed, Acceptor} ->
            ok
    after
        1000 ->
            error("No listen socket closed notification")
    end,
    receive
        {tcp_closed, Sock1} ->
            ok
    after
        1000 ->
            error("Client socket still connected")
    end.

%% The exit signal of a socket that the acceptor closed can arrive after
%% fast_close/1 stops waiting for it. The acceptor drops it without a log.
t_late_port_exit_not_logged(Config) ->
    Port = ?PORT,
    #{acceptor := Acceptor} = Server = start(Port, no_rate_limit(), #{}, Config),
    HandlerId = ?FUNCTION_NAME,
    ok = logger:add_handler(HandlerId, ?MODULE, #{config => #{pid => self()}}),
    try
        {ok, ClosedPort} = gen_tcp:listen(0, []),
        ok = gen_tcp:close(ClosedPort),
        Acceptor ! {'EXIT', ClosedPort, normal},
        %% Any other message is still logged. Its log event shows that the
        %% acceptor has handled the exit message sent before it.
        Acceptor ! unexpected_message,
        receive
            {log, #{msg := {report, #{msg := "esockd_acceptor_fsm_unhandled_event",
                                      event_content := Content}}}} ->
                ?assertEqual(unexpected_message, Content)
        after
            1000 ->
                error("No log event for the unexpected message")
        end,
        ?assert(is_process_alive(Acceptor)),
        {ok, Sock} = connect(Port),
        ok = wait_for_counter(Config, ?COUNTER_ACCEPTED, 1, 2000),
        disconnect(Sock)
    after
        logger:remove_handler(HandlerId),
        stop(Server)
    end.

%% logger handler callback, used by t_late_port_exit_not_logged
log(LogEvent, #{config := #{pid := Pid}}) ->
    Pid ! {log, LogEvent},
    ok.

assert_socket_connected(Sock) ->
    ok = inet:setopts(Sock, [{active, true}]),
    receive
        Msg ->
            error({unexpected, Msg})
    after
        10 ->
            ok
    end.

assert_socket_disconnected(Sock) ->
    ok = inet:setopts(Sock, [{active, true}]),
    receive
        {tcp_closed, Sock} ->
            ok;
        Other ->
            error({unexpected, Other})
    after
        100 ->
            error(timeout)
    end,
    ok.

assert_no_close(Sock, Window) ->
    receive
        {tcp_closed, Sock} = Msg -> ct:fail({closed_early, Msg});
        {tcp_error, Sock, _} = Msg -> ct:fail({closed_early, Msg})
    after
        Window -> ok
    end.

%% The client socket must have show_econnreset set.
assert_reset(Sock, Timeout) ->
    receive
        {tcp_error, Sock, econnreset} -> ok;
        {tcp_closed, Sock} -> ct:fail({closed_without_reset, Sock})
    after
        Timeout -> ct:fail({no_reset, Sock})
    end.

stop_if_alive(Pid) ->
    try
        gen_server:stop(Pid)
    catch
        exit:noproc -> ok
    end.

disconnect(Socket) ->
    port_close(Socket),
    ok.

%% no connection can get through
pause_then_allow(Pause) ->
    #{module => ?MODULE,
      name => pause_then_allow,
      current => pause,
      next => allow,
      pause => Pause
     }.

%% make a no-limit limiter
no_rate_limit() ->
    #{module => ?MODULE, name => no_rate_limit}.

%% limiter callback
consume(_Token, #{name := pause_then_allow} = Limiter) ->
    case Limiter of
        #{current := pause} ->
            {pause, maps:get(pause, Limiter), Limiter#{current => allow}};
        #{current := allow} ->
            {ok, Limiter}
    end;
consume(_Token, #{name := no_rate_limit} = Limiter) ->
    {ok, Limiter}.

now_ts() -> erlang:system_time(millisecond).

get_counter(Config, Index) ->
    counters:get(proplists:get_value(counters, Config), Index).

reset_counter(Config, Index) ->
    counters:put(proplists:get_value(counters, Config), Index, 0).

wait_for_counter(Config, Index, Count, Timeout) ->
    Counters = proplists:get_value(counters, Config),
    Now = now_ts(),
    Deadline = Now + Timeout,
    try
        do_wait_for_counter(Counters, Index, Count, Deadline)
    catch throw : ok ->
              ok
    end.

do_wait_for_counter(Counters, Index, Count, Deadline) ->
    Value = counters:get(Counters, Index),
    Match = match_counter(Value, Count),
    case Match of
        true ->
            throw(ok);
        false ->
            ok;
        error ->
            error(#{cause => counter_exceeded_expect,
                    expected => Count,
                    counter_index => Index,
                    got => Value})
    end,
    case now_ts() > Deadline of
        true ->
            error(#{cause => timeout,
                    expected => Count,
                    counter_index=> Index,
                    got => Value});
        false ->
            timer:sleep(100),
            do_wait_for_counter(Counters, Index, Count, Deadline)
    end.

match_counter(Value, {'>', Expect}) ->
    Value > Expect;
match_counter(Value, Value) ->
    true;
match_counter(Value, Expect) when Value > Expect ->
    error;
match_counter(_Vlaue, _Expect) ->
    false.

%% dummy callback to start connection
start_connection(Opts, _Sock, _UpgradeFuns) ->
    case maps:get(start_connection_result, Opts, undefined) of
        undefined ->
            {ok, pid};
        Other ->
            Other
    end.
