%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2017, Feng Lee <feng@emqtt.io>
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

% start
-export([start/0, start/1]).

%% callback 
-export([start_link/1, init/1, loop/1]).

start() ->
    start(5000).

start(Port) ->
    [ok = application:start(App) ||
        App <- [sasl, syntax_tools, asn1, crypto, public_key, ssl]],
    ok = esockd:start(),
    %{cacertfile, "./crt/cacert.pem"}, 
    SslOpts = [{certfile, "./crt/demo.crt"},
               {keyfile,  "./crt/demo.key"}],
    SockOpts = [binary, {reuseaddr, true}],
    Opts = [{acceptors, 4},
            {max_clients, 1000},
            {sslopts, SslOpts},
            {sockopts, SockOpts}],
    {ok, _} = esockd:open('echo/ssl', Port, Opts, ssl_echo_server).

start_link(Conn) ->
    {ok, spawn_link(?MODULE, init, [Conn])}.

init(Conn) ->
    {ok, NewConn} = Conn:wait(),
    loop(NewConn).

loop(Conn) ->
    case Conn:recv(0) of
        {ok, Data} ->
            {ok, PeerName} = Conn:peername(),
            io:format("~s - ~p~n", [esockd_net:format(peername, PeerName), Data]),
            Conn:send(Data),
            Conn:gc(), %% Try GC?
            loop(Conn);
        {error, Reason} ->
            io:format("tcp ~s~n", [Reason]),
            {stop, Reason}
    end.

