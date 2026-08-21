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

-module(esockd_limiter_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").

all() -> esockd_ct:all(?MODULE).

%%--------------------------------------------------------------------
%% Test cases for limiter
%%--------------------------------------------------------------------

t_crud_limiter(_) ->
    {ok, _} = esockd_limiter:start_link(),
    ok = esockd_limiter:create(bucket1, 10),
    ok = esockd_limiter:create(bucket2, 1000, 10),
    #{name     := bucket1,
      capacity := 10,
      interval := 1,
      tokens   := 10
     } = esockd_limiter:lookup(bucket1),
    #{name     := bucket2,
      capacity := 1000,
      interval := 10,
      tokens   := 1000
     } = esockd_limiter:lookup(bucket2),
    Limiters = esockd_limiter:get_all(),
    ?assertEqual(2, length(Limiters)),
    ok = esockd_limiter:delete(bucket1),
    ok = esockd_limiter:delete(bucket2),
    timer:sleep(500), %% wait for deleting
    undefined = esockd_limiter:lookup(bucket1),
    undefined = esockd_limiter:lookup(bucket2),
    ok = esockd_limiter:stop().

t_twice_create(_) ->
    {ok, _} = esockd_limiter:start_link(),
    ok = esockd_limiter:create(bucket1, 10),
    #{name     := bucket1,
      capacity := 10,
      interval := 1,
      tokens   := 10
     } = esockd_limiter:lookup(bucket1),
    {5, 0} = esockd_limiter:consume(bucket1, 5),
    ok = esockd_limiter:create(bucket1, 100),
    #{name     := bucket1,
      capacity := 100,
      interval := 1,
      tokens   := 100
     } = esockd_limiter:lookup(bucket1),
    ok = esockd_limiter:stop().

t_consume(_) ->
    {ok, _} = esockd_limiter:start_link(),
    ok = esockd_limiter:create(bucket, 10, 2),
    #{name     := bucket,
      capacity := 10,
      interval := 2,
      tokens   := 10
     } = esockd_limiter:lookup(bucket),
    {9, 0} = esockd_limiter:consume(bucket),
    #{tokens := 9} = esockd_limiter:lookup(bucket),
    {5, 0} = esockd_limiter:consume(bucket, 4),
    #{tokens := 5} = esockd_limiter:lookup(bucket),
    {0, PauseTime1} = esockd_limiter:consume(bucket, 5),
    ?assertEqual(PauseTime1 =< 2000 andalso PauseTime1 >= 1900, true),

    {-1, PauseTime2} = esockd_limiter:consume(bucket, 1),
    %% borrow token from next interval, but havn't exhausted the whole next interval
    %% pause to next interval is enough
    ?assertEqual(PauseTime2 =< 2000 andalso PauseTime2 >= 1900, true),
    #{tokens := -1} = esockd_limiter:lookup(bucket),

    ok = timer:sleep(1000),
    #{tokens := -1} = esockd_limiter:lookup(bucket),

    ok = timer:sleep(1020),
    #{tokens := 9} = esockd_limiter:lookup(bucket),

    {4, 0} = esockd_limiter:consume(bucket, 5),
    #{tokens := 4} = esockd_limiter:lookup(bucket),

    {-11, PauseTime3} = esockd_limiter:consume(bucket, 15),
    #{tokens := -11} = esockd_limiter:lookup(bucket),
    %% borrow token from next interval, and exhausted the whole next interval
    %% should pause for 2 intervals
    ?assertEqual(PauseTime3 =< 4000 andalso PauseTime3 >= 3900, true),
    ok = timer:sleep(2100),
    %% after 1 interval
    #{tokens := -1} = esockd_limiter:lookup(bucket),
    ok = timer:sleep(2100),
    #{tokens := 9} = esockd_limiter:lookup(bucket),
    ok = timer:sleep(2100),
    #{tokens := 10} = esockd_limiter:lookup(bucket),

    {1, 0} = esockd_limiter:consume(notexisted, 1),
    ok = esockd_limiter:stop().

t_strict_lasttime_update(_) ->
    Milliseconds = 1000,
    {ok, _} = esockd_limiter:start_link(),
    ok = esockd_limiter:create(bucket, 10, 2),
    #{name     := bucket,
      capacity := 10,
      interval := Interval,
      tokens   := 10,
      lasttime := L0
     } = esockd_limiter:lookup(bucket),

    ok = timer:sleep(Milliseconds + 100),
    #{lasttime := L1} = esockd_limiter:lookup(bucket),
    ?assertEqual(L1, L0),

    ok = timer:sleep(Milliseconds + 100),
    #{lasttime := L2} = esockd_limiter:lookup(bucket),
    ?assertEqual(L2, L1 + (Interval * Milliseconds)),

    ok = timer:sleep(2 * (Milliseconds + 100)),
    #{lasttime := L3} = esockd_limiter:lookup(bucket),
    ?assertEqual(L3, L2 + (Interval * Milliseconds)).

