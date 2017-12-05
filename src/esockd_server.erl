%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2017 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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
%%% eSockd Server.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_server).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(gen_server).

-define(SERVER, ?MODULE).

%% Start esockd server
-export([start_link/0]).

%% stats API
-export([stats_fun/2,
         get_stats/1,
         inc_stats/3, dec_stats/3,
         init_stats/2, del_stats/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).

-define(STATS_TAB, esockd_stats).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start esockd server.
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc New Stats Fun.
-spec(stats_fun({atom(), esockd:listen_on()}, atom()) -> fun()).
stats_fun({Protocol, ListenOn}, Metric) ->
    init_stats({Protocol, ListenOn}, Metric),
    fun({inc, Num}) -> esockd_server:inc_stats({Protocol, ListenOn}, Metric, Num);
       ({dec, Num}) -> esockd_server:dec_stats({Protocol, ListenOn}, Metric, Num)
    end.

%% @doc Get Stats.
-spec(get_stats({atom(), esockd:listen_on()}) -> [{atom(), non_neg_integer()}]).
get_stats({Protocol, ListenOn}) ->
    [{Metric, Val} || [Metric, Val]
                      <- ets:match(?STATS_TAB, {{{Protocol, ListenOn}, '$1'}, '$2'})].

%% @doc Inc Stats.
-spec(inc_stats({atom(), esockd:listen_on()}, atom(), pos_integer()) -> any()).
inc_stats({Protocol, ListenOn}, Metric, Num) when is_integer(Num) ->
    update_counter({{Protocol, ListenOn}, Metric}, Num).
    
%% @doc Dec Stats.
-spec(dec_stats({atom(), esockd:listen_on()}, atom(), pos_integer()) -> any()).
dec_stats({Protocol, ListenOn}, Metric, Num) when is_integer(Num) ->
    update_counter({{Protocol, ListenOn}, Metric}, -Num).

%% @doc Update stats counter.
%% @private
update_counter(Key, Num) ->
    ets:update_counter(?STATS_TAB, Key, {2, Num}).

%% @doc Init Stats.
-spec(init_stats({atom(), esockd:listen_on()}, atom()) -> ok).
init_stats({Protocol, ListenOn}, Metric) ->
    gen_server:call(?SERVER, {init, {Protocol, ListenOn}, Metric}).

%% @doc Del Stats.
-spec(del_stats({atom(), esockd:listen_on()}) -> ok).
del_stats({Protocol, ListenOn}) ->
    gen_server:cast(?SERVER, {del, {Protocol, ListenOn}}).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([]) ->
    ets:new(?STATS_TAB, [set, public, named_table, {write_concurrency, true}]),
    {ok, #state{}}.

handle_call({init, {Protocol, ListenOn}, Metric}, _From, State) ->
    Key = {{Protocol, ListenOn}, Metric},
    ets:insert(?STATS_TAB, {Key, 0}),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({del, {Protocol, ListenOn}}, State) ->
    ets:match_delete(?STATS_TAB, {{{Protocol, ListenOn}, '_'}, '_'}),
    {noreply, State};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

