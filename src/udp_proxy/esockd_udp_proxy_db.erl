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

-module(esockd_udp_proxy_db).

-behaviour(gen_server).

-include("include/esockd_proxy.hrl").

%% API
-export([
    start_link/0,
    insert/3,
    attach/2,
    detach/2,
    lookup/2
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-define(ID(Mod, CId), {Mod, CId}).

-record(connection, {
    id :: ?ID(connection_module(), connection_id()),
    %% the connection pid
    pid :: pid(),
    %% Reference Counter
    count :: non_neg_integer()
}).

-define(TAB, esockd_udp_proxy_db).
-define(MINIMUM_VAL, -2147483647).

%%--------------------------------------------------------------------
%%- API
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec insert(connection_module(), connection_id(), pid()) -> boolean().
insert(Mod, CId, Pid) ->
    ets:insert_new(?TAB, #connection{
        id = ?ID(Mod, CId),
        pid = Pid,
        count = 0
    }).

-spec attach(connection_module(), connection_id()) -> integer().
attach(Mod, CId) ->
    ets:update_counter(?TAB, ?ID(Mod, CId), {#connection.count, 1}).

-spec detach(connection_module(), connection_id()) -> {Clear :: true, connection_state()} | false.
detach(Mod, CId) ->
    Id = ?ID(Mod, CId),
    RC = ets:update_counter(?TAB, Id, {#connection.count, -1, 0, ?MINIMUM_VAL}),
    if
        RC < 0 ->
            case ets:lookup(?TAB, Id) of
                [#connection{pid = Pid}] ->
                    ets:delete(?TAB, Id),
                    {true, Pid};
                _ ->
                    false
            end;
        true ->
            false
    end.

-spec lookup(connection_module(), connection_id()) -> {ok, pid()} | undefined.
lookup(Mod, CId) ->
    case ets:lookup(?TAB, ?ID(Mod, CId)) of
        [#connection{pid = Pid}] ->
            {ok, Pid};
        _ ->
            undefined
    end.

%%--------------------------------------------------------------------
%%- gen_server callbacks
%%--------------------------------------------------------------------
init([]) ->
    ?TAB = ets:new(?TAB, [
        set,
        public,
        named_table,
        {keypos, #connection.id},
        {write_concurrency, true},
        {read_concurrency, true}
    ]),
    {ok, #{}}.

handle_call(Req, _From, State) ->
    error_logger:error_msg("Unexpected call: ~p", [Req]),
    {reply, ignore, State}.

handle_cast(Msg, State) ->
    error_logger:error_msg("Unexpected cast: ~p~n", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    error_logger:error_msg("Unexpected info: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ets:delete(?TAB),
    ok.
