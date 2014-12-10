%%------------------------------------------------------------------------------
%% Copyright (c) 2014, Feng Lee <feng@slimchat.io>
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

-module(echo_test).

-export([start/1, start/2,
		stop/1]).

-define(TCP_OPTIONS, [
		binary, 
		{packet, raw}, 
		{reuseaddr, true}, 
		{backlog, 512}, 
		{nodelay, false}]). 

start([Port]) when is_atom(Port) ->
	start(Port, echo_server);

start([Port, Server]) when is_atom(Port), is_atom(Server) ->
	start(list_to_integer(atom_to_list(Port)), Server).

start(Port, Server) when is_integer(Port), is_atom(Server) ->
    esockd:start(),
	MFArgs = {Server, start_link, []},
    esockd:listen(echo, Port, [{acceptor_pool, 10}, {max_conns, 2048}|?TCP_OPTIONS], MFArgs).

stop(Port) ->
    esockd:stop(echo, Port).
