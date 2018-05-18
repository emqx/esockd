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
%%% @doc
%%% Proxy Protcol Echo Server.
%%%
%%% @end
%%%===================================================================

-module(proxy_protocol_server).

-include("../include/esockd.hrl").

-behaviour(gen_server).

%% start
-export([start/0, start/1]).

%% esockd callback
-export([start_link/2]).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {transport, sock}).

start() -> start(5000).
%% shell
start([Port]) when is_atom(Port) ->
    start(list_to_integer(atom_to_list(Port)));
start(Port) when is_integer(Port) ->
    ok = application:start(sasl),
    ok = esockd:start(),
    Options = [{tcp_options, [binary]},
               proxy_protocol,
               {proxy_protocol_timeout, 1000}],
    MFArgs = {?MODULE, start_link, []},
    esockd:open(echo, Port, Options, MFArgs).

start_link(Transport, Sock) ->
	{ok, proc_lib:spawn_link(?MODULE, init, [[Transport, Sock]])}.

init([Transport, Sock]) ->
    case Transport:wait(Sock) of
        {ok, NewSock} ->
            Transport:setopts(NewSock, [{active, once}]),
            State = #state{transport = Transport, sock = Sock},
            gen_server:enter_loop(?MODULE, [], State);
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Req, _From, State) ->
    {reply, ignore, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, Sock, Data},
            State = #state{transport = Transport, sock = Sock}) ->
	{ok, Peername} = Transport:peername(Sock),
	io:format("Data from ~s - ~s~n",
              [esockd_net:format(peername, Peername), Data]),
	Transport:send(Sock, Data),
	Transport:setopts(Sock, [{active, once}]),
    {noreply, State};

handle_info({tcp_error, _Sock, Reason}, State) ->
	io:format("TCP Error: ~s~n", [Reason]),
    {stop, {shutdown, Reason}, State};

handle_info({tcp_closed, _Sock}, State) ->
	io:format("TCP Closed~n"),
	{stop, normal, State};

handle_info(Info, State) ->
    io:format("Unexpected Info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

