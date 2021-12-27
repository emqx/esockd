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

-export([make_instance/1, consume/2, delete/1]).

-type pause_time() :: non_neg_integer().
-type consume_handler() :: fun((integer(), limiter()) ->
                                      {ok, limiter()}
                                          | {pause, pause_time(), limiter()}).
-type delete_handler() :: fun((limiter()) -> ok).

-type limiter() :: #{ module := atom()
                    , name := atom()
                    , consume := consume_handler()
                    , delete := delete_handler()

                      %% other context
                    , atom() => term()
                    }.

-type make_instance_opts() :: #{ module := atom()
                               , atom() => term()
                               }.

-export_type([limiter/0, make_instance_opts/0]).

%%--------------------------------------------------------------------
%% Callbacks
%%--------------------------------------------------------------------
-callback make_instance(make_instance_opts()) -> limiter().

make_instance(#{module := Module} = Opts) ->
    Module:create_instace(Opts).

consume(Token, #{consume := Func} = Limiter) ->
    Func(Token, Limiter).

delete(#{delete := Func} = Limiter) ->
    Func(Limiter).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
