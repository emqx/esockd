%%%===================================================================
%%% Copyright (c) 2013-2018 EMQ Inc. All rights reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%===================================================================

-module(esockd_dtls_acceptor).

-behaviour(gen_statem).

-include("esockd.hrl").

-export([start_link/4]).

-export([waiting_for_sock/3, waiting_for_data/3]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, handle_event/4, terminate/3,
         code_change/4]).

-record(state, {sup, mfargs, max_clients, peername, lsock, sock, channel}).

start_link(Sup, Opts, MFA, LSock) ->
    gen_statem:start_link(?MODULE, [Sup, Opts, MFA, LSock], []).

init([Sup, Opts, MFA, LSock]) ->
    process_flag(trap_exit, true),
    State = #state{sup = Sup, mfargs = MFA,
                   max_clients = max_clients(Opts),
                   lsock = LSock},
    {ok, waiting_for_sock, State, {next_event, internal, accept}}.

max_clients(Opts) ->
    proplists:get_value(max_clients, Opts, 0).

callback_mode() -> state_functions.

waiting_for_sock(internal, accept, State = #state{sup = Sup, lsock = LSock,
                                                  mfargs = {M, F, Args}}) ->
    {ok, Sock} = ssl:transport_accept(LSock),
    esockd_dtls_acceptor_sup:start_acceptor(Sup, LSock),
    {ok, Peername} = ssl:peername(Sock),
    io:format("DTLS accept: ~p~n", [Peername]),
    case ssl:handshake(Sock, ?SSL_HANDSHAKE_TIMEOUT) of
        ok -> case erlang:apply(M, F, [self(), Peername | Args]) of
                  {ok, Pid} ->
                      link(Pid),
                      {next_state, waiting_for_data,
                       State#state{sock = Sock, peername = Peername, channel = Pid}};
                  {error, Reason} ->
                      {stop, Reason, State};
                  {'EXIT', Error} ->
                      shutdown(Error, State)
              end;
        {error, Reason} -> shutdown(Reason, State#state{sock = Sock})
    end;

waiting_for_sock(EventType, EventContent, StateData) ->
    handle_event(EventType, EventContent, waiting_for_sock, StateData).

waiting_for_data(info, {ssl, _Sock, Data}, State = #state{channel = Ch}) ->
    Ch ! {datagram, self(), Data},
    {keep_state, State};

waiting_for_data(info, {ssl_closed, _Socket}, State) ->
    {stop, {shutdown, closed}, State};

waiting_for_data(info, {datagram, _To, Data}, State = #state{sock = Sock}) ->
    case ssl:send(Sock, Data) of
        ok -> {keep_state, State};
        {error, Reason} ->
            shutdown(Reason, State)
    end;

waiting_for_data(info, {'EXIT', Ch, Reason}, State = #state{channel = Ch}) ->
    {stop, Reason, State};

waiting_for_data(EventType, EventContent, StateData) ->
    handle_event(EventType, EventContent, waiting_for_data, StateData).

handle_event(EventType, EventContent, StateName, StateData) ->
    error_logger:error_msg("StateName: ~s, Unexpected Event(~s, ~p)",
                           [StateName, EventType, EventContent]),
    {keep_state, StateData}.

terminate(_Reason, _StateName, #state{sock = undefined}) ->
    ok;
terminate(Reason, _StateName, #state{sock = Sock}) ->
    io:format("DTLS closed: ~p~n", [Reason]),
    ssl:close(Sock).

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

shutdown(Reason, State) ->
    {stop, {shutdown, Reason}, State}.

