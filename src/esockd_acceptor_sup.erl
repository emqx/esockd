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
%%% eSockd TCP/SSL Acceptor Supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_acceptor_sup).

-behaviour(supervisor).

-export([start_link/2, start_acceptor/3, count_acceptors/1]).

-export([init/1]).

%%------------------------------------------------------------------------------
%% @doc
%% Start Acceptor Supervisor.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Manager, Logger) -> {ok, pid()} when
    Manager :: pid(),
    Logger  :: gen_logger:logmod().
start_link(Manager, Logger) ->
    supervisor:start_link(?MODULE, [Manager, Logger]).

%%------------------------------------------------------------------------------
%% @doc 
%% Start a acceptor.
%%
%% @end
%%------------------------------------------------------------------------------
start_acceptor(AcceptorSup, LSock, SockFun) ->
    supervisor:start_child(AcceptorSup, [LSock, SockFun]).

%%------------------------------------------------------------------------------
%% @doc 
%% Count Acceptors.
%%
%% @end
%%------------------------------------------------------------------------------
count_acceptors(AcceptorSup) ->
    length(supervisor:which_children(AcceptorSup)).

%%%=============================================================================
%% Supervisor callbacks
%%%=============================================================================
init([Manager, Logger]) ->
    {ok, {{simple_one_for_one, 1000, 3600},
          [{acceptor, {esockd_acceptor, start_link, [Manager, Logger]},
            transient, 5000, worker, [esockd_acceptor]}]}}.

