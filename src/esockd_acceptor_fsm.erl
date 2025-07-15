%%--------------------------------------------------------------------
%% Copyright (c) 2020-2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_acceptor_fsm).

-behaviour(gen_statem).

-include("esockd.hrl").

-export([start_link/6]).

%% state callbacks
-export([handle_event/4]).

%% The state diagram:
%%   init
%%     |   +---------------------+
%%     |   |                     |
%%   +-V---v-----+      +--------+----------+
%%   |  waiting  +----->+ accepting-waiting |
%%   +-+----^----+      +--------+----------+
%%     |    |                    |
%%     |    +--------------+     |
%%     |                   |     |
%%     |                 +-+-----v------+
%%     +---------------->+  suspending  +<-----------+
%%                       +--------------+            |
%%                               |                   |
%%                               |                   |
%%                    +----------v-----------+       |
%%                    | accepting-suspending +-------+
%%                    +----------------------+

%% gen_statem Callbacks
-export([
    init/1,
    callback_mode/0,
    terminate/3,
    code_change/4
]).

%% time to suspend if system-limit reached (emfile/enfile)
-define(SYS_LIMIT_SUSPEND_MS, 1000).

-record(d, {
    listener_ref :: esockd:listener_ref(),
    modctx :: {module(), _Ctx},
    upgrade_funs :: [esockd:sock_fun()],
    conn_limiter :: undefined | esockd_generic_limiter:limiter(),
    conn_sup :: pid()
                %% NOTE: Only for tests
                | {function(), [term()]}
}).

%% @doc Start an acceptor
-spec start_link(
    esockd:listener_ref(),
    pid(),
    {module(), _Options},
    [esockd:sock_fun()],
    esockd_generic_limiter:limiter(),
    _ListenSocket
) ->
    {ok, pid()} | {error, term()}.
start_link(ListenerRef, ConnSup, ModOpts, UpgradeFuns, Limiter, LSock) ->
    gen_statem:start_link(
        ?MODULE,
        [ListenerRef, ConnSup, ModOpts, UpgradeFuns, Limiter, LSock],
        []
    ).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

callback_mode() ->
    handle_event_function.

init([ListenerRef, ConnSup, {Mod, Opts}, UpgradeFuns, Limiter, LSock]) ->
    _ = erlang:process_flag(trap_exit, true),
    Ctx = Mod:init(LSock, Opts),
    D = #d{
        listener_ref = ListenerRef,
        modctx = {Mod, Ctx},
        upgrade_funs = UpgradeFuns,
        conn_limiter = Limiter,
        conn_sup = ConnSup
    },
    {ok, waiting, D, {next_event, internal, accept}}.

handle_event(internal, accept, State, D) when State =:= waiting orelse
                                              State =:= suspending ->
    case async_accept(State, D) of
        {ok, Sock} ->
            handle_accepted(Sock, State, D);
        {async, Ref} ->
            {next_state, {accepting, Ref, State}, D};
        {error, econnaborted} ->
            inc_stats(D, econnaborted),
            {keep_state, D, {next_event, internal, accept}};
        {error, closed} ->
            {stop, normal, D};
        {error, Reason} ->
            {stop, Reason, D}
    end;
handle_event(info, Message, State = {accepting, Ref, InState}, D) ->
    case async_accept_result(Message, Ref, D) of
        {ok, Sock} ->
            handle_accepted(Sock, InState, D);
        {error, Reason} ->
            inc_stats(D, Reason),
            handle_socket_error(Reason, InState, D);
        {async, NRef} ->
            {next_state, {accepting, NRef, InState}, D};
        Info ->
            handle_info(info, Info, State, D)
    end;
handle_event({timeout, cooldown}, begin_waiting, {accepting, Ref, suspending}, D) ->
    {next_state, {accepting, Ref, waiting}, D};
handle_event({timeout, cooldown}, begin_waiting, suspending, D) ->
    enter_waiting(D);
handle_event(Type, Content, State, D) ->
    handle_info(Type, Content, State, D).

handle_info(Type, Content, State, _D) ->
    logger:log(warning, #{msg => "esockd_acceptor_fsm_unhandled_event",
                          state => State,
                          event_type => Type,
                          event_content => Content}),
    keep_state_and_data.

handle_accepted(Sock, waiting, D = #d{conn_limiter = Limiter}) ->
    case esockd_generic_limiter:consume(1, Limiter) of
        {ok, NLimiter} ->
            ND = D#d{conn_limiter = NLimiter},
            _ = handle_socket(Sock, ND),
            enter_waiting(ND);
        {pause, PauseTime, NLimiter} ->
            _ = close(D, Sock),
            _ = inc_stats(D, rate_limited),
            ND = D#d{conn_limiter = NLimiter},
            enter_suspending(ND, PauseTime)
    end;
handle_accepted(Sock, suspending, D) ->
    _ = close(D, Sock),
    _ = inc_stats(D, rate_limited),
    {next_state, suspending, D, {next_event, internal, accept}}.

enter_waiting(D) ->
    Action = {next_event, internal, accept},
    {next_state, waiting, D, Action}.

enter_suspending(D, Timeout) ->
    Actions = [{next_event, internal, accept},
               {{timeout, cooldown}, Timeout, begin_waiting}],
    {next_state, suspending, D, Actions}.

handle_socket(
    Sock,
    D = #d{
        modctx = {Mod, Ctx},
        upgrade_funs = UpgradeFuns,
        conn_sup = ConnSup
    }
) ->
    case Mod:post_accept(Sock, Ctx) of
        {ok, TransportMod, NSock} ->
            case start_connection(ConnSup, TransportMod, NSock, UpgradeFuns) of
                {ok, _Pid} ->
                    %% Inc accepted stats.
                    inc_stats(D, accepted);
                {error, Reason} ->
                    handle_start_error(Reason, D),
                    close(D, NSock),
                    inc_stats(D, Reason)
            end;
        {error, Reason} ->
            %% the socket became invalid before
            %% starting the owner process
            close(D, Sock),
            inc_stats(D, Reason)
    end.

