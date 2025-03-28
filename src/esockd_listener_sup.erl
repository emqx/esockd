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

-module(esockd_listener_sup).

-behaviour(supervisor).

-include("esockd.hrl").

-export([ start_link/2
        , listener/1
        , acceptor_sup/1
        , connection_sup/1
       ]).

%% get/set
-export([ get_options/2
        , get_acceptors/1
        , get_max_connections/1
        , get_max_conn_rate/3
        , get_current_connections/1
        , get_shutdown_count/1
        ]).

-export([ set_options/3
        , set_max_connections/3
        , set_max_conn_rate/3
        ]).

-export([ get_access_rules/1
        , allow/2
        , deny/2
        ]).

-export([conn_rate_limiter/1, conn_limiter_opts/2, conn_limiter_opt/2]).

%% supervisor callbacks
-export([init/1]).

%% callbacks
-export([ tune_socket/2
        , start_acceptors/1
        ]).

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

%% @doc Start listener supervisor
-spec start_link(atom(), esockd:listen_on())
      -> {ok, pid()} | {error, term()}.
start_link(Proto, ListenOn) ->
    ListenerRef = {Proto, ListenOn},
    supervisor:start_link(?MODULE, ListenerRef).

%% @doc Get listener.
-spec(listener(pid()) -> {module(), pid()}).
listener(Sup) ->
    Child = get_sup_child(Sup, listener),
    {get_child_mod(Child), get_child_pid(Child)}.

%% @doc Get connection supervisor.
-spec(connection_sup(pid()) -> pid()).
connection_sup(Sup) ->
    get_child_pid(get_sup_child(Sup, connection_sup)).

%% @doc Get acceptor supervisor.
-spec(acceptor_sup(pid()) -> pid()).
acceptor_sup(Sup) ->
    get_child_pid(get_sup_child(Sup, acceptor_sup)).

%% @doc Get child pid with id.
get_sup_child(Sup, ChildId) ->
    lists:keyfind(ChildId, 1, supervisor:which_children(Sup)).

get_child_pid({_, Pid, _, _}) -> Pid.
get_child_mod({_, _, _, [Mod | _]}) -> Mod.

%%--------------------------------------------------------------------
%% Get/Set APIs
%%--------------------------------------------------------------------

get_options(ListenerRef, _Sup) ->
    esockd_server:get_listener_prop(ListenerRef, options).

set_options(ListenerRef, Sup, Opts) ->
    case esockd_acceptor_sup:check_options(Opts) of
        ok ->
            do_set_options(ListenerRef, Sup, Opts);
        {error, Reason} ->
            {error, Reason}
    end.

do_set_options(ListenerRef, Sup, Opts) ->
    OptsWas = esockd_server:set_listener_prop(ListenerRef, options, Opts),
    ConnSup = esockd_server:get_listener_prop(ListenerRef, connection_sup),
    {Listener, ListenerPid} = esockd_server:get_listener_prop(ListenerRef, listener),
    try
        ensure_ok(esockd_connection_sup:set_options(ConnSup, Opts)),
        ensure_ok(Listener:set_options(ListenerPid, Opts)),
        restart_acceptor_sup(ListenerRef, Sup)
    catch
        throw:{?MODULE, Error} ->
            %% Restore previous options
            _ = esockd_server:set_listener_prop(ListenerRef, options, OptsWas),
            ok = esockd_connection_sup:set_options(ConnSup, OptsWas),
            %% Listener has failed to set options, no need to restore
            Error
    end.

restart_acceptor_sup(ListenerRef, Sup) ->
    _ = supervisor:terminate_child(Sup, acceptor_sup),
    {ok, _Child} = supervisor:restart_child(Sup, acceptor_sup),
    _ = start_acceptors(ListenerRef),
    ok.

ensure_ok(ok) ->
    ok;
ensure_ok({error, _} = Error) ->
    throw({?MODULE, Error}).

