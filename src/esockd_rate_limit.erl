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
%% @doc Token bucket based rate limit.
%%
%% [Token Bucket](https://en.wikipedia.org/wiki/Token_bucket).
%%
%% @end

-module(esockd_rate_limit).

-export([new/2, check/2]).

-record(bucket, {burst   :: pos_integer(),
                 tokens  :: non_neg_integer(),
                 rate    :: float(),
                 lastime :: pos_integer()}).

-type(bucket() :: #bucket{}).

-export_type([bucket/0]).

%% @doc Create token bucket.
-spec(new(pos_integer(), pos_integer()) -> bucket()).
new(Burst, Rate) when Burst >= Rate andalso Rate > 0 ->
    #bucket{burst = Burst , tokens = Burst , rate = Rate, lastime = now_ms()}.

%% @doc Consume tokens
-spec(check(pos_integer(), bucket()) -> {non_neg_integer(), bucket()}).
check(Tokens, Bucket = #bucket{burst   = Burst,
                                 tokens  = Remaining,
                                 rate    = Rate,
                                 lastime = Lastime}) ->
    Limit = min(Burst, Remaining + round((Rate * (now_ms() - Lastime)) / 1000)),
    case Limit >= Tokens of
        true  -> %% Tokens available
            {0, Bucket#bucket{tokens = Limit - Tokens, lastime = now_ms()}};
        false -> %% Tokens not enough
            Pause = round((Tokens - Remaining)*1000/Rate),
            {Pause, Bucket#bucket{tokens = 0, lastime = now_ms()}}
    end.

now_ms() ->
    {MegaSecs, Secs, MicroSecs} = os:timestamp(),
    (MegaSecs * 1000000 + Secs) * 1000 + round(MicroSecs/1000).

