%%------------------------------------------------------------------------------
%% Copyright (c) 2014, Feng Lee <feng.lee@slimchat.io>
%% 
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%% 
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%------------------------------------------------------------------------------

-module(esockd).

-include("esockd.hrl").

-export([start/0, 
        listen/4, listen/5,
		close/2]).

%%
%% @doc start esockd application.
%%
-spec start() -> ok.
start() ->
    application:start(esockd).

%%
%% @doc listen on port.
%%
-spec listen(Protocol       :: atom(), 
             Port           :: inet:port_number(),
             SocketOpts     :: list(tuple()), 
             Callback       :: callback()) -> {ok, pid()}.
listen(Protocol, Port, SocketOpts, Callback)  ->
    listen(Protocol, Port, SocketOpts, 10, Callback).

%%
%% @doc listen on port with acceptor pool.
%%
-spec listen(Protocol       :: atom(), 
             Port           :: inet:port_number(),
             SocketOpts     :: list(tuple()), 
             AcceptorNum    :: integer(),
             Callback       :: callback()) -> {ok, pid()}.
listen(Protocol, Port, SocketOpts, AcceptorNum, Callback) ->
	esockd_sup:start_listener(Protocol, Port, SocketOpts, AcceptorNum, Callback).

%%
%% @doc close the listener.
%%
-spec close(Protocol    :: atom(),
            Port        :: inet:port_number()) -> ok.
close(Protocol, Port) when is_atom(Protocol) and is_integer(Port) ->
	esockd_sup:stop_listener(Protocol, Port).

