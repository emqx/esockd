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

-module(esockd_dtls_acceptor).

-behaviour(gen_statem).

-include("esockd.hrl").

-export([start_link/7]).

-export([ accepting/3
        , suspending/3
        ]).

%% gen_statem callbacks
-export([ init/1
        , callback_mode/0
        , terminate/3
        , code_change/4
        ]).

-record(state, {
          proto        :: atom(),
          listen_on    :: esockd:listen_on(),
          lsock        :: ssl:sslsocket(),
          sockname     :: {inet:ip_address(), inet:port_number()},
          tune_fun     :: esockd:sock_fun(),
          upgrade_funs :: [esockd:sock_fun()],
          conn_limiter :: undefined | esockd_generic_limiter:limiter(),
          conn_sup     :: pid()
         }).

%% @doc Start an acceptor
-spec(start_link(atom(), esockd:listen_on(), pid(),
                 esockd:sock_fun(), [esockd:sock_fun()],
                 esockd_generic_limiter:limiter(), inet:socket())
      -> {ok, pid()} | {error, term()}).
start_link(Proto, ListenOn, ConnSup,
           TuneFun, UpgradeFuns, Limiter, LSock) ->
    gen_statem:start_link(?MODULE, [Proto, ListenOn, ConnSup,
                                    TuneFun, UpgradeFuns, Limiter, LSock], []).

%%--------------------------------------------------------------------
%% gen_statem callbacks
%%--------------------------------------------------------------------

init([Proto, ListenOn, ConnSup,
      TuneFun, UpgradeFuns, Limiter, LSock]) ->
    _ = rand:seed(exsplus, erlang:timestamp()),
    {ok, Sockname} = ssl:sockname(LSock),
    {ok, accepting, #state{proto        = Proto,
                           listen_on    = ListenOn,
                           lsock        = LSock,
                           sockname     = Sockname,
                           tune_fun     = TuneFun,
                           upgrade_funs = UpgradeFuns,
                           conn_limiter = Limiter,
                           conn_sup     = ConnSup},
     {next_event, internal, accept}}.

callback_mode() -> state_functions.

accepting(internal, accept,
          State = #state{proto        = Proto,
                         listen_on    = ListenOn,
                         lsock        = LSock,
                         sockname     = Sockname,
                         tune_fun     = TuneFun,
                         upgrade_funs = UpgradeFuns,
                         conn_sup     = ConnSup}) ->
    case ssl:transport_accept(LSock) of
        {ok, Sock} ->
            %% Inc accepted stats.
            _ = esockd_server:inc_stats({Proto, ListenOn}, accepted, 1),
            _ = case eval_tune_socket_fun(TuneFun, Sock) of
                {ok, Sock} ->
                    case esockd_connection_sup:start_connection(ConnSup, Sock, UpgradeFuns) of
                        {ok, _Pid} -> ok;
                        {error, enotconn} ->
                            close(Sock); %% quiet...issue #10
                        {error, einval} ->
                            close(Sock); %% quiet... haproxy check
                        {error, Reason} ->
                            error_logger:error_msg("Failed to start connection on ~s: ~p",
                                                   [esockd:format(Sockname), Reason]),
                            close(Sock)
                        end;
                {error, enotconn} ->
                    close(Sock);
                {error, einval} ->
                    close(Sock);
                {error, closed} ->
                    close(Sock);
                {error, Reason} ->
                    error_logger:error_msg("Tune buffer failed on ~s: ~s",
                                           [esockd:format(Sockname), Reason]),
                    close(Sock)
            end,
            rate_limit(State);
        {error, Reason} when Reason =:= emfile;
                             Reason =:= enfile ->
            {next_state, suspending, State, 1000};
        {error, closed} ->
            {stop, normal, State};
        {error, Reason} ->
            {stop, Reason, State}
    end.

suspending(timeout, _Timeout, State) ->
    {next_state, accepting, State, {next_event, internal, accept}};

suspending(cast, {set_conn_limiter, Limiter}, State) ->
    {keep_state, State#state{conn_limiter = Limiter}}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

close(Sock) -> ssl:close(Sock).

rate_limit(State = #state{conn_limiter = Limiter}) ->
    case esockd_generic_limiter:consume(1, Limiter) of
        {ok, Limiter2} ->
            {keep_state,
             State#state{conn_limiter = Limiter2},
             {next_event, internal, accept}};
        {pause, PauseTime, Limiter2} ->
            {next_state, suspending, State#state{conn_limiter = Limiter2}, PauseTime}
    end.

eval_tune_socket_fun({Fun, Args1}, Sock) ->
    apply(Fun, [Sock|Args1]).
