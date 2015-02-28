%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
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
%%% echo server.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ssl_echo_server).

%%callback 
-export([start_link/1, 
		 init/1,
		 loop/3]).

start_link(SockArgs) ->
	{ok, spawn_link(?MODULE, init, [SockArgs])}.

init(SockArgs = {Transport, _Sock, _SockFun}) ->
    {ok, NewSock} = esockd_connection:accept(SockArgs),
	loop(Transport, NewSock, state).

loop(Transport, Sock, State) ->
	case Transport:recv(Sock, 0) of
		{ok, Data} -> 
			{ok, Name} = Transport:peername(Sock),
			io:format("~p: ~p~n", [Name, Data]),
			Transport:send(Sock, Data),
			loop(Transport, Sock, State);
		{error, Reason} ->
			io:format("tcp ~s~n", [Reason]),
			{stop, Reason}
	end. 

