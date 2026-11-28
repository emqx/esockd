%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc Holds refused sockets open for a fixed delay, then resets them.
%%
%% One holder per listener. The acceptor that accepted a socket stays its
%% owner and only tells the holder about it. The holder closes it after
%% the delay. A held socket whose acceptor exits is closed by the runtime;
%% closing it again here does nothing.
%%
%% The acceptor checks the cap with a shared counter before it sends the
%% socket, so the holder only receives sockets it has room for.
-module(esockd_tarpit).

-behaviour(gen_server).

-export([
    start_supervised/1,
    start_link/2,
    handle/1,
    hold/3,
    flush/1,
    count/1,
    auto_size/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-export_type([handle/0]).

-type handle() :: #{pid := pid(), counter := atomics:atomics_ref(), size := pos_integer()}.

-define(TIMEOUT, release).

-record(s, {
    counter :: atomics:atomics_ref(),
    size :: pos_integer(),
    delay :: pos_integer(),
    %% {Deadline, CloseMod, Sock}, ordered by deadline because the delay is fixed.
    held = queue:new() :: queue:queue({integer(), module(), _Sock}),
    timer = false :: boolean()
}).

%% @doc Start the holder of a listener, or `ignore' when the tarpit is off.
-spec start_supervised(esockd:listener_ref()) -> {ok, pid()} | ignore.
start_supervised(ListenerRef) ->
    Type = esockd_server:get_listener_prop(ListenerRef, type),
    Opts = esockd_server:get_listener_prop(ListenerRef, options),
    case proplists:get_value(tarpit, Opts) of
        %% An invalid value is rejected by esockd_acceptor_sup:check_options/2.
        #{size := Size, delay := Delay} when is_integer(Size), Size > 0,
                                             is_integer(Delay), Delay > 0,
                                             Type =/= dtls ->
            {ok, Pid} = start_link(Size, Delay),
            _ = esockd_server:set_listener_prop(ListenerRef, tarpit, handle(Pid)),
            {ok, Pid};
        _ ->
            _ = esockd_server:set_listener_prop(ListenerRef, tarpit, undefined),
            ignore
    end.

-spec start_link(pos_integer(), pos_integer()) -> {ok, pid()}.
start_link(Size, Delay) ->
    gen_server:start_link(?MODULE, {Size, Delay}, []).

-spec handle(pid()) -> handle().
handle(Pid) ->
    gen_server:call(Pid, handle, infinity).

%% @doc Called by the socket owner. Returns `full' when the tarpit has no
%% room; the caller then closes the socket itself.
-spec hold(handle(), module(), _Sock) -> ok | full.
hold(#{pid := Pid, counter := Counter, size := Size}, CloseMod, Sock) ->
    case atomics:add_get(Counter, 1, 1) =< Size of
        true ->
            _ = erlang:send(Pid, {hold, CloseMod, Sock}),
            ok;
        false ->
            ok = atomics:sub(Counter, 1, 1),
            full
    end.

%% @doc Reset all held sockets now, for example to free fds on emfile.
-spec flush(handle()) -> ok.
flush(#{pid := Pid}) ->
    _ = erlang:send(Pid, flush),
    ok.

%% @doc Number of held sockets. A socket whose acceptor has exited is
%% counted until its deadline.
-spec count(handle() | undefined) -> non_neg_integer().
count(undefined) ->
    0;
count(#{counter := Counter}) ->
    max(0, atomics:get(Counter, 1)).

%% @doc A tarpit size for a connection rate (connections per second) and a
%% delay (milliseconds): `Rate * Delay / 1000', rounded up, at most 10% of
%% the max fds (`esockd:ulimit/0').
%%
%% Held sockets then come back at about the rate the limiter lets in. A
%% larger tarpit returns more clients than the limiter admits, and they are
%% refused again. A smaller one closes the rest at once.
-spec auto_size(number(), pos_integer()) -> non_neg_integer().
auto_size(Rate, Delay) when is_number(Rate), Rate >= 0,
                            is_integer(Delay), Delay > 0 ->
    Cap = max(1, esockd:ulimit() div 10),
    min(Cap, ceil(Rate * Delay / 1000)).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init({Size, Delay}) ->
    _ = process_flag(trap_exit, true),
    Counter = atomics:new(1, [{signed, true}]),
    {ok, #s{counter = Counter, size = Size, delay = Delay}}.

handle_call(handle, _From, S = #s{counter = Counter, size = Size}) ->
    {reply, #{pid => self(), counter => Counter, size => Size}, S};
handle_call(_Req, _From, S) ->
    {reply, ignore, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({hold, CloseMod, Sock}, S = #s{delay = Delay, held = Q}) ->
    Deadline = erlang:monotonic_time(millisecond) + Delay,
    {noreply, arm(Deadline, S#s{held = queue:in({Deadline, CloseMod, Sock}, Q)})};
handle_info(?TIMEOUT, S) ->
    {noreply, release(erlang:monotonic_time(millisecond), S#s{timer = false})};
handle_info(flush, S) ->
    {noreply, release(infinity, S)};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    _ = release(infinity, S),
    ok.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% One timer at a time, for the head of the queue.
arm(Deadline, S = #s{timer = false}) ->
    _ = erlang:send_after(Deadline, self(), ?TIMEOUT, [{abs, true}]),
    S#s{timer = true};
arm(_Deadline, S) ->
    S.

%% Reset every socket whose deadline is not after Now.
release(Now, S = #s{held = Q, counter = Counter}) ->
    case queue:peek(Q) of
        {value, {Deadline, CloseMod, Sock}} when Now =:= infinity; Deadline =< Now ->
            ok = CloseMod:reset_close(Sock),
            ok = atomics:sub(Counter, 1, 1),
            release(Now, S#s{held = queue:drop(Q)});
        {value, {Deadline, _CloseMod, _Sock}} ->
            arm(Deadline, S);
        empty ->
            S
    end.
