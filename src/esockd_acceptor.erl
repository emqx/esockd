%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_acceptor).

-behaviour(gen_statem).

-include("esockd.hrl").

-export([
    start_link/7
]).

%% state callbacks
-export([handle_event/4]).

%% The state diagram:
%%
%%         +----------------------------------------------+
%%         |                                              |
%%   +-----v----+       +-----------------+        +------+------+
%%   | waiting  +------>+  token request  +------->+  accepting  |
%%   +-+----^---+       +----+------^-----+        +-------------+
%%     |    |                |      |
%%     |    +-------------+  |      |
%%     |                  |  |      |
%%     |                +-+--V------+-----+
%%     +--------------->+    suspending   |
%%                      +-----------------+
%%

%% gen_statem Callbacks
-export([
    init/1,
    callback_mode/0,
    terminate/3,
    code_change/4
]).

-record(state, {
    proto :: atom(),
    listen_on :: esockd:listen_on(),
    lsock :: inet:socket(),
    sockmod :: module(),
    sockname :: {inet:ip_address(), inet:port_number()},
    tune_fun :: esockd:sock_fun(),
    upgrade_funs :: [esockd:sock_fun()],
    conn_limiter :: undefined | esockd_generic_limiter:limiter(),
    conn_sup :: pid(),
    accept_ref = no_ref :: term()
}).

%% @doc Start an acceptor
-spec start_link(
    atom(),
    esockd:listen_on(),
    pid(),
    esockd:sock_fun(),
    [esockd:sock_fun()],
    esockd_generic_limiter:limiter(),
    inet:socket()
) ->
    {ok, pid()} | {error, term()}.
start_link(
    Proto,
    ListenOn,
    ConnSup,
    TuneFun,
    UpgradeFuns,
    Limiter,
    LSock
) ->
    gen_statem:start_link(
        ?MODULE,
        [
            Proto,
            ListenOn,
            ConnSup,
            TuneFun,
            UpgradeFuns,
            Limiter,
            LSock
        ],
        []
    ).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------
callback_mode() -> handle_event_function.

init([Proto, ListenOn, ConnSup, TuneFun, UpgradeFuns, Limiter, LSock]) ->
    _ = erlang:process_flag(trap_exit, true),
    _ = rand:seed(exsplus, erlang:timestamp()),
    {ok, Sockname} = inet:sockname(LSock),
    {ok, SockMod} = inet_db:lookup_socket(LSock),
    {ok, waiting,
        #state{
            proto = Proto,
            listen_on = ListenOn,
            lsock = LSock,
            sockmod = SockMod,
            sockname = Sockname,
            tune_fun = TuneFun,
            upgrade_funs = UpgradeFuns,
            conn_limiter = Limiter,
            conn_sup = ConnSup
        },
        {next_event, internal, begin_waiting}}.

