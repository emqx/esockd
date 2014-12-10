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

-export([start_link/2, go/2, ack/1]).

-spec start_link(Callback, Sock) -> {ok, pid()} | {error, any()} when
		Callback :: esockd:callback(), 
		Sock :: inet:socket().

start_link(Callback, Sock) ->
	case call(Callback, Sock) of
	{ok, Pid} -> link(Pid), {ok, Pid};
	{error, Error} -> {error, Error}
	end.

%%
%% @doc called by acceptor
%%
go(Client, Sock) ->
	Client ! {go, Sock}.

%%
%% @doc called by client
%%
ack(Sock) ->
	receive {go, Sock} -> ok end.

call({M, F}, Sock) ->
    M:F(Sock);

call({M, F, A}, Sock) ->
    erlang:apply(M, F, [Sock | A]);

call(Mod, Sock) when is_atom(Mod) ->
    Mod:start_link(Sock);

call(Fun, Sock) when is_function(Fun) ->
    Fun(Sock).

