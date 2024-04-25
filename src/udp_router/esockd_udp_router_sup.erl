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

-module(esockd_udp_router_sup).

-behaviour(supervisor).

%% API
-export([ start_link/0
        , ensure_start/0]).

%% Supervisor callbacks
-export([init/1]).

%% shared with esockd_udp_router_monitor
-define(POOL, esockd_udp_monitor).
-define(WORKER_NAME(Id), {?POOL, Id}).

%%%-------------------------------------------------------------------
%%- API functions
%%--------------------------------------------------------------------
ensure_start() ->
    case erlang:whereis(?MODULE) of
        undefined ->
            Spec = #{id => ?MODULE,
                     restart => transient,
                     shutdown => infinity,
                     type => supervisor,
                     modules => [?MODULE]},
            esockd_sup:start_child(Spec),
            ok;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%% @doc
%% Starts the supervisor
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} |
          {error, {already_started, Pid :: pid()}} |
          {error, {shutdown, term()}} |
          {error, term()} |
          ignore.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%--------------------------------------------------------------------
%%- Supervisor callbacks
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart intensity, and child
%% specifications.
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) ->
          {ok, {SupFlags :: supervisor:sup_flags(),
                [ChildSpec :: supervisor:child_spec()]}} |
          ignore.
init([]) ->
    Size = erlang:system_info(schedulers) * 2,
    ok = ensure_pool(Size),

    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 3600},

    AChilds = [begin
                   ensure_pool_worker(I),
                   #{id => ?WORKER_NAME(I),
                     start => {?POOL, start_link, [I]},
                     restart => transient,
                     shutdown => 5000,
                     type => worker,
                     modules => [?POOL]}
               end || I <- lists:seq(1, Size)],

    {ok, {SupFlags, [AChilds]}}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
ensure_pool(Size) ->
    try gproc_pool:new(?POOL, hash, [{size, Size}])
    catch
        error:exists -> ok
    end.

ensure_pool_worker(Id) ->
    try gproc_pool:add_worker(?POOL, ?WORKER_NAME(Id), Id)
    catch
        error:exists -> ok
    end.