t_concurrent_consume(_) ->
    {ok, _} = esockd_limiter:start_link(),
    ConnRate = 10000,
    ok = esockd_limiter:create(bucket, ConnRate, 1),
    Parent = self(),
    Consumer = fun() ->
                   {X, P} = esockd_limiter:consume(bucket, 1),
                   Parent ! {consumer, X, P}
               end,
    Collect = fun _F(0, Acc) -> Acc;
                  _F(N, Acc) ->
                      _F(N-1, [receive M -> M after 1000 -> error(timeout) end | Acc])
              end,
    %% Case1: N*1
    [spawn(Consumer) || _ <- lists:seq(1, ConnRate)],
    ReceviedTokens = Collect(ConnRate, []),
    ct:pal("~p~n", [ReceviedTokens]),
    ?assertEqual(ConnRate, length(lists:usort(ReceviedTokens))),

    %% Case2: N/10 * N
    ok = esockd_limiter:create(bucket, ConnRate, 1),
    [spawn(fun() ->
         [Consumer() || _ <- lists:seq(1, ConnRate div 10)]
     end) || _ <- lists:seq(1, 10)],
    ReceviedTokens2 = Collect(ConnRate, []),
    ct:pal("~p~n", [ReceviedTokens2]),
    ?assertEqual(ConnRate, length(lists:usort(ReceviedTokens2))).

