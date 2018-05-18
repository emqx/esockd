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

-module(ssl_echo_server).

-export([start/0, start/1]).

-export([start_link/2, init/2, loop/2]).

start() -> start(5000).

start(Port) ->
    [{ok, _} = application:ensure_all_started(App)
     || App <- [sasl, crypto, ssl, esockd]],
    TcpOpts = [binary, {reuseaddr, true}],
    %{cacertfile, "./crt/cacert.pem"},
    SslOpts = [{certfile, "./crt/demo.crt"},
               {keyfile,  "./crt/demo.key"}],
    Opts = [{acceptors, 4},
            {max_clients, 1000},
            {tcp_options, TcpOpts},
            {ssl_options, SslOpts}],
    {ok, _} = esockd:open('echo/ssl', Port, Opts, ssl_echo_server).

start_link(Transport, Sock) ->
    {ok, spawn_link(?MODULE, init, [Transport, Sock])}.

init(Transport, Sock) ->
    case Transport:wait(Sock) of
        {ok, NewSock} ->
            loop(Transport, NewSock);
        Error -> Error
    end.

loop(Transport, Sock) ->
    case Transport:recv(Sock, 0) of
        {ok, Data} ->
            {ok, PeerName} = Transport:peername(Sock),
            io:format("~s - ~p~n", [esockd_net:format(peername, PeerName), Data]),
            Transport:send(Sock, Data),
            loop(Transport, Sock);
        {error, Reason} ->
            io:format("tcp ~s~n", [Reason]),
            {stop, Reason}
    end.