handle_event(internal, begin_waiting, waiting, #state{accept_ref = Ref}) when Ref =/= no_ref ->
    %% started waiting in suspending state
    keep_state_and_data;
handle_event(internal, begin_waiting, waiting, State = #state{lsock = LSock, accept_ref = no_ref}) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} ->
            {keep_state, State#state{accept_ref = Ref}};
        {error, Reason} when
            Reason =:= emfile;
            Reason =:= enfile
        ->
            start_suspending(State, 1000);
        {error, econnaborted} ->
            {next_state, waiting, State, {next_event, internal, begin_waiting}};
        {error, closed} ->
            {stop, normal, State};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_event(internal, accept_and_close, suspending, State = #state{lsock = LSock}) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} ->
            {keep_state, State#state{accept_ref = Ref}};
        {error, Reason} when
            Reason =:= emfile;
            Reason =:= enfile
        ->
            {keep_state_and_data, {next_event, internal, accept_and_close}};
        {error, econnaborted} ->
            {keep_state_and_data, {next_event, internal, accept_and_close}};
        {error, closed} ->
            {stop, normal, State};
        {error, Reason} ->
            {stop, Reason, State}
    end;
handle_event(
    info,
    {inet_async, LSock, Ref, {ok, Sock}},
    waiting,
    State = #state{lsock = LSock, accept_ref = Ref}
) ->
    NextEvent = {next_event, internal, {token_request, Sock}},
    {next_state, token_request, State#state{accept_ref = no_ref}, NextEvent};
handle_event(
    info,
    {inet_async, LSock, Ref, {ok, Sock}},
    suspending,
    State = #state{lsock = LSock, accept_ref = Ref}
) ->
    _ = close(Sock),
    NextEvent = {next_event, internal, accept_and_close},
    {keep_state, State#state{accept_ref = no_ref}, NextEvent};
handle_event(
    internal, {token_request, Sock}, token_request, State = #state{conn_limiter = Limiter}
) ->
    case esockd_generic_limiter:consume(1, Limiter) of
        {ok, Limiter2} ->
            {next_state, accepting, State#state{conn_limiter = Limiter2},
                {next_event, internal, {accept, Sock}}};
        {pause, PauseTime, Limiter2} ->
            _ = close(Sock),
            start_suspending(State#state{conn_limiter = Limiter2}, PauseTime)
    end;
handle_event(
    internal,
    {accept, Sock},
    accepting,
    State = #state{
        proto = Proto,
        listen_on = ListenOn,
        sockmod = SockMod,
        tune_fun = TuneFun,
        upgrade_funs = UpgradeFuns,
        conn_sup = ConnSup
    }
) ->
    %% make it look like gen_tcp:accept
    inet_db:register_socket(Sock, SockMod),

    %% Inc accepted stats.
    esockd_server:inc_stats({Proto, ListenOn}, accepted, 1),

    case eval_tune_socket_fun(TuneFun, Sock) of
        {ok, Sock} ->
            case esockd_connection_sup:start_connection(ConnSup, Sock, UpgradeFuns) of
                {ok, _Pid} ->
                    ok;
                {error, Reason} ->
                    handle_accept_error(Reason, "failed_to_start_connection_process", State),
                    close(Sock)
            end;
        {error, Reason} ->
            handle_accept_error(Reason, "failed_to_apply_tune_funcs", State),
            close(Sock)
    end,
    {next_state, waiting, State, {next_event, internal, begin_waiting}};
handle_event(state_timeout, begin_waiting, suspending, State) ->
    {next_state, waiting, State, {next_event, internal, begin_waiting}};
handle_event(
    info,
    {inet_async, LSock, Ref, {error, Reason}},
    StateName,
    State = #state{lsock = LSock, accept_ref = Ref}
) ->
    handle_socket_error(Reason, State#state{accept_ref = no_ref}, StateName);
handle_event(Type, Content, StateName, _) ->
    logger:log(warning, #{msg => "esockd_acceptor_unhandled_event",
                          state_name => StateName,
                          event_type => Type,
                          event_content => Content}),
    keep_state_and_data.

terminate(normal, _StateName, #state{}) ->
    ok;
terminate(shutdown, _StateName, #state{}) ->
    ok;
terminate(Reason, _StateName, #state{}) ->
    logger:log(error, #{msg => "esockd_acceptor_terminating",
                        reaseon => Reason}),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

close(Sock) ->
    try
        %% port-close leads to a TPC reset which cuts out the tcp graceful close overheads
        true = port_close(Sock),
        receive {'EXIT', Sock, _} -> ok after 1 -> ok end
    catch
        error:_ -> ok
    end.

eval_tune_socket_fun({Fun, Args1}, Sock) ->
    apply(Fun, [Sock | Args1]).

handle_accept_error(enotconn, _, _) ->
    ok;
handle_accept_error(einval, _, _) ->
    ok;
handle_accept_error(overloaded, _, #state{proto = Proto, listen_on = ListenOn}) ->
    esockd_server:inc_stats({Proto, ListenOn}, closed_overloaded, 1),
    ok;
handle_accept_error(Reason, Msg, #state{sockname = Sockname}) ->
    logger:log(error, #{msg => Msg,
                        listener => esockd:format(Sockname),
                        cause => Reason}).

handle_socket_error(closed, State, _StateName) ->
    {stop, normal, State};
%% {error, econnaborted} -> accept
%% {error, esslaccept}   -> accept
%% {error, esslaccept}   -> accept
handle_socket_error(Reason, State, suspending) when Reason =:= econnaborted; Reason =:= esslaccept ->
    {keep_state, State, {next_event, internal, accept_and_close}};
handle_socket_error(Reason, State, _StateName) when Reason =:= econnaborted; Reason =:= esslaccept ->
    {next_state, waiting, State, {next_event, internal, begin_waiting}};
%% emfile: The per-process limit of open file descriptors has been reached.
%% enfile: The system limit on the total number of open files has been reached.
%% enfile: The system limit on the total number of open files has been reached.
handle_socket_error(Reason, State, suspending) when Reason =:= emfile; Reason =:= enfile ->
    log_system_limit(State, Reason),
    {keep_state, State, {next_event, internal, accept_and_close}};
handle_socket_error(Reason, State, _StateName) when Reason =:= emfile; Reason =:= enfile ->
    log_system_limit(State, Reason),
    start_suspending(State, 1000);
handle_socket_error(Reason, State, _StateName) ->
    {stop, Reason, State}.

explain_posix(emfile) ->
    "EMFILE (Too many open files)";
explain_posix(enfile) ->
    "ENFILE (File table overflow)".

log_system_limit(State, Reason) ->
    logger:log(error, #{msg => "cannot_accept_more_connections",
                        listener => esockd:format(State#state.sockname),
                        cause => explain_posix(Reason)}).

start_suspending(State, Timeout) ->
    Actions = [{next_event, internal, accept_and_close},
               {state_timeout, Timeout, begin_waiting}],
    {next_state, suspending, State, Actions}.
