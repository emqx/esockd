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
%%% eSockd connection api.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_connection).

%%FIXME: this module should be rewrite...

-author('feng@emqtt.io').

-export([start_link/2, ready/2, accept/1]).

-spec start_link(Callback, Sock) -> {ok, pid()} | {error, any()} when
		Callback :: esockd:callback(), 
		Sock :: inet:socket().
start_link(Callback, SockArgs = {_Transport, _Sock, _SockFun}) ->
	case call(Callback, SockArgs) of
	{ok, Pid} -> {ok, Pid};
	{error, Error} -> {error, Error}
	end.

%%
%% @doc called by acceptor
%%
ready(Conn, SockArgs = {_Transport, _Sock, _SockFun}) ->
	Conn ! {ready, SockArgs}.

%%
%% @doc called by connection proccess when finished.
%%
accept(SockArgs = {_Transport, Sock, SockFun}) ->
	receive {ready, SockArgs} -> ok end,
    case SockFun(Sock) of
        {ok, NewSock} ->
            {ok, NewSock};
        {error, Error} ->
            exit({shutdown, Error})
    end.

call({M, F}, SockArgs) ->
    M:F(SockArgs);

call({M, F, A}, SockArgs) ->
    erlang:apply(M, F, [SockArgs | A]);

call(Mod, SockArgs) when is_atom(Mod) ->
    Mod:start_link(SockArgs);

call(Fun, SockArgs) when is_function(Fun) ->
    Fun(SockArgs).


