%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(esockd_acceptor).

-behaviour(gen_server).

-include("esockd.hrl").

-export([start_link/7]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {lsock       :: inet:socket(),
                sockfun     :: esockd:sock_fun(),
                tunefun     :: esockd:tune_fun(),
                sockname    :: iolist(),
                conn_sup    :: pid(),
                statsfun    :: fun(),
                limitfun    :: fun(),
                logger      :: gen_logger:logmod(),
                accept_ref  :: reference(),
                emfile_count = 0}).

%% @doc Start acceptor
-spec(start_link(ConnSup, AcceptStatsFun, BufferTuneFun, LimitFun, Logger, LSock, SockFun)
      -> {ok, pid()} | {error, term()} when
      ConnSup        :: pid(),
      AcceptStatsFun :: fun(),
      BufferTuneFun  :: esockd:tune_fun(),
      LimitFun         :: fun(),
      Logger         :: gen_logger:logmod(),
      LSock          :: inet:socket(),
      SockFun        :: esockd:sock_fun()).
start_link(ConnSup, AcceptStatsFun, BufTuneFun, LimitFun, Logger, LSock, SockFun) ->
    gen_server:start_link(?MODULE, {ConnSup, AcceptStatsFun, BufTuneFun, LimitFun, Logger, LSock, SockFun}, []).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init({ConnSup, AcceptStatsFun, BufferTuneFun, LimitFun, Logger, LSock, SockFun}) ->
    {ok, SockName} = inet:sockname(LSock),
    gen_server:cast(self(), accept),
    {ok, #state{lsock    = LSock,
                sockfun  = SockFun,
                tunefun  = BufferTuneFun,
                sockname = esockd_net:format(sockname, SockName),
                conn_sup = ConnSup,
                statsfun = AcceptStatsFun,
                limitfun = LimitFun,
                logger   = Logger}}.

handle_call(Req, _From, State) ->
    error_logger:error_msg("[~s] unexpected call: ~p", [?MODULE, Req]),
    {noreply, State}.

handle_cast(accept, State) ->
    accept(State);

handle_cast(Msg, State) ->
    error_logger:error_msg("[~s] unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.

handle_info({inet_async, LSock, Ref, {ok, Sock}},
            State = #state{lsock      = LSock,
                           sockfun    = SockFun,
                           tunefun    = BufferTuneFun,
                           sockname   = SockName,
                           conn_sup   = ConnSup,
                           statsfun   = AcceptStatsFun,
                           logger     = Logger,
                           accept_ref = Ref}) ->
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
    rate_limit(State);

handle_info({inet_async, LSock, Ref, {error, closed}},
            State = #state{lsock = LSock, accept_ref = Ref}) ->
    {stop, normal, State};

%% {error, econnaborted} -> accept
handle_info({inet_async, LSock, Ref, {error, econnaborted}},
            State = #state{lsock = LSock, accept_ref = Ref}) ->
    accept(State);

%% {error, esslaccept} -> accept
handle_info({inet_async, LSock, Ref, {error, esslaccept}},
            State = #state{lsock = LSock, accept_ref = Ref}) ->
    accept(State);

%% async accept errors...
%% {error, timeout} ->
%% {error, e{n,m}file} -> suspend 100??
handle_info({inet_async, LSock, Ref, {error, Error}},
            State = #state{lsock = LSock, accept_ref = Ref}) ->
    sockerr(Error, State);

handle_info(resume, State) ->
    accept(State);

handle_info(Info, State) ->
    error_logger:error_msg("[~s] unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% rate limit
%%--------------------------------------------------------------------

rate_limit(State = #state{limitfun = RateLimit}) ->
    case RateLimit(1) of
        I when I =< 0 ->
            suspend(1000 + rand:uniform(1000), State);
        _ -> accept(State) %% accept more
    end.

%%--------------------------------------------------------------------
%% accept...
%%--------------------------------------------------------------------

accept(State = #state{lsock = LSock}) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} ->
            {noreply, State#state{accept_ref = Ref}};
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
    _TRef = erlang:send_after(Time, self(), resume),
    {noreply, State#state{accept_ref = undefined}, hibernate}.

