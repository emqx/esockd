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
%%% eSockd TCP/SSL Transport.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_transport).

-author('feng@emqtt.io').

-include("esockd.hrl").

-export([listen/2, send/2, port_command/2, recv/2, async_recv/3, close/1,controlling_process/2]).

-export([getopts/2, setopts/2, getstat/2]).

-export([sockname/1, peername/1, shutdown/2]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Listen.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec listen(Port, SockOpts) -> {ok, Socket} | {error, Reason :: any()} when
    Port        :: inet:port_number(),
    SockOpts    :: [gen_tcp:listen_option()],
    Socket      :: inet:socket().
listen(Port, SockOpts) ->
    gen_tcp:listen(Port, SockOpts).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Set Controlling Process of Socket.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec controlling_process(Socket, NewOwener) -> ok | {error, Reason :: any()} when
    Socket      :: inet:socket() | ssl_socket(),
    NewOwener   :: pid().
controlling_process(Socket, NewOwner) when is_port(Socket) ->
    inet:tcp_controlling_process(Socket, NewOwner);
controlling_process(#ssl_socket{ssl = SslSocket}, NewOwner) ->
    ssl:controlling_process(SslSocket, NewOwner).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Close Socket.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec close(Socket :: inet:socket() | ssl_socket()) -> ok.
close(Socket) when is_port(Socket) ->
    gen_tcp:close(Socket);
close(#ssl_socket{ssl = SslSocket}) ->
    ssl:close(SslSocket).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Send data.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec send(Socket, Data) -> ok when
    Socket  :: inet:socket() | ssl_socket(),
    Data    :: iolist().
send(Socket, Data) when is_port(Socket) ->
    gen_tcp:send(Socket, Data);
send(#ssl_socket{ssl = SslSocket}, Data) ->
    ssl:send(SslSocket, Data).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Port command to write data.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
port_command(Sock, Data) when is_port(Sock) ->
    erlang:port_command(Sock, Data);
port_command(Socket = #ssl_socket{ssl = SslSocket}, Data) ->
    case ssl:send(SslSocket, Data) of
        ok -> self() ! {inet_reply, Socket, ok}, true;
        {error, Reason} -> erlang:error(Reason)
    end.

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Receive data.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec recv(Socket, Length) -> {ok, Data} | {error, Reason :: any()} when
    Socket  :: inet:socket() | ssl_socket(),
    Length  :: non_neg_integer(),
    Data    :: [char()] | binary().
recv(Socket, Length) when is_port(Socket) ->
    gen_tcp:recv(Socket, Length);
recv(#ssl_socket{ssl = SslSocket}, Length)  ->
    ssl:recv(SslSocket, Length).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Async Receive data.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec async_recv(Socket, Length, Timeout) -> {ok, Ref} when
    Socket  :: inet:socket() | ssl_socket(),
    Length  :: non_neg_integer(),
    Timeout :: non_neg_integer() | infinity,
    Ref     :: reference().
async_recv(Socket = #ssl_socket{ssl = SslSocket}, Length, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    spawn(fun () -> Self ! {inet_async, Socket, Ref,
        ssl:recv(SslSocket, Length, Timeout)}
    end),
    {ok, Ref};
async_recv(Socket, Length, infinity) when is_port(Socket) ->
    prim_inet:async_recv(Socket, Length, -1);
async_recv(Socket, Length, Timeout) when is_port(Socket) ->
    prim_inet:async_recv(Socket, Length, Timeout).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Get socket options.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
getopts(Socket, OptionNames) when is_port(Socket) ->
    inet:getopts(Socket, OptionNames);
getopts(#ssl_socket{ssl = SslSocket}, OptionNames) ->
    ssl:getopts(SslSocket, OptionNames).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Set socket options.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
setopts(Socket, Options) when is_port(Socket) ->
    inet:setopts(Socket, Options);
setopts(#ssl_socket{ssl = SslSocket}, Options) ->
    ssl:setopts(SslSocket, Options).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Get socket stats.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec getstat(Socket, Stats) -> {ok, Values} | {error, any()} when
    Socket  :: inet:socket() | ssl_socket(),
    Stats   :: list(),
    Values  :: list().
getstat(Socket, Stats) when is_port(Socket) ->
    inet:getstat(Socket, Stats);
getstat(#ssl_socket{tcp = Socket}, Stats) ->
    inet:getstat(Socket, Stats).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Socket name.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec sockname(Socket) -> {ok, {Address, Port}} | {error, any()} when
    Socket  :: inet:socket() | ssl_socket(),
    Address :: inet:ip_address(),
    Port    :: inet:port_number().
sockname(Socket) when is_port(Socket) ->
    inet:sockname(Socket);
sockname(#ssl_socket{ssl = SslSocket}) ->
    ssl:sockname(SslSocket).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Socket peer name.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec peername(Socket) -> {ok, {Address, Port}} | {error, any()} when
    Socket  :: inet:socket() | ssl_socket(),
    Address :: inet:ip_address(),
    Port    :: inet:port_number().
peername(Socket) when is_port(Socket) ->
    inet:peername(Socket);
peername(#ssl_socket{ssl = SslSocket}) ->
    ssl:peername(SslSocket).

%%%-----------------------------------------------------------------------------
%%% @doc
%%% Shutdown socket.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-spec shutdown(Socket, How) -> ok | {error, Reason :: any()} when
    Socket  :: inet:socket() | ssl_socket,
    How     :: read | write | read_write.
shutdown(Socket, How) when is_port(Socket) ->
    gen_tcp:shutdown(Socket, How);
shutdown(#ssl_socket{ssl = SslSocket}, How) ->
    ssl:shutdown(SslSocket, How).

%%%=============================================================================
%%% Internal functions
%%%=============================================================================