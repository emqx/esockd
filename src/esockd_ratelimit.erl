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
%%
%% @doc esockd rate limiter:
%%
%% [Token Bucket](https://en.wikipedia.org/wiki/Token_bucket).
%%
%% [Leaky Bucket](https://en.wikipedia.org/wiki/Leaky_bucket)
%%
%% @end

-module(esockd_ratelimit).

-export([new/2, check/2]).

-record(bucket, {capacity  :: pos_integer(),     %% tokens capacity
                 remaining :: non_neg_integer(), %% available tokens
                 limitrate :: float(),           %% bytes/millsec
                 lastime   :: pos_integer()}).   %% millseconds

-type(bucket() :: #bucket{}).

-export_type([bucket/0]).

%% @doc Create rate limiter bucket.
-spec(new(pos_integer(), pos_integer()) -> bucket()).
new(Capacity, Rate) when Capacity > Rate andalso Rate > 0 ->
    #bucket{capacity = Capacity, remaining = Capacity, limitrate = Rate/1000, lastime = now_ms()}.

%% @doc Check inflow bytes.
-spec(check(pos_integer(), bucket()) -> {non_neg_integer(), bucket()}).
check(Bytes, Bucket = #bucket{capacity = Capacity, remaining = Remaining,
                              limitrate = Rate, lastime = Lastime}) ->
    Tokens = lists:min([Capacity, Remaining + round(Rate * (now_ms() - Lastime))]),
    {Pause1, NewBucket} =
    case Tokens >= Bytes of
        true  -> %% Tokens available
            {0, Bucket#bucket{remaining = Tokens - Bytes, lastime = now_ms()}};
        false -> %% Tokens not enough
            Pause = round((Bytes - Tokens)/Rate),
            {Pause, Bucket#bucket{remaining = 0, lastime = now_ms() + Pause}}
    end,
    {Pause1, NewBucket}.

now_ms() ->
    {MegaSecs, Secs, MicroSecs} = os:timestamp(),
    (MegaSecs * 1000000 + Secs) * 1000 + round(MicroSecs/1000).

