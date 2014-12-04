
-module(echo_client).

-export([start/2, send/2, loop/2]).

start(Port, N) ->
	connect(Port, N).

connect(_Port, 0) ->
	ok;

connect(Port, N) ->
	spawn(fun() ->
		{ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {packet, raw}, {active, true}]),
		send(N, Sock)
	end),
    timer:sleep(10),
	connect(Port, N-1).

send(N, Sock) ->
	gen_tcp:send(Sock, iolist_to_binary(["Hello from ", integer_to_list(N)])),
	loop(N, Sock).

loop(N, Sock) ->
	receive
		{tcp, Sock, Data} -> 
            io:format("~p received: ~s~n", [N, Data]), 
            loop(N, Sock);
		{tcp_closed, Sock} -> io:format("~p socket closed~n", [N]);
		{tcp_error, Sock, Reason} -> io:format("~p socket error: ~p~n", [N, Reason]);
		Other -> io:format("what's the fuck: ~p", [Other])
	after
		5000 -> send(N, Sock)
	end.
	 