%% Increase a bucket's interval via `update/3` must neither starve other buckets
%% (regression: the shared countdown timer used to be stretched by ~Interval
%% seconds, freezing a 1s conn-rate limiter) nor stall the limiter permanently
%% (regression: an over-due tick computed a non-positive schedule, so no timer
%% was armed again and no bucket ever refilled).
t_update_larger_interval_no_starvation_no_stall(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        ok = esockd_limiter:create(fast, 100, 1),
        ok = esockd_limiter:create(slow, 1000, 1),
        timer:sleep(300),
        drain(fast, 100),
        ok = update(slow, 1000, 10),
        %% `fast` must keep refilling on its ~1s cadence, three cycles in a row.
        ok = expect_tokens(fast, 100, 3000),
        drain(fast, 100),
        ok = expect_tokens(fast, 100, 3000),
        drain(fast, 100),
        ok = expect_tokens(fast, 100, 3000)
    after
        esockd_limiter:stop()
    end.

%% A long-interval bucket coexisting with a short-interval one (no update) must
%% not slow the short-interval one down in steady state.
t_steady_state_multiple_buckets_independent(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        ok = esockd_limiter:create(fast, 100, 1),
        ok = esockd_limiter:create(slow, 1000, 10),
        timer:sleep(300),
        drain(fast, 100),
        ok = expect_tokens(fast, 100, 3000),
        drain(fast, 100),
        ok = expect_tokens(fast, 100, 3000),
        %% `slow` keeps its config and stays usable.
        #{tokens := 1000, interval := 10} = esockd_limiter:lookup(slow)
    after
        esockd_limiter:stop()
    end.

%% After `update` to a smaller interval the bucket must refill on the new,
%% faster cadence.
t_update_smaller_interval(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        ok = esockd_limiter:create(b, 100, 10),
        ok = update(b, 100, 1),
        timer:sleep(300),
        drain(b, 100),
        ok = expect_tokens(b, 100, 3000)
    after
        esockd_limiter:stop()
    end.

%% A capacity-only update (same interval) resets the bucket and it keeps working.
t_update_capacity_only_same_interval(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        ok = esockd_limiter:create(b, 100, 1),
        ok = update(b, 200, 1),
        #{tokens := 200} = esockd_limiter:lookup(b),
        {199, 0} = esockd_limiter:consume(b, 1),
        timer:sleep(300),
        drain(b, 199),
        ok = expect_tokens(b, 200, 3000)
    after
        esockd_limiter:stop()
    end.

%% Over-consuming a burst many times the capacity must produce staggered pauses
%% that stay bounded (borrowed from a finite number of future cycles), not a
%% runaway pause value.
t_burst_borrow_pause_bounded(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        Capacity = 100,
        ok = esockd_limiter:create(b, Capacity, 1),
        Pauses = [P || {_, P} <- [esockd_limiter:consume(b, 1)
                                   || _ <- lists:seq(1, Capacity * 20)]],
        MaxPause = lists:max(Pauses),
        %% borrowed from at most ~20 future cycles, so < 21s + slack
        ?assert(MaxPause < 21 * 1000 + 1000),
        %% exhausted consumers are staggered, not all paused equally
        ?assert(length(lists:usort(Pauses)) > 1),
        %% no refill happens mid-burst, the bucket is left in debt
        #{tokens := T} = esockd_limiter:lookup(b),
        ?assert(T =< 0)
    after
        esockd_limiter:stop()
    end.

%% The acceptor passes `undefined` as the bucket name when no max_conn_rate is
%% configured; consume must be a cheap no-op and never raise.
t_consume_undefined_bucket(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        {1, 0} = esockd_limiter:consume(undefined, 1),
        {1, 0} = esockd_limiter:consume(nonexistent_bucket, 1)
    after
        esockd_limiter:stop()
    end.

%% `get_all/1` must not crash when a bucket row is observed without its tokens
%% row (a concurrent delete removes the bucket row first). Regression for the
%% `ets:lookup_element` badarg in `tokens/1`.
t_get_all_no_crash_with_orphan_bucket(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        ok = esockd_limiter:create(real_bucket, 100, 1),
        %% Simulate the mid-delete state: bucket row present, tokens row gone.
        ets:insert(esockd_limiter, {{bucket, orphan}, 100, 1, 0}),
        Buckets = esockd_limiter:get_all(),
        ?assertMatch([#{name := orphan, tokens := 0}],
                     [B || B = #{name := orphan} <- Buckets]),
        ets:delete(esockd_limiter, {bucket, orphan})
    after
        esockd_limiter:stop()
    end.

%% create/update/delete churn must not leak state or break the countdown.
t_create_update_delete_churn(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        ok = esockd_limiter:create(c1, 10, 1),
        ok = esockd_limiter:create(c2, 20, 2),
        ok = update(c1, 30, 1),
        #{tokens := 30} = esockd_limiter:lookup(c1),
        ok = esockd_limiter:delete(c1),
        ok = esockd_limiter:delete(c2),
        timer:sleep(100),
        undefined = esockd_limiter:lookup(c1),
        undefined = esockd_limiter:lookup(c2),
        %% re-create after delete: the countdown drives it again
        ok = esockd_limiter:create(c1, 40, 1),
        #{tokens := 40} = esockd_limiter:lookup(c1),
        {39, 0} = esockd_limiter:consume(c1, 1),
        drain(c1, 39),
        ok = expect_tokens(c1, 40, 3000),
        ok = esockd_limiter:delete(c1),
        timer:sleep(100),
        undefined = esockd_limiter:lookup(c1)
    after
        esockd_limiter:stop()
    end.

%% Deleting a bucket while consumers are paused on it must make subsequent
%% consumes pause-free no-ops.
t_delete_while_active(_) ->
    {ok, _} = esockd_limiter:start_link(),
    try
        ok = esockd_limiter:create(b, 1, 1),
        {0, Pause} = esockd_limiter:consume(b, 1),
        ?assert(Pause > 0),
        ok = esockd_limiter:delete(b),
        timer:sleep(100),
        {1, 0} = esockd_limiter:consume(b, 1),
        {1, 0} = esockd_limiter:consume(b, 1)
    after
        esockd_limiter:stop()
    end.

t_handle_call(_) ->
    {reply, ignore, state} = esockd_limiter:handle_call(req, '_From', state).

t_handle_cast(_) ->
  {noreply, state} = esockd_limiter:handle_cast(msg, state).

t_handle_info(_) ->
    {noreply, state} = esockd_limiter:handle_info(info, state).

t_code_change(_) ->
    {ok, state} = esockd_limiter:code_change('OldVsn', state, 'Extra').

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

%% Master removed the `esockd_limiter:update/3` API; emulate its (5.8.x)
%% semantics for the regression tests above: refresh the bucket rows while
%% keeping the countdown at min(Interval, OldCountdown), so the countdown can
%% reach 1 well before LastTime + Interval * 1000.
update(Name, Capacity, Interval) ->
    true = ets:insert(esockd_limiter, {{tokens, Name}, Capacity}),
    true = ets:insert(esockd_limiter,
                      {{bucket, Name}, Capacity, Interval, erlang:system_time(millisecond)}),
    sys:replace_state(
        esockd_limiter,
        fun(State = #{countdown := Countdown}) ->
            Old = maps:get({bucket, Name}, Countdown, Interval),
            State#{countdown := maps:put({bucket, Name}, erlang:min(Interval, Old), Countdown)}
        end),
    ok.

drain(Name, Tokens) ->
    lists:foreach(fun(_) -> esockd_limiter:consume(Name, 1) end, lists:seq(1, Tokens)).

%% Wait until the bucket holds exactly `Tokens` tokens (a refill fills it to its
%% capacity). `Timeout` is in milliseconds.
expect_tokens(_Name, _Tokens, Timeout) when Timeout =< 0 ->
    #{tokens := T} = esockd_limiter:lookup(_Name),
    ct:fail("timeout waiting for ~p tokens, got ~p", [_Tokens, T]);
expect_tokens(Name, Tokens, Timeout) ->
    #{tokens := T} = esockd_limiter:lookup(Name),
    case T of
        Tokens -> ok;
        _ ->
            timer:sleep(50),
            expect_tokens(Name, Tokens, Timeout - 50)
    end.

