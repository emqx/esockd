%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2017 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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
%%% eSockd TCP/SSL Socket Acceptor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_acceptor).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-behaviour(gen_server).

-export([start_link/6]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {lsock       :: inet:socket(),
                sockfun     :: esockd:sock_fun(),
                tunefun     :: esockd:tune_fun(),
                sockname    :: iolist(),
                conn_sup    :: pid(),
                statsfun    :: fun(),
                logger      :: gen_logger:logmod(),
                ref         :: reference(),
                emfile_count = 0}).

%% @doc Start Acceptor
-spec(start_link(ConnSup, AcceptStatsFun, BufferTuneFun, Logger, LSock, SockFun) -> {ok, pid()} | {error, any()} when
      ConnSup        :: pid(),
      AcceptStatsFun :: fun(),
      BufferTuneFun  :: esockd:tune_fun(),
      Logger         :: gen_logger:logmod(),
      LSock          :: inet:socket(),
      SockFun        :: esockd:sock_fun()).
start_link(ConnSup, AcceptStatsFun, BufTuneFun, Logger, LSock, SockFun) ->
    gen_server:start_link(?MODULE, {ConnSup, AcceptStatsFun, BufTuneFun, Logger, LSock, SockFun}, []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init({ConnSup, AcceptStatsFun, BufferTuneFun, Logger, LSock, SockFun}) ->
    {ok, SockName} = inet:sockname(LSock),
    gen_server:cast(self(), accept),
    {ok, #state{lsock    = LSock,
                sockfun  = SockFun,
                tunefun  = BufferTuneFun,
                sockname = esockd_net:format(sockname, SockName),
                conn_sup = ConnSup,
                statsfun = AcceptStatsFun,
                logger   = Logger}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(accept, State) ->
    accept(State);

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({inet_async, LSock, Ref, {ok, Sock}}, State = #state{lsock    = LSock,
                                                                 sockfun  = SockFun,
                                                                 tunefun  = BufferTuneFun,
                                                                 sockname = SockName,
                                                                 conn_sup = ConnSup,
                                                                 statsfun = AcceptStatsFun,
                                                                 logger   = Logger,
                                                                 ref      = Ref}) ->

    %% patch up the socket so it looks like one we got from gen_tcp:accept/1
    {ok, Mod} = inet_db:lookup_socket(LSock),
    inet_db:register_socket(Sock, Mod),

    %% accepted stats.
    AcceptStatsFun({inc, 1}),

    %% Fix issues#9: enotconn error occured...
	%% {ok, Peername} = inet:peername(Sock),
    %% Logger:info("~s - Accept from ~s", [SockName, esockd_net:format(peername, Peername)]),
    case BufferTuneFun(Sock) of
        ok ->
            case esockd_connection_sup:start_connection(ConnSup, Mod, Sock, SockFun) of
                {ok, _Pid}        -> ok;
                {error, enotconn} -> catch port_close(Sock); %% quiet...issue #10
                {error, einval}   -> catch port_close(Sock); %% quiet... haproxy check
                {error, Reason}   -> catch port_close(Sock),
                                     Logger:error("Failed to start connection on ~s - ~p", [SockName, Reason])
            end;
        {error, enotconn} ->
			catch port_close(Sock);
        {error, Err} ->
            Logger:error("failed to tune buffer size of connection accepted on ~s - ~s", [SockName, Err]),
            catch port_close(Sock)
    end,
    %% accept more
    accept(State);

handle_info({inet_async, LSock, Ref, {error, closed}},
            State=#state{lsock=LSock, ref=Ref}) ->
    %% It would be wrong to attempt to restart the acceptor when we
    %% know this will fail.
    {stop, normal, State};

%% {error, econnaborted} -> accept
handle_info({inet_async, LSock, Ref, {error, econnaborted}},
            State=#state{lsock = LSock, ref = Ref}) ->
    accept(State);

%% {error, esslaccept} -> accept
handle_info({inet_async, LSock, Ref, {error, esslaccept}},
            State=#state{lsock = LSock, ref = Ref}) ->
    accept(State);

%% async accept errors...
%% {error, timeout} ->
%% {error, e{n,m}file} -> suspend 100??
handle_info({inet_async, LSock, Ref, {error, Error}}, 
            State=#state{lsock = LSock, ref = Ref}) ->
	sockerr(Error, State);

handle_info(resume, State) ->
    accept(State);

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% accept...
%%--------------------------------------------------------------------

accept(State = #state{lsock = LSock}) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} -> 
			{noreply, State#state{ref = Ref}};
		{error, Error} ->
			sockerr(Error, State)
    end.

%%--------------------------------------------------------------------
%% error happened...
%%--------------------------------------------------------------------
%% emfile: The per-process limit of open file descriptors has been reached.
sockerr(emfile, State = #state{sockname = SockName, emfile_count = Count, logger = Logger}) ->
	%%avoid too many error log.. stupid??
	case Count rem 100 of 
        0 -> Logger:error("acceptor on ~s suspend 100(ms) for ~p emfile errors!!!", [SockName, Count]);
        _ -> ignore
	end,
	suspend(100, State#state{emfile_count = Count+1});

%% enfile: The system limit on the total number of open files has been reached. usually OS's limit.
sockerr(enfile, State = #state{sockname = SockName, logger = Logger}) ->
	Logger:error("accept error on ~s - !!!enfile!!!", [SockName]),
	suspend(100, State);

sockerr(Error, State = #state{sockname = SockName, logger = Logger}) ->
	Logger:error("accept error on ~s - ~s", [SockName, Error]),
	{stop, {accept_error, Error}, State}.

%%--------------------------------------------------------------------
%% suspend for a while...
%%--------------------------------------------------------------------
suspend(Time, State) ->
    erlang:send_after(Time, self(), resume),
	{noreply, State#state{ref=undefined}, hibernate}.

