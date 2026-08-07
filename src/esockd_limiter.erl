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

%% @doc A simple ets-based rate limit server.
-module(esockd_limiter).

-behaviour(gen_server).

-export([ start_link/0
        , get_all/0
        , stop/0
        ]).

-export([ create/2
        , create/3
        , update/2
        , update/3
        , lookup/1
        , consume/1
        , consume/2
        , delete/1
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-type(bucket_name() :: term()).

-type(bucket_info() :: #{name      => bucket_name(),
                         capacity  => pos_integer(),
                         interval  => pos_integer(),
                         tokens    => pos_integer(),
                         lasttime  => integer()
                        }).

-export_type([bucket_info/0]).

-define(TAB, ?MODULE).
-define(SERVER, ?MODULE).
-define(MAX_INTERVAL, 86400000).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

-spec(start_link() -> {ok, pid()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(get_all() -> list(bucket_info())).
get_all() ->
    [bucket_info(Bucket) || Bucket = {{bucket, _}, _, _, _} <- ets:tab2list(?TAB)].

bucket_info({{bucket, Name}, Capacity, Interval, LastTime}) ->
    #{name     => Name,
      capacity => Capacity,
      interval => Interval,
      tokens   => tokens(Name),
      lasttime => LastTime
     }.

tokens(Name) ->
    case ets:lookup(?TAB, {tokens, Name}) of
        [] -> 0; %% the bucket is being deleted concurrently; report a stale 0 instead of crashing
        [{_, Tokens}] -> Tokens
    end.

-spec(stop() -> ok).
stop() ->
    gen_server:stop(?SERVER).

-spec(create(bucket_name(), pos_integer()) -> ok).
create(Name, Capacity) when is_integer(Capacity), Capacity > 0 ->
    create(Name, Capacity, 1).

-spec(create(bucket_name(), pos_integer(), pos_integer()) -> ok).
create(Name, Capacity, Interval) when is_integer(Capacity), Capacity > 0,
                                      is_integer(Interval), Interval > 0 ->
    gen_server:call(?SERVER, {create, Name, Capacity, Interval}).

-spec(update(bucket_name(), pos_integer()) -> ok).
update(Name, Capacity) when is_integer(Capacity), Capacity > 0 ->
    create(Name, Capacity, 1).

-spec(update(bucket_name(), pos_integer(), pos_integer()) -> ok).
update(Name, Capacity, Interval) when is_integer(Capacity), Capacity > 0,
                                      is_integer(Interval), Interval > 0 ->
    gen_server:call(?SERVER, {update, Name, Capacity, Interval}).

-spec(lookup(bucket_name()) -> undefined | bucket_info()).
lookup(Name) ->
    case ets:lookup(?TAB, {bucket, Name}) of
        [] -> undefined;
        [Bucket] -> bucket_info(Bucket)
    end.

-spec(consume(bucket_name())
      -> {Remaining :: integer(), PasueMillSec :: integer()}).
consume(Name) ->
    consume(Name, 1).

-spec(consume(bucket_name(), pos_integer()) -> {integer(), integer()}).
consume(Name, Tokens) when is_integer(Tokens), Tokens > 0 ->
    try ets:update_counter(?TAB, {tokens, Name}, {2, -Tokens}) of
        Remaining when Remaining > 0 ->
            %% enough tokens, no need to pause
            {Remaining, 0};
        Remaining ->
            %% 0 or negative, not enough tokens. But it has indeed been consumed,
            %% which means the token is borrowed from the future. We need to pause to that time.
            {Remaining, pause_time(Name, time_now(), Remaining)}
    catch
        error:badarg -> {1, 0}
    end.

%% @private
-spec pause_time(bucket_name(), pos_integer(), neg_integer() | 0) -> pos_integer().
pause_time(Name, Now, Remaining) ->
    case ets:lookup(?TAB, {bucket, Name}) of
        [] -> 1000; %% Pause 1 second if the bucket is deleted.
        [{_Bucket, Capacity, Interval, LastTime}] ->
            %% Remaining might negative or zero.
            %% In any case, this means that the token in this cycle has been exhausted,
            %% and the current caller must at least pause until the next Token generation cycle
            %% BorrowFrom = 1: token borrowed from next cycle
            %% BorrowFrom = 2: token borrowed from next next cycle
            %% ...etc
            %%
            %% AND NOTE:
            %% 1. The number of consumers is limited
            %% 2. The number of Tokens increased at a fixed rate
            %% Therefore, consumers are always paused in turn, and the `Pause` value does
            %% not increase indefinitely.
            BorrowFrom = (abs(Remaining) div Capacity) + 1,

            %% The `Now` might be slightly larger than `LastTime` due to concurrent access and
            %% function execution time.
            %% But we always take `LastTime` as the standard, because it always increases in fixed steps.
            %%
            %% In this case, the following `Pause` value might be zero or negative,
            %% We still consider it to be consuming tokens from the cycle before the `LastTime`.
            %% And since `LastTime` will be updated immediately, we pause for at least 1ms.
            PauseTime = LastTime + (BorrowFrom * Interval * 1000) - Now,
            max(1, PauseTime)
    end.

-spec(delete(bucket_name()) -> ok).
delete(Name) ->
    gen_server:cast(?SERVER, {delete, Name}).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    _ = ets:new(?TAB, [public, set, named_table, {write_concurrency, true}]),
    {ok, #{countdown => #{}, timer => undefined}}.

handle_call({create, Name, Capacity, Interval}, _From, State = #{countdown := Countdown}) ->
    true = ets:insert(?TAB, {{tokens, Name}, Capacity}),
    true = ets:insert(?TAB, {{bucket, Name}, Capacity, Interval, erlang:system_time(millisecond)}),
    NCountdown = maps:put({bucket, Name}, Interval, Countdown),
    {reply, ok, ensure_countdown_timer(State#{countdown := NCountdown})};

handle_call({update, Name, Capacity, Interval}, _From, State = #{countdown := Countdown}) ->
    BucketName = {bucket, Name},
    true = ets:insert(?TAB, {{tokens, Name}, Capacity}),
    true = ets:insert(?TAB, {BucketName, Capacity, Interval, erlang:system_time(millisecond)}),
    LastInterval = maps:get(BucketName, Countdown, ?MAX_INTERVAL),
    NewInterval = erlang:min(Interval, LastInterval),
    NewCountdown = maps:put(BucketName, NewInterval, Countdown),
    {reply, ok, ensure_countdown_timer(State#{countdown := NewCountdown})};

handle_call(Req, _From, State) ->
    error_logger:error_msg("Unexpected call: ~p", [Req]),
    {reply, ignore, State}.

handle_cast({delete, Name}, State = #{countdown := Countdown}) ->
    true = ets:delete(?TAB, {bucket, Name}),
    true = ets:delete(?TAB, {tokens, Name}),
    NCountdown = maps:remove({bucket, Name}, Countdown),
    {noreply, State#{countdown := NCountdown}};

handle_cast(Msg, State) ->
    error_logger:error_msg("Unexpected cast: ~p~n", [Msg]),
    {noreply, State}.

handle_info({timeout, Timer, countdown}, State = #{countdown := Countdown, timer := Timer}) ->
    Now = time_now(),
    {Countdown1, StrictNow} =
        maps:fold(
            fun(Key = {bucket, Name}, 1, {AccIn, _}) ->
                [{_Key, Capacity, Interval, LastTime}] = ets:lookup(?TAB, Key),
                    %% Intolerant function execution time deviation.
                    %% The `LastTime` value must be updated strictly in milliseconds using Interval * 1000.
                    %%
                    %% Taking this into account, `schedule_time/2` is used to calculate the time of the next update.
                    %% And the `StrictNow` value calculated from any bucket can be used
                    %% to calculate the duration of the timer.
                    %%
                    %% Bucket creation does not always coincide with the current timer period.
                    %% We accept a 1000ms deviation between `Now` and `StrictNow`,
                    %% it still correctly generates tokens according to the period on a second scale.
                    StrictNow = LastTime + Interval * 1000,

                    %% Generate tokens in interval, and the current tokens might be negative
                    %% (already borrowed by previous interval), add the Capacity value to it and
                    %% set an overflow threshold.
                    Incr = Threshold = SetValue = Capacity,
                    _ = ets:update_counter(?TAB, {tokens, Name}, {2, Incr, Threshold, SetValue}),
                    true = ets:update_element(?TAB, {bucket, Name}, {4, StrictNow}),

                    {AccIn#{Key => Interval}, StrictNow};
               (Key, C, {AccIn, StrictNow}) when C > 1 ->
                    {AccIn#{Key => C - 1}, StrictNow}
            end,
            {#{}, undefined},
            Countdown
        ),
    ScheduleTime = schedule_time(Now, StrictNow),
    NState = State#{countdown := Countdown1, timer := undefined},
    {noreply, ensure_countdown_timer(NState, ScheduleTime)};

handle_info(Info, State) ->
    error_logger:error_msg("Unexpected info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

time_now() ->
    erlang:system_time(millisecond).

%% The countdown ticks must fire roughly once per second: every bucket's
%% countdown is decremented once per tick, so a tick longer than 1s slows down
%% the token refill of every bucket.
%%
%% Two failure modes of the un-clamped `StrictNow + 1000 - Now` are avoided:
%%
%% 1. When a bucket is (re)configured via `update/3` with a larger interval, its
%%    countdown can reach 1 well before `LastTime + Interval * 1000`. The bucket
%%    then refills "early", pushing `StrictNow` far into the future. Since all
%%    buckets share a single timer, the next tick would be delayed by ~Interval
%%    seconds, starving every other bucket (e.g. a 1-second conn-rate limiter).
%%    Clamping the tick to at most 1s keeps other buckets refilling on time.
%%
%% 2. If a tick is processed more than 1s after its refill boundary, the formula
%%    becomes non-positive. `ensure_countdown_timer/2` only arms a timer for a
%%    positive duration, so the limiter would stall permanently. Clamping to at
%%    least 1ms guarantees a timer is always armed, letting the limiter recover
%%    from a delayed tick.
schedule_time(_Now, undefined) ->
    1000;
schedule_time(Now, StrictNow) ->
    max(1, min(1000, StrictNow + 1000 - Now)).

ensure_countdown_timer(State = #{timer := undefined}) ->
    ensure_countdown_timer(State, timer:seconds(1));
ensure_countdown_timer(State = #{timer := _TRef}) ->
    State.

ensure_countdown_timer(State = #{timer := undefined}, Time) when Time > 0 ->
    TRef = erlang:start_timer(Time, self(), countdown),
    State#{timer := TRef};
ensure_countdown_timer(State = #{timer := _TRef}, _Time) ->
    State.
