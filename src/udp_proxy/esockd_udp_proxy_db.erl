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
    attach/2,
    detach/2
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
    %% Reference Counter
    proxy :: pid()
}).

-define(TAB, esockd_udp_proxy_db).

%%--------------------------------------------------------------------
%%- API
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec attach(connection_module(), connection_id()) -> true.
attach(Mod, CId) ->
    ID = ?ID(Mod, CId),
    case ets:lookup(?TAB, ID) of
        [] ->
            ok;
        [#connection{proxy = ProxyId}] ->
            esockd_udp_proxy:takeover(ProxyId, CId)
    end,
    ets:insert(?TAB, #connection{id = ID, proxy = self()}).

-spec detach(connection_module(), connection_id()) -> boolean().
detach(Mod, CId) ->
    ProxyId = self(),
    ID = ?ID(Mod, CId),
    case ets:lookup(?TAB, ID) of
        [#connection{proxy = ProxyId}] ->
            ets:delete(?TAB, ID),
            true;
        _ ->
            false
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
