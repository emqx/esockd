%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(esockd_acceptor_sup).

-behaviour(supervisor).

-export([start_link/6]).

-export([ start_acceptor/2
        , count_acceptors/1
        ]).

%% Supervisor callbacks
-export([init/1]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start Acceptor Supervisor.
-spec(start_link(atom(), esockd:listen_on(), pid(),
                 esockd:sock_fun(), [esockd:sock_fun()], esockd_generic_limiter:limiter())
     -> {ok, pid()}).
start_link(Proto, ListenOn, ConnSup, TuneFun, UpgradeFuns, Limiter) ->
    supervisor:start_link(?MODULE, [Proto, ListenOn, ConnSup,
                                    TuneFun, UpgradeFuns, Limiter]).

%% @doc Start a acceptor.
-spec(start_acceptor(pid(), inet:socket()) -> {ok, pid()} | {error, term()}).
start_acceptor(AcceptorSup, LSock) ->
    supervisor:start_child(AcceptorSup, [LSock]).

%% @doc Count acceptors.
-spec(count_acceptors(AcceptorSup :: pid()) -> pos_integer()).
count_acceptors(AcceptorSup) ->
    proplists:get_value(active, supervisor:count_children(AcceptorSup), 0).

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init([Proto, ListenOn, ConnSup, TuneFun, UpgradeFuns, Limiter]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 100,
                 period => 3600
                },
    Acceptor = #{id => acceptor,
                 start => {esockd_acceptor, start_link,
                           [Proto, ListenOn, ConnSup, TuneFun, UpgradeFuns, Limiter]},
                 restart => transient,
                 shutdown => 1000,
                 type => worker,
                 modules => [esockd_acceptor]
                },
    {ok, {SupFlags, [Acceptor]}}.