terminate(normal, _StateName, _) ->
    ok;
terminate(shutdown, _StateName, _) ->
    ok;
terminate({shutdown, _}, _StateName, _) ->
    ok;
terminate(Reason, _StateName, _D) ->
    logger:log(error, #{msg => "esockd_acceptor_terminating", reason => Reason}),
    ok.

code_change(_OldVsn, State, D, _Extra) ->
    {ok, State, D}.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

close(#d{modctx = {Mod, _}}, Sock) ->
    Mod:fast_close(Sock).

handle_start_error(econnreset, _) ->
    ok;
handle_start_error(enotconn, _) ->
    ok;
handle_start_error(einval, _) ->
    ok;
handle_start_error(overloaded, _) ->
    ok;
handle_start_error(Reason, D) ->
    logger:log(error, #{msg => "failed_to_start_connection_process",
                        listener => format_sockname(D),
                        cause => Reason}).

handle_socket_error(closed, _State, D) ->
    {stop, normal, D};
%% {error, econnaborted} -> accept
handle_socket_error(econnaborted, State, D) ->
    {next_state, State, D, {next_event, internal, accept}};
handle_socket_error(Reason, suspending, D) when Reason =:= emfile; Reason =:= enfile ->
    log_system_limit(Reason, D),
    {next_state, suspending, D, {next_event, internal, accept}};
handle_socket_error(Reason, _State, D) when Reason =:= emfile; Reason =:= enfile ->
    log_system_limit(Reason, D),
    enter_suspending(D, ?SYS_LIMIT_SUSPEND_MS);
handle_socket_error(Reason, _State, D) ->
    {stop, Reason, D}.

explain_posix(emfile) ->
    "EMFILE (Too many open files)";
explain_posix(enfile) ->
    "ENFILE (File table overflow)".

log_system_limit(Reason, D) ->
    logger:log(critical,
               #{msg => "cannot_accept_more_connections",
                 listener => format_sockname(D),
                 cause => explain_posix(Reason)}).

format_sockname(#d{modctx = {Mod, Ctx}}) ->
    case Mod:sockname(Ctx) of
        {ok, SockName} ->
            esockd:format(SockName);
        {error, Reason} ->
            Reason
    end.

inc_stats(#d{listener_ref = ListenerRef}, Tag) ->
    _ = esockd_server:inc_stats(ListenerRef, counter(Tag), 1),
    ok.

counter(accepted) -> ?ARG_ACCEPTED;
counter(emfile) -> ?ARG_CLOSED_SYS_LIMIT;
counter(enfile) -> ?ARG_CLOSED_SYS_LIMIT;
counter(?ERROR_MAXLIMIT) -> ?ARG_CLOSED_MAX_LIMIT;
counter(overloaded) -> ?ARG_CLOSED_OVERLOADED;
counter(rate_limited) -> ?ARG_CLOSED_RATE_LIMITED;
counter(_) -> ?ARG_CLOSED_OTHER_REASONS.

start_connection(ConnSup, Transport, Sock, UpgradeFuns) when is_pid(ConnSup) ->
    esockd_connection_sup:start_connection(ConnSup, Transport, Sock, UpgradeFuns);
start_connection({F, A}, _Transport, Sock, UpgradeFuns) when is_function(F) ->
    %% only in tests so far
    apply(F, A ++ [Sock, UpgradeFuns]).

%% To throttle system-limit error logs,
%% if system limit reached, slow down the state machine by
%% turning the immediate return to a delayed async message.
%% The first delayed message should cause acceptor to enter suspending state.
%% Then it should continue to accept 10 more sockets (which are all likely
%% to result in emfile error anyway) during suspending state.
async_accept(CurrentState, #d{modctx = {Mod, Ctx}}) ->
    case Mod:async_accept(Ctx) of
        {error, Reason} when Reason =:= emfile orelse Reason =:= enfile ->
            Delay = case CurrentState of
                        suspending -> ?SYS_LIMIT_SUSPEND_MS div 10;
                        _Waiting -> 0
                    end,
            Ref = make_ref(),
            Msg = {?MODULE, Ref, {error, Reason}},
            _ = erlang:send_after(Delay, self(), Msg),
            {async, Ref};
        Other ->
            Other
    end.

async_accept_result({?MODULE, Ref, {error, Reason}}, Ref, _) ->
    {error, Reason};
async_accept_result(Message, Ref, #d{modctx = {Mod, Ctx}}) ->
    Mod:async_accept_result(Message, Ref, Ctx).
