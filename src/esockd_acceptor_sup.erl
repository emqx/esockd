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

-export([ start_supervised/1
        ]).

-export([ start_acceptors/2
        , start_acceptor/2
        , count_acceptors/1
        , check_options/2
        ]).

%% Supervisor callbacks
-export([init/1]).

-define(ACCEPTOR_POOL, 16).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start Acceptor Supervisor.
-spec start_supervised(esockd:listener_ref()) -> {ok, pid()}.
start_supervised(ListenerRef = {Proto, ListenOn}) ->
    Type = esockd_server:get_listener_prop(ListenerRef, type),
    Opts = esockd_server:get_listener_prop(ListenerRef, options),
    ConnSup = esockd_server:get_listener_prop(ListenerRef, connection_sup),
    case check_options(Type, Opts) of
        ok ->
            UpgradeFuns = upgrade_funs(Type, Opts),
            LimiterOpts = esockd_listener_sup:conn_limiter_opts(Opts, {listener, Proto, ListenOn}),
            Limiter = esockd_listener_sup:conn_rate_limiter(LimiterOpts),
            case Type of
                T when T =:= tcp; T =:= ssl ->
                    TuneFun = esockd_accept_inet:mk_tune_socket_fun(Opts),
                    AcceptCb = {esockd_accept_inet, TuneFun},
                    Mod = esockd_acceptor_fsm,
                    Args = [ListenerRef, esockd_transport, ConnSup, AcceptCb, UpgradeFuns, Limiter];
                tcpsocket ->
                    TuneFun = esockd_accept_socket:mk_tune_socket_fun(Opts),
                    AcceptCb = {esockd_accept_socket, TuneFun},
                    Mod = esockd_acceptor_fsm,
                    Args = [ListenerRef, esockd_socket, ConnSup, AcceptCb, UpgradeFuns, Limiter];
                dtls ->
                    TuneFun = esockd_accept_inet:mk_tune_socket_fun(Opts),
                    Mod = esockd_dtls_acceptor,
                    Args = [ListenerRef, ConnSup, TuneFun, UpgradeFuns, Limiter]
            end,
            case supervisor:start_link(?MODULE, {Mod, Args}) of
                {ok, Pid} ->
                    _ = esockd_server:set_listener_prop(ListenerRef, acceptor_sup, Pid),
                    {ok, Pid};
                {error, _} = Error ->
                    Error
            end;
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

upgrade_funs(Type, Opts) ->
    proxy_upgrade_fun(Type, Opts) ++ ssl_upgrade_fun(Type, Opts).

proxy_upgrade_fun(Type, Opts) ->
    case proplists:get_bool(proxy_protocol, Opts) of
        false ->
            [];
        true when Type =:= tcpsocket ->
            [esockd_socket:proxy_upgrade_fun(Opts)];
        true ->
            [esockd_transport:proxy_upgrade_fun(Opts)]
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

-spec check_options(atom(), list()) -> ok | {error, any()}.
check_options(tcpsocket, Opts) ->
    case proplists:get_value(ssl_options, Opts) of
        undefined -> ok;
        _SslOpts -> {error, ssl_not_supported}
    end;
check_options(_Type, Opts) ->
    try
        ok = check_ssl_opts(ssl_options, Opts),
        ok = check_ssl_opts(dtls_options, Opts)
    catch
        throw : Reason ->
            {error, Reason}
    end.

check_ssl_opts(Key, Opts) ->
    case proplists:get_value(Key, Opts) of
        undefined ->
            ok;
        SslOpts ->
            try
                {ok, _} = ssl:handle_options(SslOpts, server, undefined),
                ok
            catch
                _ : {error, Reason} ->
                    throw_invalid_ssl_option(Key, Reason);
                _ : Wat : Stack ->
                    %% It's a function_clause for OTP 25
                    %% And, maybe OTP decide to change some day, who knows
                    throw_invalid_ssl_option(Key, {Wat, Stack})
            end
    end.

-spec throw_invalid_ssl_option(_, _) -> no_return().
throw_invalid_ssl_option(Key, Reason) ->
    throw(#{error => invalid_ssl_option,
            reason => Reason,
            key => Key}).
