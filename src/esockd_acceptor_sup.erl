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

-export([ start_link/6
        , start_supervised/1
        ]).

-export([ start_acceptors/2
        , start_acceptor/2
        , count_acceptors/1
        ]).

%% Supervisor callbacks
-export([init/1]).

%% callbacks
-export([tune_socket/2]).

-define(ACCEPTOR_POOL, 16).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start Acceptor Supervisor.
-spec(start_link(atom(), esockd:listen_on(), pid(),
                 esockd:sock_fun(), [esockd:sock_fun()], esockd_generic_limiter:limiter())
     -> {ok, pid()}).
start_link(Proto, ListenOn, ConnSup, TuneFun, UpgradeFuns, Limiter) ->
    supervisor:start_link(?MODULE, { esockd_acceptor
                                   , [Proto, ListenOn, ConnSup,
                                      TuneFun, UpgradeFuns, Limiter]}).

%% @doc Start Acceptor Supervisor.
-spec start_supervised(esockd:listener_ref()) -> {ok, pid()}.
start_supervised(ListenerRef = {Proto, ListenOn}) ->
    Type = esockd_server:get_listener_prop(ListenerRef, type),
    Opts = esockd_server:get_listener_prop(ListenerRef, options),
    TuneFun = tune_socket_fun(Opts),
    UpgradeFuns = upgrade_funs(Type, Opts),
    LimiterOpts = esockd_listener_sup:conn_limiter_opts(Opts, {listener, Proto, ListenOn}),
    Limiter = esockd_listener_sup:conn_rate_limiter(LimiterOpts),
    AcceptorMod = case Type of
                         dtls -> esockd_dtls_acceptor;
                         _ -> esockd_acceptor
                     end,
    ConnSup = esockd_server:get_listener_prop(ListenerRef, connection_sup),
    AcceptorArgs = [Proto, ListenOn, ConnSup, TuneFun, UpgradeFuns, Limiter],
    case supervisor:start_link(?MODULE, {AcceptorMod, AcceptorArgs}) of
        {ok, Pid} ->
            _ = esockd_server:set_listener_prop(ListenerRef, acceptor_sup, Pid),
            {ok, Pid};
        {error, _} = Error ->
            Error
    end.

%% @doc Start acceptors.
-spec start_acceptors(esockd:listener_ref(), inet:socket()) -> ok.
start_acceptors(ListenerRef, LSock) ->
    Opts = esockd_server:get_listener_prop(ListenerRef, options),
    AcceptorNum = proplists:get_value(acceptors, Opts, ?ACCEPTOR_POOL),
    AcceptorSup = esockd_server:get_listener_prop(ListenerRef, acceptor_sup),
    lists:foreach(
        fun(_) -> {ok, _} = start_acceptor(AcceptorSup, LSock) end,
        lists:seq(1, AcceptorNum)
    ).

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

init({AcceptorMod, AcceptorArgs}) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 100000,
                 period => 1
                },
    Acceptor = #{id => acceptor,
                 start => {AcceptorMod, start_link, AcceptorArgs},
                 restart => transient,
                 shutdown => 1000,
                 type => worker,
                 modules => [AcceptorMod]
                },
    {ok, {SupFlags, [Acceptor]}}.

%%--------------------------------------------------------------------
%% Internal functions
%% -------------------------------------------------------------------

tune_socket_fun(Opts) ->
    TuneOpts = [ {tune_buffer, proplists:get_bool(tune_buffer, Opts)}
                 %% optional callback, returns ok | {error, Reason}
               , {tune_fun, proplists:get_value(tune_fun, Opts, undefined)}],
    {fun ?MODULE:tune_socket/2, [TuneOpts]}.

upgrade_funs(Type, Opts) ->
    lists:append([proxy_upgrade_fun(Opts), ssl_upgrade_fun(Type, Opts)]).

proxy_upgrade_fun(Opts) ->
    case proplists:get_bool(proxy_protocol, Opts) of
        false -> [];
        true  -> [esockd_transport:proxy_upgrade_fun(Opts)]
    end.

ssl_upgrade_fun(Type, Opts) ->
    Key = case Type of
              dtls -> dtls_options;
              _ -> ssl_options
          end,
    case proplists:get_value(Key, Opts) of
        undefined -> [];
        SslOpts -> [esockd_transport:ssl_upgrade_fun(SslOpts)]
    end.

tune_socket(Sock, []) ->
    {ok, Sock};
tune_socket(Sock, [{tune_buffer, true}|More]) ->
    case esockd_transport:getopts(Sock, [sndbuf, recbuf, buffer]) of
        {ok, BufSizes} ->
            BufSz = lists:max([Sz || {_Opt, Sz} <- BufSizes]),
            _ = esockd_transport:setopts(Sock, [{buffer, BufSz}]),
            tune_socket(Sock, More);
        Error -> Error
   end;
tune_socket(Sock, [{tune_fun, undefined} | More]) ->
    tune_socket(Sock, More);
tune_socket(Sock, [{tune_fun, {M, F, A}} | More]) ->
    case apply(M, F, A) of
        ok ->
            tune_socket(Sock, More);
        Error -> Error
    end;
tune_socket(Sock, [_|More]) ->
    tune_socket(Sock, More).
