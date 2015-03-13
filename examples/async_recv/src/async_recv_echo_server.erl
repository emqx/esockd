%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2014-2015, Feng Lee <feng@emqtt.io>
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
%%% @doc
%%% Async Recv Echo Server.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(async_recv_echo_server).

-behaviour(gen_server).

%% start
-export([start/0, start/1]).

-export([start_link/1]).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {transport, sock}).

-define(TCP_OPTIONS, [
		binary,
		{packet, raw},
		{reuseaddr, true},
		{backlog, 512},
		{nodelay, false}]).
%% API
start() ->
    start(5000).
start([Port]) when is_atom(Port) ->
    start(a2i(Port));
start(Port) when is_integer(Port) ->
    ok = esockd:start(),
    SockOpts = [{acceptors, 10}, 
                {max_clients, 1024} | ?TCP_OPTIONS],
    MFArgs = {?MODULE, start_link, []},
    esockd:open(echo, Port, SockOpts, MFArgs).

%% eSockd Callbacks
start_link(SockArgs) ->
	{ok, proc_lib:spawn_link(?MODULE, init, [SockArgs])}.

init(SockArgs = {Transport, _Sock, _SockFun}) ->
    {ok, NewSock} = esockd_connection:accept(SockArgs),
    Transport:async_recv(NewSock, 0, infinity),
    gen_server:enter_loop(?MODULE, [], #state{transport = Transport, sock = NewSock}).

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({inet_async, Sock, _Ref, {ok, Data}}, State = #state{transport = Transport, sock = Sock}) ->
	{ok, PeerName} = Transport:peername(Sock),
    io:format("~s - ~s~n", [esockd_net:format(peername, PeerName), Data]),
	Transport:send(Sock, Data),
    Transport:async_recv(Sock, 0, infinity),
    {noreply, State};

handle_info({inet_async, _Sock, _Ref, {error, Reason}}, State) ->
    {stop, {shutdown, {inet_async_error, Reason}}, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

a2i(A) -> list_to_integer(atom_to_list(A)).

