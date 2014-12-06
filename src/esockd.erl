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

-export([start/0, 
        listen/4,
		close/2]).

-type mfargs() :: {module(), atom(), [term()]}.

-type callback() :: mfargs() | atom() | function().

-type option() :: 
		{acceptor_pool, non_neg_integer()} |
		{max_conns, non_neg_integer()} | 
		gen_tcp:listen_option().

-export_type([callback/0, option/0]).

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
             Options		:: [option()], 
             Callback       :: callback()) -> {ok, pid()}.
listen(Protocol, Port, Options, Callback)  ->
	esockd_sup:start_listener(Protocol, Port, Options, Callback).

%%
%% @doc close the listener.
%%
-spec close(Protocol    :: atom(),
            Port        :: inet:port_number()) -> ok.
close(Protocol, Port) when is_atom(Protocol) and is_integer(Port) ->
	esockd_sup:stop_listener(Protocol, Port).

