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
%%% Simple Echo Server.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(echo_server).

-export([start/0, start/1]).

%%callback 
-export([accept/2, loop/1]).

-define(TCP_OPTIONS, [
		%binary,
		%{packet, raw},
		{reuseaddr, true},
		{backlog, 1024},
		{nodelay, false}]).

%%------------------------------------------------------------------------------
%% @doc
%% Start echo server.
%%
%% @end
%%------------------------------------------------------------------------------
start() ->
    start(5000).
%% shell
start([Port]) when is_atom(Port) ->
    start(list_to_integer(atom_to_list(Port)));
start(Port) when is_integer(Port) ->
    application:start(sasl),
    {ok, LSock} = gen_tcp:listen(Port, [{active, false} | ?TCP_OPTIONS]),
    io:format("Listening on ~p~n", [Port]),
    spawn(?MODULE, accept, [self(), LSock]),
    mainloop().

mainloop() ->
    receive 
        {accecpted, PeerName} -> 
            io:format("Accept from ~p~n", [PeerName]),
            mainloop()
    end.

accept(Parent, LSock) ->
    {ok, Sock} = gen_tcp:accept(LSock),
    {ok, PeerName} = inet:peername(Sock),
    Parent ! {accepted, PeerName},
    spawn(?MODULE, accept, [Parent, LSock]),
    loop(Sock).

loop(Sock) ->
	case gen_tcp:recv(Sock, 0, 30000) of
		{ok, Data} ->
			{ok, PeerName} = inet:peername(Sock),
			io:format("~s - ~s~n", [esockd_net:format(peername, PeerName), Data]),
			gen_tcp:send(Sock, Data),
			loop(Sock);
		{error, Reason} ->
			io:format("tcp ~s~n", [Reason]),
			{stop, Reason}
	end.
    
