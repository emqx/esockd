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

-module(esockd_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([child_id/2]).

-export([ start_child/1
        , stop_listener/2
        , restart_listener/2
        ]).

-export([ listeners/0
        , listener/1
        , listener_and_module/1
        ]).

-export([ child_spec/3
        , udp_child_spec/3
        , dtls_child_spec/3
        ]).

%% supervisor callback
-export([init/1]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(start_link() -> {ok, pid()} | ignore | {error, term()}).
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec child_spec(atom(), esockd:listen_on(), [esockd:option()])
      -> supervisor:child_spec().
child_spec(Proto, ListenOn, Opts) when is_atom(Proto) ->
    ListenerRef = {Proto, ListenOn},
    _ = esockd_server:set_listener_prop(ListenerRef, type, tcp),
    _ = esockd_server:set_listener_prop(ListenerRef, options, Opts),
    #{id => child_id(Proto, ListenOn),
      start => {esockd_listener_sup, start_link, [Proto, ListenOn]},
      restart => transient,
      shutdown => infinity,
      type => supervisor,
      modules => [esockd_listener_sup]}.

-spec udp_child_spec(atom(), esockd:listen_on(), [esockd:option()])
      -> supervisor:child_spec().
udp_child_spec(Proto, Port, Opts) when is_atom(Proto) ->
    #{id => child_id(Proto, Port),
      start => {esockd_udp, server, [Proto, Port, Opts]},
      restart => transient,
      shutdown => 5000,
      type => worker,
      modules => [esockd_udp]}.

-spec dtls_child_spec(atom(), esockd:listen_on(), [esockd:option()])
      -> supervisor:child_spec().
dtls_child_spec(Proto, Port, Opts) when is_atom(Proto) ->
    ListenerRef = {Proto, Port},
    _ = esockd_server:set_listener_prop(ListenerRef, type, dtls),
    _ = esockd_server:set_listener_prop(ListenerRef, options, Opts),
    #{id => child_id(Proto, Port),
      start => {esockd_listener_sup, start_link, [Proto, Port]},
      restart => transient,
      shutdown => infinity,
      type => supervisor,
      modules => [esockd_listener_sup]}.

-spec(start_child(supervisor:child_spec()) -> {ok, pid()} | {error, term()}).
start_child(ChildSpec) ->
	supervisor:start_child(?MODULE, ChildSpec).

-spec(stop_listener(atom(), esockd:listen_on()) -> ok | {error, term()}).
stop_listener(Proto, ListenOn) ->
    ListenerRef = {Proto, ListenOn},
    case match_listeners(Proto, ListenOn) of
        [] -> {error, not_found};
        Listeners ->
            Results = [terminate_and_delete(ChildId) || ChildId <- Listeners],
            case ok_or_error(Results) of
                ok ->
                    _ = esockd_server:erase_listener_props(ListenerRef),
                    ok;
                Error ->
                    Error
            end
    end.

terminate_and_delete(ChildId) ->
	case supervisor:terminate_child(?MODULE, ChildId) of
        ok    -> supervisor:delete_child(?MODULE, ChildId);
        Error -> Error
	end.

-spec(listeners() -> [{term(), pid()}]).
listeners() ->
    [{Id, Pid} || {{listener_sup, Id}, Pid, _Type, _} <- supervisor:which_children(?MODULE)].

-spec(listener({atom(), esockd:listen_on()}) -> pid()).
listener({Proto, ListenOn}) ->
    ChildId = child_id(Proto, ListenOn),
    case [Pid || {Id, Pid, _Type, _} <- supervisor:which_children(?MODULE), Id =:= ChildId] of
        [] -> error(not_found);
        L  -> hd(L)
    end.

-spec(listener_and_module({atom(), esockd:listen_on()})
     -> undefined
      | {ListenerSup :: pid(), Mod :: esockd_listener_sup | esockd_udp}).
listener_and_module({Proto, ListenOn}) ->
    ChildId = child_id(Proto, ListenOn),
    case [{Pid, Mod} || {Id, Pid, _Type, [Mod|_]} <- supervisor:which_children(?MODULE), Id =:= ChildId] of
        [] -> undefined;
        L  -> hd(L)
    end.

-spec(restart_listener(atom(), esockd:listen_on()) -> ok | {error, term()}).
restart_listener(Proto, ListenOn) ->
    case match_listeners(Proto, ListenOn) of
        [] -> {error, not_found};
        Listeners ->
            ok_or_error([terminate_and_restart(ChildId) || ChildId <- Listeners])
    end.

terminate_and_restart(ChildId) ->
    case supervisor:terminate_child(?MODULE, ChildId) of
        ok    -> supervisor:restart_child(?MODULE, ChildId);
        Error -> Error
    end.

match_listeners(Proto, ListenOn) ->
    [ChildId || {ChildId, _Pid, _Type, _} <- supervisor:which_children(?MODULE),
                match_listener(Proto, ListenOn, ChildId)].

match_listener(Proto, ListenOn, {listener_sup, {Proto, ListenOn}}) ->
    true;
match_listener(Proto, Port, {listener_sup, {Proto, {_IP, Port}}}) ->
    true;
match_listener(_Proto, _ListenOn, _ChildId) ->
    false.

child_id(Proto, ListenOn) ->
    {listener_sup, {Proto, ListenOn}}.

ok_or_error([]) -> ok;
ok_or_error([ok|Results]) ->
    ok_or_error(Results);
ok_or_error([{ok, _Pid}|Results]) ->
    ok_or_error(Results);
ok_or_error([{error, Reason}|_]) ->
    {error, Reason}.

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 100
                },
    Limiter = #{id => esockd_limiter,
                start => {esockd_limiter, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [esockd_limiter]
               },
    Server = #{id => esockd_server,
               start => {esockd_server, start_link, []},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [esockd_server]
              },
    ProxyDB = #{id => esockd_udp_proxy_db,
                start => {esockd_udp_proxy_db, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [esockd_udp_proxy_db]
               },
    {ok, {SupFlags, [Limiter, Server, ProxyDB]}}.
