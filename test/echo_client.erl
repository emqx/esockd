
-module(echo_client).

-export([start/1, start/2, send/2, run/3, connect/3, loop/2]).

start([Port, N]) when is_atom(Port), is_atom(N) ->
	start(a2i(Port), a2i(N)).

start(Port, N) ->
	spawn(?MODULE, run, [self(), Port, N]),
	mainloop(0).

mainloop(Count) ->
	receive
		{connected, _Sock} -> 
			io:format("conneted: ~p~n", [Count]),
			mainloop(Count+1)
	end.

run(_Parent, _Port, 0) ->
	ok;
run(Parent, Port, N) ->
	spawn(?MODULE, connect, [Parent, Port, N]),
    timer:sleep(2),
	run(Parent, Port, N-1).

connect(Parent, Port, N) ->
	{ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {packet, raw}, {active, true}]),
	Parent ! {connected, Sock},
	send(N, Sock).

send(N, Sock) ->
	random:seed(now()),
	Data = iolist_to_binary(lists:duplicate(128, "00000000")),
	gen_tcp:send(Sock, Data),
	loop(N, Sock).

loop(N, Sock) ->
	Timeout = 5000 + random:uniform(5000),
	receive
		{tcp, Sock, _Data} -> 
            %io:format("~p received: ~s~n", [N, Data]), 
            loop(N, Sock);
		{tcp_closed, Sock} -> 
			io:format("~p socket closed~n", [N]);
		{tcp_error, Sock, Reason} -> 
			io:format("~p socket error: ~p~n", [N, Reason]);
		Other -> 
			io:format("what's the fuck: ~p", [Other])
	after
		Timeout -> send(N, Sock)
	end.
	 
a2i(A) -> list_to_integer(atom_to_list(A)).
