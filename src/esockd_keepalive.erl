%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2017 Feng Lee <feng@emqtt.io>. All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc socket keepalive
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_keepalive).

-author("Feng Lee <feng@emqtt.io>").

-export([start/3, resume/1, cancel/1]).

-record(keepalive, {connection,
                    recv_oct,
                    timeout_msec,
                    timeout_msg,
                    timer_ref}).

-type(keepalive() :: #keepalive{}).

%% @doc Start keepalive
-spec(start(esockd_connection:connection(), pos_integer(), any()) ->
      {ok, keepalive()} | {error, any()}).
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

