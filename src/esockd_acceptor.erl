%%%===================================================================
%%% Copyright (c) 2013-2018 EMQ Inc. All rights reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%===================================================================

-module(esockd_acceptor).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-behaviour(gen_server).

-export([start_link/5]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {lsock       :: inet:socket(),
                sockfun     :: esockd:sock_fun(),
                tunefun     :: esockd:tune_fun(),
                sockname    :: iolist(),
                conn_sup    :: pid(),
                statsfun    :: fun(),
                ref         :: reference(),
                emfile_count = 0}).

%% @doc Start Acceptor
-spec(start_link(pid(), fun(), esockd:tune_fun(), inet:socket(), esockd:sock_fun())
      -> {ok, pid()} | {error, term()}).
start_link(ConnSup, StatsFun, BufTuneFun, LSock, SockFun) ->
    gen_server:start_link(?MODULE, {ConnSup, StatsFun, BufTuneFun, LSock, SockFun}, []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init({ConnSup, StatsFun, BufferTuneFun, LSock, SockFun}) ->
    {ok, SockName} = inet:sockname(LSock),
    gen_server:cast(self(), accept),
    {ok, #state{lsock    = LSock,
                sockfun  = SockFun,
                tunefun  = BufferTuneFun,
                sockname = esockd_net:format(sockname, SockName),
                conn_sup = ConnSup,
                statsfun = StatsFun}}.

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
                                                                 statsfun = StatsFun,
                                                                 ref      = Ref}) ->

    %% patch up the socket so it looks like one we got from gen_tcp:accept/1
    {ok, Mod} = inet_db:lookup_socket(LSock),
    inet_db:register_socket(Sock, Mod),

    %% accepted stats.
    StatsFun({inc, 1}),

    %% Fix issues#9: enotconn error occured...
	%% {ok, Peername} = inet:peername(Sock),
    case BufferTuneFun(Sock) of
        ok ->
            case esockd_connection_sup:start_connection(ConnSup, Mod, Sock, SockFun) of
                {ok, _Pid}        -> ok;
                {error, enotconn} -> catch port_close(Sock); %% quiet...issue #10
                {error, einval}   -> catch port_close(Sock); %% quiet... haproxy check
                {error, Reason}   ->
                    catch port_close(Sock),
                    error_logger:error_msg("Failed to start connection on ~s - ~p",
                                           [SockName, Reason])
            end;
        {error, enotconn} ->
			catch port_close(Sock);
        {error, Err} ->
            error_logger:error_msg("Failed to tune buffer of socket accepted on ~s - ~s",
                                   [SockName, Err]),
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
sockerr(emfile, State = #state{sockname = SockName, emfile_count = Count}) ->
	%% Avoid too many error log.. stupid??
	case Count rem 100 of
        0 -> error_logger:error_msg("Acceptor on ~s suspend 100(ms) for ~p emfile errors!!!",
                                    [SockName, Count]);
        _ -> ignore
	end,
	suspend(100, State#state{emfile_count = Count+1});

%% enfile: The system limit on the total number of open files has been reached. usually OS's limit.
sockerr(enfile, State = #state{sockname = SockName}) ->
	error_logger:error_msg("Accept error on ~s - !!!enfile!!!", [SockName]),
	suspend(100, State);

sockerr(Error, State = #state{sockname = SockName}) ->
	error_logger:error_msg("accept error on ~s - ~s", [SockName, Error]),
	{stop, {accept_error, Error}, State}.

%%--------------------------------------------------------------------
%% suspend for a while...
%%--------------------------------------------------------------------

suspend(Time, State) ->
    erlang:send_after(Time, self(), resume),
	{noreply, State#state{ref = undefined}, hibernate}.

