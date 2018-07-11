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

-module(esockd_acceptor_sup).

-behaviour(supervisor).

-export([start_link/4, start_acceptor/2, count_acceptors/1]).

-export([init/1]).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start Acceptor Supervisor.
-spec(start_link(pid(), esockd:sock_fun(), [esockd:sock_fun()], fun()) -> {ok, pid()}).
start_link(ConnSup, TuneFun, UpgradeFuns, StatsFun) ->
    supervisor:start_link(?MODULE, [ConnSup, TuneFun, UpgradeFuns, StatsFun]).

%% @doc Start a acceptor.
-spec(start_acceptor(pid(), inet:socket()) -> {ok, pid()} | ignore | {error, term()}).
start_acceptor(AcceptorSup, LSock) ->
    supervisor:start_child(AcceptorSup, [LSock]).

%% @doc Count acceptors.
-spec(count_acceptors(AcceptorSup :: pid()) -> pos_integer()).
count_acceptors(AcceptorSup) ->
    length(supervisor:which_children(AcceptorSup)).

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([ConnSup, TuneFun, UpgradeFuns, StatsFun]) ->
    {ok, {{simple_one_for_one, 100, 3600},
          [#{id       => acceptor,
             start    => {esockd_acceptor, start_link,
                         [ConnSup, TuneFun, UpgradeFuns, StatsFun]},
             restart  => transient,
             shutdown => 5000,
             type     => worker,
             modules  => [esockd_acceptor]}]}}.

