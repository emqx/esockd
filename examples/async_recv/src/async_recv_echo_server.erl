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

-include("../../../include/esockd.hrl").

-behaviour(gen_server).

%% start
-export([start/0, start/1]).

-export([start_link/1]).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {conn}).

-define(TCP_OPTIONS, [
		binary,
		{packet, raw},
        %{buffer, 1024},
		{reuseaddr, true},
		{backlog, 512},
		{nodelay, false}]).
%% API
start() ->
    start(5000).
start([Port]) when is_atom(Port) ->
    start(list_to_integer(atom_to_list(Port)));
start(Port) when is_integer(Port) ->
    [ok = application:start(App) ||
        App <- [sasl, syntax_tools, asn1, crypto, public_key, ssl]],
    ok = esockd:start(),
    SslOpts = [{certfile, "./crt/demo.crt"},
               {keyfile,  "./crt/demo.key"}],
    SockOpts = [{acceptors, 10},
                {max_clients, 100000},
                {ssl, SslOpts},
                {sockopts, ?TCP_OPTIONS}],
    MFArgs = {?MODULE, start_link, []},
    esockd:open(echo, Port, SockOpts, MFArgs).

%% eSockd Callbacks
start_link(Conn) ->
	{ok, proc_lib:spawn_link(?MODULE, init, [Conn])}.

init(Conn) ->
    {ok, Conn1} = Conn:ack(),
    Conn1:async_recv(0, infinity),
    gen_server:enter_loop(?MODULE, [], #state{conn = Conn1}).

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({inet_async, Sock, _Ref, {ok, Data}}, State = #state{conn = ?ESOCK(Sock) = Conn}) ->
	{ok, PeerName} = Conn:peername(),
    io:format("~s - ~s~n", [esockd_net:format(peername, PeerName), Data]),
	Conn:async_send(Data),
    Conn:async_recv(0, infinity),
    {noreply, State};

handle_info({inet_async, Sock, _Ref, {error, Reason}}, State = #state{conn = ?ESOCK(Sock)}) ->
    io:format("shutdown for ~p~n", [Reason]),
    shutdown(Reason, State);

handle_info({inet_reply, Sock ,ok}, State = #state{conn = ?ESOCK(Sock)}) ->
    io:format("inet_reply ~p ok~n", [Sock]),
    {noreply, State};

handle_info({inet_reply, Sock, {error, Reason}}, State = #state{conn = ?ESOCK(Sock)}) ->
    io:format("shutdown for ~p~n", [Reason]),
    shutdown(Reason, State);

handle_info(Info, State) ->
    io:format("~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

shutdown(Reason, State) ->
    {stop, {shutdown, Reason}, State}.

