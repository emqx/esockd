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
    start_link/7,
    set_conn_limiter/2
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
    accept_ref :: term()
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

-spec set_conn_limiter(pid(), esockd_generic_limiter:limiter()) -> ok.
set_conn_limiter(Acceptor, Limiter) ->
    gen_statem:call(Acceptor, {set_conn_limiter, Limiter}, 5000).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------
callback_mode() -> handle_event_function.

init([Proto, ListenOn, ConnSup, TuneFun, UpgradeFuns, Limiter, LSock]) ->
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

handle_event(internal, begin_waiting, waiting, State = #state{lsock = LSock}) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} ->
            {keep_state, State#state{accept_ref = Ref}};
        {error, Reason} when
            Reason =:= emfile;
            Reason =:= enfile
        ->
            {next_state, suspending, State, {state_timeout, 1000, begin_waiting}};
        {error, closed} ->
            {stop, normal, State};
        {error, Reason} ->
            error_logger:error_msg("~p async_accept error: ~p", [?MODULE, Reason]),
            {stop, Reason, State}
    end;
handle_event(
    info,
    {inet_async, LSock, Ref, {ok, Sock}},
    waiting,
    State = #state{lsock = LSock, accept_ref = Ref}
) ->
    {next_state, token_request, State, {next_event, internal, {token_request, Sock}}};
handle_event(
    internal, {token_request, Sock} = Content, token_request, State = #state{conn_limiter = Limiter}
) ->
    case esockd_generic_limiter:consume(1, Limiter) of
        {ok, Limiter2} ->
            {next_state, accepting, State#state{conn_limiter = Limiter2},
                {next_event, internal, {accept, Sock}}};
        {pause, PauseTime, Limiter2} ->
            {next_state, suspending, State#state{conn_limiter = Limiter2},
                {state_timeout, PauseTime, Content}}
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
                    handle_accept_error(Reason, "Failed to start connection on ~s: ~p", State),
                    close(Sock)
            end;
        {error, Reason} ->
            handle_accept_error(Reason, "Tune buffer failed on ~s: ~s", State),
            close(Sock)
    end,
    {next_state, waiting, State, {next_event, internal, begin_waiting}};
handle_event(state_timeout, {token_request, _} = Content, suspending, State) ->
    {next_state, token_request, State, {next_event, internal, Content}};
handle_event(state_timeout, begin_waiting, suspending, State) ->
    {next_state, waiting, State, {next_event, internal, begin_waiting}};
handle_event({call, From}, {set_conn_limiter, Limiter}, _, State) ->
    {keep_state, State#state{conn_limiter = Limiter}, {reply, From, ok}};
handle_event(
    info,
    {inet_async, LSock, Ref, {error, Reason}},
    _,
    State = #state{lsock = LSock, accept_ref = Ref}
) ->
    handle_socket_error(Reason, State);
handle_event(Type, Content, StateName, _) ->
    error_logger:warning_msg(
        "Unhandled message, State:~p, Type:~p Content:~p",
        [StateName, Type, Content]
    ),
    keep_state_and_data.

terminate(normal, _StateName, #state{}) ->
    ok;
terminate(Reason, _StateName, #state{}) ->
    error_logger:error_msg("~p terminating due to ~p", [?MODULE, Reason]),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

close(Sock) -> catch port_close(Sock).

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
    error_logger:error_msg(Msg, [esockd:format(Sockname), Reason]).

handle_socket_error(closed, State) ->
    {stop, normal, State};
%% {error, econnaborted} -> accept
%% {error, esslaccept}   -> accept
%% {error, esslaccept}   -> accept
handle_socket_error(Reason, State) when Reason =:= econnaborted; Reason =:= esslaccept ->
    {next_state, waiting, State, {next_event, internal, begin_waiting}};
%% emfile: The per-process limit of open file descriptors has been reached.
%% enfile: The system limit on the total number of open files has been reached.
%% enfile: The system limit on the total number of open files has been reached.
handle_socket_error(Reason, State) when Reason =:= emfile; Reason =:= enfile ->
    error_logger:error_msg(
        "Accept error on ~s: ~s",
        [esockd:format(State#state.sockname), explain_posix(Reason)]
    ),
    {next_state, suspending, State, {state_timeout, 1000, begin_waiting}};
handle_socket_error(Reason, State) ->
    {stop, Reason, State}.

explain_posix(emfile) ->
    "EMFILE (Too many open files)";
explain_posix(enfile) ->
    "ENFILE (File table overflow)".
