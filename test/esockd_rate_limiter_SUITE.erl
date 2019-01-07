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

-module(esockd_rate_limiter_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-compile(export_all).
-compile(nowarn_export_all).

-define(LIMITER, esockd_rate_limiter).

all() ->
    [{group, all}].

groups() ->
    [{all, [sequence], [consume, consume_and_pause]}].

consume(_) ->
    {ok, _} = ?LIMITER:start_link(),
    ok = ?LIMITER:create(bucket, 1000),
    ?assertEqual({900, 0}, ?LIMITER:consume(bucket, 100)),
    ?assertEqual({800, 0}, ?LIMITER:consume(bucket, 100)),
    ?assertEqual({700, 0}, ?LIMITER:consume(bucket, 100)),
    ?assertEqual({600, 0}, ?LIMITER:consume(bucket, 100)),
    ?assertEqual({100, 0}, ?LIMITER:consume(bucket, 500)),
    timer:sleep(1200), erlang:yield(),
    %% The bucket is reset again.
    ?assertEqual({500, 0}, ?LIMITER:consume(bucket, 500)),
    ?LIMITER:delete(bucket),
    timer:sleep(100), erlang:yield(),
    ?assertEqual([], ?LIMITER:buckets()),
    ok = ?LIMITER:stop().

consume_and_pause(_) ->
    {ok, _} = ?LIMITER:start_link(),
    ok = ?LIMITER:create(bucket1, 1000),
    ?assertEqual({500, 0}, ?LIMITER:consume(bucket1, 500)),
    timer:sleep(100), erlang:yield(),
    {0, Pause1} = ?LIMITER:consume(bucket1, 600),
    ct:print("Pause1: ~p", [Pause1]),
    ?assert((500 < Pause1 andalso Pause1 < 1000)),
    ok = ?LIMITER:create(bucket2, 1000, 5),
    ?assertEqual({500, 0}, ?LIMITER:consume(bucket2, 500)),
    timer:sleep(500), erlang:yield(),
    {0, Pause2} = ?LIMITER:consume(bucket2, 600),
    ct:print("Pause2: ~p", [Pause2]),
    ?assert((4000 < Pause2 andalso Pause2 < 5000)),
    ?assertEqual(2, length(?LIMITER:buckets())),
    ok = ?LIMITER:delete(bucket1),
    ok = ?LIMITER:delete(bucket2),
    ok = ?LIMITER:stop().

