%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc A simple ets-based rate limiter.
-module(esockd_rate_limiter).

-behaviour(gen_server).

-export([start_link/0]).

-export([ create/2
        , create/3
        , consume/1
        , consume/2
        , delete/1
        ]).

-export([buckets/0]).

%% for test
-export([stop/0]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-type(bucket() :: term()).

-export_type([bucket/0]).

%%-record(bucket, {name, limit, period, last}).

-define(TAB, ?MODULE).
-define(SERVER, ?MODULE).

-spec(start_link() -> {ok, pid()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(create(bucket(), pos_integer()) -> ok).
create(Bucket, Limit) when is_integer(Limit), Limit > 0 ->
    create(Bucket, Limit, 1).

-spec(create(bucket(), pos_integer(), pos_integer()) -> ok).
create(Bucket, Limit, Period) when is_integer(Limit), Limit > 0,
                                   is_integer(Period), Period > 0 ->
    gen_server:call(?SERVER, {create, Bucket, Limit, Period}).

-spec(consume(bucket()) -> {integer(), integer()}).
consume(Bucket) ->
    consume(Bucket, 1).

-spec(consume(bucket(), pos_integer()) -> {integer(), integer()}).
consume(Bucket, Tokens) when is_integer(Tokens), Tokens > 0 ->
    try ets:update_counter(?TAB, {tokens, Bucket}, {2, -Tokens, 0, 0}) of
        0 -> {0, pause_time(Bucket, os:timestamp())};
        I -> {I, 0}
    catch
        error:badarg -> {-1, 1000} %% pause for 1 second
    end.

%% @private
pause_time(Bucket, Now) ->
    case ets:lookup(?TAB, {bucket, Bucket}) of
        [] -> 1000; %% The bucket is deleted?
        [{_Bucket, _Limit, Period, Last}] ->
            max(1, Period * 1000 - timer:now_diff(Now, Last) div 1000)
    end.

-spec(delete(bucket()) -> ok).
delete(Bucket) ->
    gen_server:cast(?SERVER, {delete, Bucket}).

-spec(buckets() -> list(map())).
buckets() ->
    [#{name => Name,
       limit => Limit,
       period => Period,
       tokens => tokens(Name),
       last => Last} || {{bucket, Name}, Limit, Period, Last} <- ets:tab2list(?TAB)].

tokens(Name) ->
    ets:lookup_element(?TAB, {tokens, Name}, 2).

-spec(stop() -> ok).
stop() ->
    gen_server:stop(?TAB).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([]) ->
    _ = ets:new(?TAB, [public, set, named_table, {write_concurrency, true}]),
    {ok, #{countdown => #{}, timer => undefined}}.

handle_call({create, Bucket, Limit, Period}, _From, State = #{countdown := Countdown}) ->
    true = ets:insert(?TAB, {{tokens, Bucket}, Limit}),
    true = ets:insert(?TAB, {{bucket, Bucket}, Limit, Period, os:timestamp()}),
    NState = State#{countdown := maps:put({bucket, Bucket}, Period, Countdown)},
    {reply, ok, ensure_countdown_timer(NState)};

handle_call(Req, _From, State) ->
    error_logger:error_msg("unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast({delete, Bucket}, State = #{countdown := Countdown}) ->
    true = ets:delete(?TAB, {bucket, Bucket}),
    true = ets:delete(?TAB, {tokens, Bucket}),
    NState = State#{countdown := maps:remove({bucket, Bucket}, Countdown)},
    {noreply, NState};

handle_cast(Msg, State) ->
    error_logger:error_msg("unexpected cast: ~p~n", [Msg]),
    {noreply, State}.

handle_info({timeout, Timer, countdown}, State = #{countdown := Countdown, timer := Timer}) ->
    Countdown1 = maps:fold(
                   fun(Key = {bucket, Bucket}, 1, Map) ->
                           [{_Key, Limit, Period, _Last}] = ets:lookup(?TAB, Key),
                           true = ets:update_element(?TAB, {tokens, Bucket}, {2, Limit}),
                           true = ets:update_element(?TAB, {bucket, Bucket}, {4, os:timestamp()}),
                           maps:put(Key, Period, Map);
                      (Key, C, Map) when C > 1 ->
                           maps:put(Key, C-1, Map)
                   end, #{}, Countdown),
    NState = State#{countdown := Countdown1, timer := undefined},
    {noreply, ensure_countdown_timer(NState)};

handle_info(Info, State) ->
    error_logger:error_msg("unexpected info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ensure_countdown_timer(State = #{timer := undefined}) ->
    TRef = erlang:start_timer(timer:seconds(1), self(), countdown),
    State#{timer := TRef};
ensure_countdown_timer(State = #{timer := _TRef}) ->
    State.

