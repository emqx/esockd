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
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2012 VMware, Inc.  All rights reserved.
%%
%%------------------------------------------------------------------------------

-module(esockd_acceptor).

-behaviour(gen_server).

-export([start_link/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {client_sup, sock, ref}).

start_link(ClientSup, LSock) ->
    gen_server:start_link(?MODULE, {ClientSup, LSock}, []).

%%--------------------------------------------------------------------

init({ClientSup, LSock}) ->
    gen_server:cast(self(), accept),
    {ok, #state{client_sup=ClientSup, sock=LSock}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(accept, State) ->
    accept(State);

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({inet_async, LSock, Ref, {ok, Sock}},
            State = #state{client_sup=ClientSup, sock=LSock, ref=Ref}) ->

    %% patch up the socket so it looks like one we got from
    %% gen_tcp:accept/1
    {ok, Mod} = inet_db:lookup_socket(LSock),
    inet_db:register_socket(Sock, Mod),

	%%TODO: Copy socket options from LSock?
	{ok, Client} = supervisor2:start_child(ClientSup, [Sock]),
	Mod:controlling_process(Sock, Client), 
	%%FIXME: should be wrapped
	esockd_client:ready(Client, self(), Sock),

    %% accept more
    accept(State);

handle_info({inet_async, LSock, Ref, {error, closed}},
            State=#state{sock=LSock, ref=Ref}) ->
    %% It would be wrong to attempt to restart the acceptor when we
    %% know this will fail.
    {stop, normal, State};

%%TODO: 
%% {error, timeout} ->
%% {error, esslaccept} ->
%% {error, e{n,m}file} -> sleep 100??

handle_info({inet_async, LSock, Ref, {error, Reason}},
            State=#state{sock=LSock, ref=Ref}) ->
	error_logger:error_msg("accept error: ~p~n", [Reason]),
    {stop, {accept_failed, Reason}, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------

accept(State = #state{sock=LSock}) ->
    case prim_inet:async_accept(LSock, -1) of
        {ok, Ref} -> 
			{noreply, State#state{ref=Ref}};
        Error     -> 
			error_logger:error_msg("accept error: ~p~n", [Error]),
			{stop, {cannot_accept, Error}, State}
    end.

