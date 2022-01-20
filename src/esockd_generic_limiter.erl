%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_generic_limiter).

-export([create/1, consume/2, delete/1]).

-type pause_time() :: non_neg_integer().

-type limiter() :: #{ module := atom()
                    , name := atom()

                      %% other context
                    , atom() => term()
                    }.

-type create_options() :: #{ module := atom()
                           , atom() => term()
                           }.

-type consume_result() :: {ok, limiter()} |
                          {pause, pause_time(), limiter()}.

-callback create(create_options()) -> limiter().

-callback consume(integer(), limiter()) -> consume_result().

-callback delete(limiter()) -> ok.

-export_type([limiter/0, create_options/0, consume_result/0]).

%%--------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------
create(#{module := Module} = Opts) ->
    Module:create_limiter(Opts).

consume(Token, #{module := Module} = Limiter) ->
    Module:consume_limiter(Token, Limiter).

delete(#{module := Module} = Limiter) ->
    Module:delete_limiter(Limiter).
