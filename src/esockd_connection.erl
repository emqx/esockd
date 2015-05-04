%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2015 eMQTT.IO, All Rights Reserved.
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

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-export([start_link/2, ready/2, accept/1, transform/1]).

%%------------------------------------------------------------------------------
%% @doc Start a connection.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(SockArgs, MFArgs) -> {ok, pid()} | {error, any()} | ignore when
		SockArgs :: esockd:sock_args(),
		MFArgs   :: esockd:mfargs(). 
start_link(SockArgs, MFArgs) ->
	case call(SockArgs, MFArgs) of
        {ok, Pid}       -> {ok, Pid};
        ignore          -> ignore;
        {error, Error}  -> {error, Error}
	end.

%%------------------------------------------------------------------------------
%% @doc Tell the connection that socket is ready. Called by acceptor.
%% @end
%%------------------------------------------------------------------------------
-spec ready(Conn, SockArgs) -> any() when
        Conn     :: pid(),
        SockArgs :: esockd:sock_args().
ready(Conn, SockArgs = {_Transport, _Sock, _SockFun}) ->
	Conn ! {sock_ready, SockArgs}.

%%------------------------------------------------------------------------------
%% @doc Connection accept the socket. Called by connection.
%% @end
%%------------------------------------------------------------------------------
-spec accept(SockArgs) -> {ok, NewSock} when
    SockArgs    :: esockd:sock_args(),
    NewSock     :: inet:socket() | esockd:ssl_socket().
accept(SockArgs) ->
	receive
        {sock_ready, SockArgs} -> transform(SockArgs)
    end.

%%------------------------------------------------------------------------------
%% @doc Transform Socket. Callbed by connection proccess.
%% @end
%%------------------------------------------------------------------------------
transform({_Transport, Sock, SockFun}) ->
    case SockFun(Sock) of
        {ok, NewSock} ->
            {ok, NewSock};
        {error, Error} ->
            exit({shutdown, Error})
    end.

call(SockArgs, M) when is_atom(M) ->
    M:start_link(SockArgs);

call(SockArgs, {M, F}) when is_atom(M), is_atom(F) ->
    M:F(SockArgs);

call(SockArgs, {M, F, Args}) when is_atom(M), is_atom(F) ->
    erlang:apply(M, F, [SockArgs|Args]).

