
-module(echo_server).

%% Callbacks
-export([start_link/1, init/1, loop/1]).

start_link(Conn) ->
	{ok, spawn_link(?MODULE, init, [Conn])}.

init(Conn) ->
    {ok, NewConn} = Conn:wait(), loop(NewConn).

loop(Conn) ->
	case Conn:recv(0) of
        {ok, Data} ->
            {ok, PeerName} = Conn:peername(),
            io:format("~s - ~s~n", [esockd_net:format(peername, PeerName), Data]),
            Conn:send(Data),
            loop(Conn);
        {error, Reason} ->
            io:format("tcp ~s~n", [Reason]),
            exit({shutdown, Reason})
	end.

