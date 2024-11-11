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

-module(esockd_server).

-behaviour(gen_server).

-export([start_link/0, stop/0]).

%% stats API
-export([ stats_fun/2
        , init_stats/2
        , get_stats/1
        , inc_stats/3
        , dec_stats/3
        , del_stats/1
        , ensure_stats/1
        ]).

%% listener properties API
-export([ get_listener_prop/2
        , list_listener_props/1
        , set_listener_prop/3
        , erase_listener_props/1
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-record(state, {
    listener_props :: #{esockd:listener_ref() => #{_Name => _Value}}
}).

-define(SERVER, ?MODULE).
-define(STATS_TAB, esockd_stats).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(start_link() -> {ok, pid()} | ignore | {error, term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(stop() -> ok).
stop() -> gen_server:stop(?SERVER).

-spec(stats_fun({atom(), esockd:listen_on()}, atom()) -> fun()).
stats_fun({Protocol, ListenOn}, Metric) ->
    init_stats({Protocol, ListenOn}, [Metric]),
    fun({inc, Num}) -> esockd_server:inc_stats({Protocol, ListenOn}, Metric, Num);
       ({dec, Num}) -> esockd_server:dec_stats({Protocol, ListenOn}, Metric, Num)
    end.

-spec(init_stats({atom(), esockd:listen_on()}, [atom()]) -> ok).
init_stats({Protocol, ListenOn}, Metrics) ->
    gen_server:call(?SERVER, {init, {Protocol, ListenOn}, Metrics}).

-spec(get_stats({atom(), esockd:listen_on()}) -> [{atom(), non_neg_integer()}]).
get_stats({Protocol, ListenOn}) ->
    [{Metric, Val} || [Metric, Val]
                      <- ets:match(?STATS_TAB, {{{Protocol, ListenOn}, '$1'}, '$2'})].

-spec(inc_stats({atom(), esockd:listen_on()}, atom(), pos_integer()) -> any()).
inc_stats({Protocol, ListenOn}, Metric, Num) when is_integer(Num) ->
    update_counter({{Protocol, ListenOn}, Metric}, Num).

-spec(dec_stats({atom(), esockd:listen_on()}, atom(), pos_integer()) -> any()).
dec_stats({Protocol, ListenOn}, Metric, Num) when is_integer(Num) ->
    update_counter({{Protocol, ListenOn}, Metric}, -Num).

update_counter(Key, Num) ->
    ets:update_counter(?STATS_TAB, Key, {2, Num}).

-spec(del_stats({atom(), esockd:listen_on()}) -> ok).
del_stats({Protocol, ListenOn}) ->
    gen_server:cast(?SERVER, {del, {Protocol, ListenOn}}).

-spec ensure_stats({atom(), esockd:listen_on()}) -> ok.
ensure_stats(StatsKey) ->
    Stats = [accepted,
             closed_overloaded,
             closed_rate_limitted,
             closed_other_reasons],
    ok = ?MODULE:init_stats(StatsKey, Stats),
    ok.

-spec get_listener_prop(esockd:listener_ref(), _Name) -> _Value | undefined.
get_listener_prop(ListenerRef = {_Proto, _ListenOn}, Name) ->
    gen_server:call(?SERVER, {get_listener_prop, ListenerRef, Name}, infinity).

-spec list_listener_props(esockd:listener_ref()) -> [{_Name, _Value}].
list_listener_props(ListenerRef = {_Proto, _ListenOn}) ->
    gen_server:call(?SERVER, {list_listener_props, ListenerRef}, infinity).

-spec set_listener_prop(esockd:listener_ref(), _Name, _Value) -> _ValueWas.
set_listener_prop(ListenerRef = {_Proto, _ListenOn}, Name, Value) ->
    gen_server:call(?SERVER, {set_listener_prop, ListenerRef, Name, Value}, infinity).    

-spec erase_listener_props(esockd:listener_ref()) -> [{_Name, _ValueWas}].
erase_listener_props(ListenerRef = {_Proto, _ListenOn}) ->
    gen_server:call(?SERVER, {erase_listener_props, ListenerRef}, infinity).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    _ = ets:new(?STATS_TAB, [public, set, named_table,
                             {write_concurrency, true}]),
    {ok, #state{listener_props = #{}}}.

handle_call({init, {Protocol, ListenOn}, Metrics}, _From, State) ->
    lists:foreach(fun(Metric) ->
        true = ets:insert(?STATS_TAB, {{{Protocol, ListenOn}, Metric}, 0})
    end, Metrics),
    {reply, ok, State, hibernate};

handle_call({get_listener_prop, ListenerRef, Name}, _From,
            State = #state{listener_props = LProps}) ->
    {reply, lprops_get(ListenerRef, Name, LProps), State};

handle_call({set_listener_prop, ListenerRef, Name, NValue}, _From,
            State = #state{listener_props = LProps}) ->
    Value = lprops_get(ListenerRef, Name, LProps),
    NLProps = lprops_set(ListenerRef, Name, NValue, LProps),
    {reply, Value, State#state{listener_props = NLProps}};

handle_call({list_listener_props, ListenerRef}, _From,
            State = #state{listener_props = LProps}) ->
    {reply, lprops_list(ListenerRef, LProps), State};

handle_call({erase_listener_props, ListenerRef}, _From,
            State = #state{listener_props = LProps}) ->
    Props = lprops_list(ListenerRef, LProps),
    {reply, Props, State#state{listener_props = lprops_erase(ListenerRef, LProps)}};

handle_call(Req, _From, State) ->
    error_logger:error_msg("[~s] Unexpected call: ~p", [?MODULE, Req]),
    {reply, ignore, State}.

handle_cast({del, {Protocol, ListenOn}}, State) ->
    ets:match_delete(?STATS_TAB, {{{Protocol, ListenOn}, '_'}, '_'}),
    {noreply, State, hibernate};

handle_cast(Msg, State) ->
    error_logger:error_msg("[~s] Unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    error_logger:error_msg("[~s] Unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%

lprops_get(ListenerRef, Name, LProps) ->
    case LProps of
        #{ListenerRef := Props} ->
            maps:get(Name, Props, undefined);
        #{} ->
            undefined
    end.

lprops_set(ListenerRef, Name, Value, LProps) ->
    Props = maps:get(ListenerRef, LProps, #{}),
    LProps#{ListenerRef => Props#{Name => Value}}.

lprops_list(ListenerRef, LProps) ->
    Props = maps:get(ListenerRef, LProps, #{}),
    maps:to_list(Props).

lprops_erase(ListenerRef, LProps) ->
    maps:remove(ListenerRef, LProps).
