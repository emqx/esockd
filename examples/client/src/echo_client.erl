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
%%% Echo Test Client.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(echo_client).

-export([start/1, start/3, send/2, run/4, connect/4, loop/2]).

-define(TCP_OPTIONS, [binary,
                      {packet, raw},
                      {buffer, 1024},
                      {active, true}]).

start([Port, Host, N]) when is_atom(Port), is_atom(Host), is_atom(N) ->
	start(a2i(Port), atom_to_list(Host), a2i(N)).

start(Port, Host, N) ->
	spawn(?MODULE, run, [self(), Host, Port, N]),
	mainloop(1).

mainloop(Count) ->
	receive
		{connected, _Sock} -> 
			io:format("conneted: ~p~n", [Count]),
			mainloop(Count+1)
	end.

run(_Parent, _Host, _Port, 0) ->
	ok;
run(Parent, Host, Port, N) ->
	spawn(?MODULE, connect, [Parent, Host, Port, N]),
	timer:sleep(5),
	run(Parent, Host, Port, N-1).

connect(Parent, Host, Port, N) ->
	case gen_tcp:connect(Host, Port, ?TCP_OPTIONS, 60000) of
    {ok, Sock} -> 
        Parent ! {connected, Sock},
        random:seed(now()),
        loop(N, Sock);
    {error, Error} ->
        io:format("client ~p connect error: ~p~n", [N, Error])
    end.

loop(N, Sock) ->
	Timeout = 5000+random:uniform(5000),
	receive
		{tcp, Sock, Data} -> 
            io:format("client ~p received: ~s~n", [N, Data]), 
            loop(N, Sock);
		{tcp_closed, Sock} -> 
			io:format("client ~p socket closed~n", [N]);
		{tcp_error, Sock, Reason} -> 
			io:format("client ~p socket error: ~p~n", [N, Reason]);
		Other -> 
			io:format("client ~p unexpected: ~p", [N, Other])
	after
		Timeout -> send(N, Sock), loop(N, Sock)
	end.

send(N, Sock) ->
	%Data = iolist_to_binary(lists:duplicate(128, "00000000")),
	gen_tcp:send(Sock, [integer_to_list(N), ":", <<"Hello, eSockd!">>]).
	 
a2i(A) -> list_to_integer(atom_to_list(A)).

