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

-module(esockd_keepalive).

-export([start/3, resume/1, cancel/1]).

-record(keepalive, {connection,
                    recv_oct,
                    timeout_msec,
                    timeout_msg,
                    timer_ref}).

-type(keepalive() :: #keepalive{}).

%% @doc Start keepalive
-spec(start(esockd_connection:connection(), pos_integer(), any()) ->
      {ok, keepalive()} | {error, term()}).
start(Connection, TimeoutSec, TimeoutMsg) when TimeoutSec > 0 ->
    with_sock_stats(Connection, fun(RecvOct) ->
        Ms = timer:seconds(TimeoutSec),
        Ref = erlang:send_after(Ms, self(), TimeoutMsg),
        {ok, #keepalive {connection   = Connection,
                         recv_oct     = RecvOct,
                         timeout_msec = Ms,
                         timeout_msg  = TimeoutMsg,
                         timer_ref    = Ref}}
    end).

%% @doc Try to resume keepalive, called when timeout
-spec(resume(keepalive()) -> timeout | {resumed, keepalive()}).
resume(KeepAlive = #keepalive {connection   = Connection,
                               recv_oct     = RecvOct,
                               timeout_msec = Ms,
                               timeout_msg  = TimeoutMsg,
                               timer_ref    = Ref}) ->
    with_sock_stats(Connection, fun(NewRecvOct) ->
        case NewRecvOct =:= RecvOct of
            false ->
                cancel(Ref), %% need?
                NewRef = erlang:send_after(Ms, self(), TimeoutMsg),
                {resumed, KeepAlive#keepalive{recv_oct = NewRecvOct, timer_ref = NewRef}};
            true ->
                {error, timeout}
        end
    end).

%% @doc Cancel Keepalive
-spec(cancel(keepalive()) -> any()).
cancel(#keepalive{timer_ref = Ref}) ->
    cancel(Ref);
cancel(undefined) -> 
	undefined;
cancel(Ref) -> 
	catch erlang:cancel_timer(Ref).

with_sock_stats(Connection, SuccFun) ->
    case Connection:getstat([recv_oct]) of
        {ok, [{recv_oct, RecvOct}]} ->
            SuccFun(RecvOct);
        {error, Error} ->
            {error, Error}
    end.

