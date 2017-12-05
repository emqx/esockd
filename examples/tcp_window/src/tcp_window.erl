%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2014-2017, Feng Lee <feng@emqtt.io>
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

-module(tcp_window).

-export([main/0, main/1]).

%% Callback 
-export([start_server/2, server_init/2, server_loop/2]).

-define(TCP_OPTIONS,
        [binary,
         {active, false},
         {packet, raw},
         {recbuf, 1024},
         {sndbuf, 1024},
         {send_timeout, 3000}]).

main() -> main(5000, sync).

main([Port, Type]) when is_atom(Port) ->
    main(list_to_integer(atom_to_list(Port)), Type).

main(Port, Type) when is_integer(Port) ->
    lists:foreach(fun application:ensure_all_started/1, [sasl, crypto, gen_logger, esockd]),
    SockOpts = [{access, [{allow, all}]},
                {acceptors, 1}, 
                {shutdown, infinity},
                {max_clients, 100},
                {sockopts, ?TCP_OPTIONS}],
    esockd:open(tcp_block, Port, SockOpts, {?MODULE, start_server, [Type]}),
    start_client(Port).

start_server(Conn, Type) ->
	{ok, spawn_link(?MODULE, server_init, [Conn, Type])}.

server_init(Conn0, Type) ->
    {ok, Conn} = Conn0:wait(),
    io:format("sockopts: ~p~n", [Conn:getopts([send_timeout, send_timeout_close])]),
    server_loop(Conn, send_fun(Type, Conn)).

server_loop(Conn, SendFun) ->
	case Conn:recv(0) of
		{ok, Data} ->
			{ok, PeerName} = Conn:peername(),
            io:format("server recv: ~p from (~s)~n", [Data, esockd_net:format(peername, PeerName)]),
			SendFun(Data),
            %% flood the tcp window of client
            send_loop(Conn, SendFun, Data, 0);
		{error, Reason} ->
            io:format("server tcp error ~s~n", [Reason]),
            Conn:fast_close(),
			{stop, Reason}
	end.

send_loop(Conn, SendFun, Data, Count) ->
    case SendFun(Data) of
        true ->
            io:format("Send ~w~n", [Count]),
            io:format("Stats: ~p~n", [Conn:getstat([send_cnt])]),
            send_loop(Conn, SendFun, Data, Count + iolist_size(Data));
        false ->
            io:format("False Send ~w~n", [Count]),
            send_loop(Conn, SendFun, Data, Count + iolist_size(Data));
        ok ->
            io:format("Send ~w~n", [Count]),
            send_loop(Conn, SendFun, Data, Count + iolist_size(Data));
        {error, Error} ->
            io:format("Send error: ~p~n", [Error]),
            Conn:fast_close()
    end.

start_client(Port) ->
	case gen_tcp:connect("127.0.0.1", Port, ?TCP_OPTIONS, 60000) of
        {ok, Sock} ->
            inet:setopts(Sock, [{active, false}]),
            client_loop(Sock, 0);
        {error, Reason} ->
            io:format("client failed to connect: ~p~n", [Reason])
    end.

client_loop(Sock, I) ->
    gen_tcp:send(Sock, crypto:strong_rand_bytes(1024*1024)),
    timer:sleep(100000),
    case gen_tcp:recv(Sock, 0) of
        {ok, Data} ->
            io:format("client recv: ~p~n", [Data]),
            client_loop(Sock, I+1);
        {error, Reason} ->
            io:format("client tcp error: ~p~n", [Reason]),
            gen_tcp:close(Sock)
    end.

send_fun(sync, Conn) ->
    fun(Data) -> Conn:send(Data) end;
send_fun(async, Conn) ->
    fun(Data) -> port_command(Conn:sock(), Data) end;
send_fun(async_force, Conn) ->
    fun(Data) -> port_command(Conn:sock(), Data, [force]) end;
send_fun(async_nosuspend, Conn) ->
    fun(Data) -> port_command(Conn:sock(), Data, [nosuspend]) end.

