%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-export([create/2, create/3, aquire/1, aquire/2, delete/1]).
-export([buckets/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-type(bucket() :: term()).

-export_type([bucket/0]).

%%-record(bucket, {name, limit, period}).

-define(TAB, ?MODULE).
-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

create(Bucket, Limit) when Limit > 0 ->
    create(Bucket, Limit, 1).
create(Bucket, Limit, Period) when Limit > 0, Period > 0 ->
    gen_server:call(?SERVER, {create, Bucket, Limit, Period}).

aquire(Bucket) ->
    aquire(Bucket, 1).

aquire(Bucket, Tokens) when Tokens > 0 ->
    try
        ets:update_counter(?TAB, {tokens, Bucket}, {2, -Tokens, 0, 0})
    catch
        error:badarg -> -1
    end.

delete(Bucket) ->
    gen_server:cast(?SERVER, {delete, Bucket}).

buckets() ->
    [{bucket, Name, Limit, Period, tokens(Name)} ||
     {{bucket, Name}, Limit, Period}
     <- ets:match_object(?TAB, {{bucket, '_'}, '_', '_'})].

tokens(Name) ->
    ets:lookup_element(?TAB, {tokens, Name}, 2).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    _ = ets:new(?TAB, [public, set, named_table, {write_concurrency, true}]),
    {ok, #{countdown => #{}, timer => undefined}}.

handle_call({create, Bucket, Limit, Period}, _From, State = #{countdown := Countdown}) ->
    ets:insert(?TAB, {{tokens, Bucket}, Limit}),
    ets:insert(?TAB, {{bucket, Bucket}, Limit, Period}),
    {reply, ok, ensure_reset_timer(State#{countdown := maps:put({bucket, Bucket}, Period, Countdown)})};

handle_call(Req, _From, State) ->
    error_logger:error_msg("unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast({delete, Bucket}, State = #{countdown := Countdown}) ->
    ets:delete(?TAB, {bucket, Bucket}),
    ets:delete(?TAB, {tokens, Bucket}),
    {noreply, State#{countdown := maps:remove({bucket, Bucket}, Countdown)}};

handle_cast(Msg, State) ->
    error_logger:error_msg("unexpected cast: ~p~n", [Msg]),
    {noreply, State}.

handle_info({timeout, Timer, reset}, State = #{countdown := Countdown, timer := Timer}) ->
    Countdown1 = maps:fold(
                   fun(Key = {bucket, Bucket}, 0, Map) ->
                           [{_Key, Limit, Period}] = ets:lookup(?TAB, Key),
                           ets:update_element(?TAB, {tokens, Bucket}, {2, Limit}),
                           maps:put(Key, Period, Map);
                      (Key, C, Map) when C > 0 ->
                           maps:put(Key, C-1, Map)
                   end, Countdown, Countdown),
    {noreply, ensure_reset_timer(State#{countdown := Countdown1, timer := undefined})};

handle_info(Info, State) ->
    error_logger:error_msg("unexpected info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ensure_reset_timer(State = #{timer := undefined}) ->
    State#{timer := erlang:start_timer(timer:seconds(1), self(), reset)};
ensure_reset_timer(State = #{timer := _Timer}) ->
    State.