get_acceptors(Sup) ->
    esockd_acceptor_sup:count_acceptors(acceptor_sup(Sup)).

get_max_connections(Sup) ->
    esockd_connection_sup:get_max_connections(connection_sup(Sup)).

set_max_connections(ListenerRef, Sup, MaxConns) ->
    set_options(ListenerRef, Sup, [{max_connections, MaxConns}]).

get_max_conn_rate(_Sup, Proto, ListenOn) ->
    case esockd_limiter:lookup({listener, Proto, ListenOn}) of
        undefined ->
            {error, not_found};
        #{capacity := Capacity, interval := Interval} ->
            {Capacity, Interval}
    end.

set_max_conn_rate(ListenerRef, Sup, Opt) ->
    set_options(ListenerRef, Sup, [{limiter, Opt}]).

get_current_connections(Sup) ->
    esockd_connection_sup:count_connections(connection_sup(Sup)).

get_shutdown_count(Sup) ->
    esockd_connection_sup:get_shutdown_count(connection_sup(Sup)).

get_access_rules(Sup) ->
    esockd_connection_sup:access_rules(connection_sup(Sup)).

allow(Sup, CIDR) ->
    esockd_connection_sup:allow(connection_sup(Sup), CIDR).

deny(Sup, CIDR) ->
    esockd_connection_sup:deny(connection_sup(Sup), CIDR).

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init(ListenerRef) ->
    ConnSup = #{id => connection_sup,
                start => {esockd_connection_sup, start_supervised, [ListenerRef]},
                restart => transient,
                shutdown => infinity,
                type => supervisor,
                modules => [esockd_connection_sup]},
    ListenerMod = case esockd_server:get_listener_prop(ListenerRef, type) of
                    dtls -> esockd_dtls_listener;
                    _ -> esockd_listener
                end,
    Listener = #{id => listener,
                 start => {ListenerMod, start_supervised, [ListenerRef]},
                 restart => transient,
                 shutdown => 16#ffffffff,
                 type => worker,
                 modules => [ListenerMod]},
    AcceptorSup = #{id => acceptor_sup,
                    start => {esockd_acceptor_sup, start_supervised, [ListenerRef]},
                    restart => transient,
                    shutdown => infinity,
                    type => supervisor,
                    modules => [esockd_acceptor_sup]},
    Starter = #{id => starter,
                start => {?MODULE, start_acceptors, [ListenerRef]},
                restart => transient,
                shutdown => infinity,
                type => worker,
                modules => []},
    {ok, { {rest_for_one, 10, 3600}
         , [ConnSup, Listener, AcceptorSup, Starter]
         }}.

-spec start_acceptors(esockd:listener_ref()) -> ignore.
start_acceptors(ListenerRef) ->
    {LMod, LPid} = esockd_server:get_listener_prop(ListenerRef, listener),
    LState = LMod:get_state(LPid),
    LSock = proplists:get_value(listen_sock, LState),
    ok = esockd_acceptor_sup:start_acceptors(ListenerRef, LSock),
    ignore.

%%--------------------------------------------------------------------
%% Sock tune/upgrade functions
%%--------------------------------------------------------------------

tune_socket(Sock, Tunings) ->
    esockd_acceptor_sup:tune_socket(Sock, Tunings).

conn_limiter_opts(Opts, DefName) ->
    Opt =  proplists:get_value(limiter, Opts, undefined),
    conn_limiter_opt(Opt, DefName).

conn_limiter_opt(#{name := _} = Opt, _DefName) ->
    Opt;
conn_limiter_opt(Opt, DefName) when is_map(Opt) ->
    Opt#{name => DefName};
conn_limiter_opt(_Opt, _DefName) ->
    undefined.

conn_rate_limiter(undefined) ->
    undefined;
conn_rate_limiter(Opts) ->
    esockd_generic_limiter:create(Opts).
