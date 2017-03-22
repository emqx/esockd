%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2017 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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
%%% Proxy Protcol Echo Server.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(proxy_protocol_server).

-include("../../../include/esockd.hrl").

-behaviour(gen_server).

%% start
-export([start/0, start/1]).

%% esockd callback 
-export([start_link/1]).

%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {conn}).

start() -> start(5000).
%% shell
start([Port]) when is_atom(Port) ->
    start(list_to_integer(atom_to_list(Port)));
start(Port) when is_integer(Port) ->
    application:start(sasl),
    ok = esockd:start(),
    SockOpts = [{sockopts, [binary]}, {connopts, [proxy_protocol, {proxy_protocol_timeout, 1000}]}],
    MFArgs = {?MODULE, start_link, []},
    esockd:open(echo, Port, SockOpts, MFArgs).

start_link(Conn) ->
	{ok, proc_lib:spawn_link(?MODULE, init, [Conn])}.

init(Conn) ->
    {ok, Conn1} = Conn:wait(),
    io:format("Proxy Conn: ~p~n", [Conn1]),
    Conn1:setopts([{active, once}]),
    gen_server:enter_loop(?MODULE, [], #state{conn = Conn1}).

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({tcp, _Sock, Data}, State=#state{conn = Conn}) ->
	{ok, PeerName} = Conn:peername(),
	{ok, SockName} = Conn:sockname(),
    io:format("Data from ~p to ~p~n", [PeerName, SockName]),
	io:format("~s - ~s~n", [esockd_net:format(peername, PeerName), Data]),
	Conn:send(Data),
	Conn:setopts([{active, once}]),
    {noreply, State};

handle_info({tcp_error, _Sock, Reason}, State=#state{conn = _Conn}) ->
	io:format("tcp_error: ~s~n", [Reason]),
    {stop, {shutdown, {tcp_error, Reason}}, State};

handle_info({tcp_closed, _Sock}, State=#state{conn = _Conn}) ->
	io:format("tcp_closed~n"),
	{stop, normal, State};

handle_info(Info, State) ->
    io:format("Unexpected Info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

