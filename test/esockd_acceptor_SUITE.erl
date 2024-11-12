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

-module(esockd_acceptor_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("esockd.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(PORT, 30000 + ?LINE).
-define(COUNTER_ACCPETED, 1).
-define(COUNTER_OVERLOADED, 2).
-define(COUNTER_RATE_LIMITED, 3).
-define(COUNTER_SYS_LIMIT, 4).
-define(COUNTER_OTHER_REASONS, 5).
-define(COUNTER_LAST, 10).

counter_tag_to_index(accepted) -> ?COUNTER_ACCPETED;
counter_tag_to_index(closed_sys_limit) -> ?COUNTER_SYS_LIMIT;
counter_tag_to_index(closed_overloaded) -> ?COUNTER_OVERLOADED;
counter_tag_to_index(closed_rate_limited) -> ?COUNTER_RATE_LIMITED;
counter_tag_to_index(closed_other_reasons) -> ?COUNTER_OTHER_REASONS.

all() -> esockd_ct:all(?MODULE).

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    Counters = counters:new(?COUNTER_LAST, []),
    meck:new(esockd_server, [passthrough, no_history, no_sticky]),
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
    SockOpts = [binary,
                {active, false},
                {reuseaddr, true},
                {nodelay, true},
                {backlog, maps:get(backlog, Opts, 1024)}],
    {ok, ListenSocket} = gen_tcp:listen(PortNumber, SockOpts),
    TuneFun = maps:get(tune_fun, Opts, esockd_acceptor_sup:tune_socket_fun(tcp, [])),
    StartConn = {fun ?MODULE:start_connection/3, [Opts]},
    {ok, AccPid} = esockd_acceptor:start_link(tcp, PortNumber, StartConn, TuneFun, _UpFuns = [], Limiter, ListenSocket),
    #{lsock => ListenSocket, acceptor => AccPid}.

stop(#{lsock := ListenSocket, acceptor := AccPid}) ->
    ok = gen_statem:stop(AccPid),
    gen_tcp:close(ListenSocket),
    ok.

connect(Port) ->
    connect(Port, 1000, #{}).

connect(Port, Timeout, Opts0) ->
    Opts = [binary,
            {active, maps:get(active, Opts0, false)},
            {nodelay, true}],
    gen_tcp:connect("localhost", Port, Opts, Timeout).

%% This is the very basic test, if this fails, nothing elese matters.
t_normal(Config) ->
    Port = ?PORT,
    Server = start(Port, no_limit()),
    {ok, ClientSock} = connect(Port),
    try
        ok = wait_for_counter(Config, ?COUNTER_ACCPETED, 1, 2000)
    after
        disconnect(ClientSock),
        stop(Server)
    end.

t_rate_limitted(Config) ->
    Port = ?PORT,
    Pause = 200,
    Server = start(Port, pause_then_allow(Pause)),
    try
        Count = 10,
        Socks = lists:map(fun(_) ->
                                  {ok, Sock} = connect(Port, 1000, #{active => true}),
                                  Sock
                          end, lists:seq(1, Count)),
        lists:foreach(fun(Sock) ->
                              receive
                                  {tcp_closed, Sock} ->
                                      ok;
                                  Other ->
                                      ct:fail({unexpected, Other})
                              end
                      end, Socks),
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED, Count, 2000),
        timer:sleep(Pause),
        {ok, Sock2} = connect(Port),
        ok = wait_for_counter(Config, ?COUNTER_ACCPETED, 1, 2000),
        disconnect(Sock2)
    after
        stop(Server)
    end.

%% Failed to spawn new connection process
t_error_when_spawn(Config) ->
    Port = ?PORT,
    Server = start(Port, no_limit(), #{start_connection_result => {error, overloaded}}),
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
    Server = start(Port, no_limit(), #{tune_fun => {fun(_) -> {error, einval} end, []}}),
    {ok, Sock1} = connect(Port),
    try
        ok = wait_for_counter(Config, ?COUNTER_OTHER_REASONS, 1, 2000),
        disconnect(Sock1)
    after
        stop(Server)
    end.

%% It not possible to trigger a real emfile error while keeping
%% the Erlang VM healthy (test case may need to write files etc),
%% so we use meck to simulate one.
t_sys_limit(Config) ->
    meck:new(prim_inet, [passthrough, no_history, unstick]),
    meck:expect(prim_inet, async_accept, fun(_, _) -> {error, emfile} end),
    Port = ?PORT,
    Server = start(Port, no_limit()),
    try
        %% acceptor to enter suspending state after started
        %% because async_accept always returns {error, emfile}
        ok = wait_for_counter(Config, ?COUNTER_SYS_LIMIT, {'>', 1}, 2000),
        %% now unload the mock
        meck:unload(prim_inet),
        %% this one is closed immediately because acceptor is still in suspending state
        {ok, Sock1} = connect(Port),
        ok = wait_for_counter(Config, ?COUNTER_RATE_LIMITED, 1, 2000),
        ok = assert_socket_disconnected(Sock1),
        %% allow acceptor to exit from suspending state
        timer:sleep(1000),
        {ok, Sock2} = connect(Port),
        ok = wait_for_counter(Config, ?COUNTER_ACCPETED, 1, 2000),
        ok = assert_socket_connected(Sock2),
        disconnect(Sock2)
    after
        stop(Server)
    end.

t_close_listener_socket_cause_acceptor_stop(_Config) ->
    Port = ?PORT,
    #{acceptor := Acceptor, lsock := LSock} = start(Port, no_limit()),
    Mref = monitor(process, Acceptor),
    unlink(Acceptor),
    unlink(LSock),
    {ok, Sock1} = connect(Port),
    ok = assert_socket_connected(Sock1),
    exit(LSock, kill),
    receive
        {'DOWN', Mref, process, Acceptor, Reason} ->
            ?assertEqual(normal, Reason)
    after
        1000 ->
            error(timeout)
    end,
    receive
        {tcp_closed, Sock1} ->
            ok
    after
        1000 ->
            error(timeout)
    end.

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
no_limit() ->
    #{module => ?MODULE, name => no_limit}.

%% limiter callback
consume(_Token, #{name := pause_then_allow} = Limiter) ->
    case Limiter of
        #{current := pause} ->
            {pause, maps:get(pause, Limiter), Limiter#{current => allow}};
        #{current := allow} ->
            {ok, Limiter}
    end;
consume(_Token, #{name := no_limit} = Limiter) ->
    {ok, Limiter}.

now_ts() -> erlang:system_time(millisecond).

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
