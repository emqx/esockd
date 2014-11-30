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
-module(esockd_client).

%%FIXME: this module should be rewrite...

-export([start_link/2,
		 ready/3,
		 accepted/1]).

start_link(Callback, Sock) ->
	{ok, _Pid} = callback(Callback, Sock).

%%
%% @doc called by acceptor
%%
ready(Pid, Acceptor, Sock) ->
	Pid ! {ready, Acceptor, Sock}.

%%
%% @doc called by client
%%
accepted(Socket) ->
	receive {ready, _, Socket} -> ok end.

callback({M, F}, Sock) ->
    M:F(Sock);

callback({M, F, A}, Sock) ->
    erlang:apply(M, F, [Sock | A]);

callback(Mod, Sock) when is_atom(Mod) ->
    Mod:start_link(Sock);

callback(Fun, Sock) when is_function(Fun) ->
    Fun(Sock).

