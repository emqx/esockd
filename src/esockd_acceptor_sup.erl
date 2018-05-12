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

-module(esockd_acceptor_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

-export([start_link/3, start_acceptor/3, count_acceptors/1]).

-export([init/1]).

%%%-------------------------------------------------------------------
%%% API
%%%-------------------------------------------------------------------

%% @doc Start Acceptor Supervisor.
-spec(start_link(pid(), fun(), esockd:tune_fun()) -> {ok, pid()}).
start_link(ConnSup, StatsFun, BufferTuneFun) ->
    supervisor:start_link(?MODULE, [ConnSup, StatsFun, BufferTuneFun]).

%% @doc Start a acceptor.
-spec(start_acceptor(pid(), inet:socket(), esockd:sock_fun())
      -> {ok, pid()} | ignore | {error, term()}).
start_acceptor(AcceptorSup, LSock, SockFun) ->
    supervisor:start_child(AcceptorSup, [LSock, SockFun]).

%% @doc Count Acceptors.
-spec(count_acceptors(AcceptorSup :: pid()) -> pos_integer()).
count_acceptors(AcceptorSup) ->
    length(supervisor:which_children(AcceptorSup)).

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

init([ConnSup, StatsFun, BufferTuneFun]) ->
    {ok, {{simple_one_for_one, 100, 3600},
          [{acceptor, {esockd_acceptor, start_link,
                       [ConnSup, StatsFun, BufferTuneFun]},
            transient, 5000, worker, [esockd_acceptor]}]}}.

