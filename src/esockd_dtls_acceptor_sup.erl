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

-module(esockd_dtls_acceptor_sup).

-behaviour(supervisor).

-export([start_link/2, start_acceptor/2, count_acceptors/1]).

-export([init/1]).

start_link(Opts, MFA) ->
    supervisor:start_link(?MODULE, [Opts, MFA]).

-spec(start_acceptor(pid(), inet:socket()) -> {ok, pid()} | {error, term()}).
start_acceptor(Sup, LSock) ->
    supervisor:start_child(Sup, [LSock]).

count_acceptors(Sup) ->
    proplists:get_value(active, supervisor:count_children(Sup), 0).

init([Opts, MFA]) ->
    {ok, {{simple_one_for_one, 0, 1},
          [{acceptor, {esockd_dtls_acceptor, start_link, [self(), Opts, MFA]},
            transient, 5000, worker, [esockd_dtls_acceptor]}]}}.

