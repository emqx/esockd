%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_sup).

-behaviour(supervisor).

-export([start_link/0, child_id/2]).
-export([start_listener/4, stop_listener/2, listeners/0, listener/1, restart_listener/2]).
-export([child_spec/4, udp_child_spec/4, dtls_child_spec/4, start_child/1]).

%% supervisor callback
-export([init/1]).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

-spec(start_link() -> {ok, pid()} | ignore | {error, term()}).
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec(start_listener(atom(), esockd:listen_on(), [esockd:option()], esockd:mfargs())
      -> {ok, pid()} | {error, term()}).
start_listener(Proto, ListenOn, Opts, MFA) ->
    start_child(child_spec(Proto, ListenOn, Opts, MFA)).

-spec(child_spec(atom(), esockd:listen_on(), [esockd:option()], esockd:mfargs())
      -> supervisor:child_spec()).
child_spec(Proto, ListenOn, Opts, MFA) when is_atom(Proto) ->
	{child_id(Proto, ListenOn),
     {esockd_listener_sup, start_link, [Proto, ListenOn, Opts, MFA]},
     transient, infinity, supervisor, [esockd_listener_sup]}.

-spec(udp_child_spec(atom(), esockd:listen_on(), [esockd:option()], esockd:mfargs())
      -> supervisor:child_spec()).
udp_child_spec(Proto, Port, Opts, MFA) when is_atom(Proto) ->
	{child_id(Proto, Port),
     {esockd_udp, server, [Proto, Port, Opts, MFA]},
     transient, 5000, worker, [esockd_udp]}.

-spec(dtls_child_spec(atom(), esockd:listen_on(), [esockd:option()], esockd:mfargs())
      -> supervisor:child_spec()).
dtls_child_spec(Proto, Port, Opts, MFA) when is_atom(Proto) ->
    {child_id(Proto, Port),
     {esockd_dtls_listener_sup, start_link, [Proto, Port, Opts, MFA]},
     transient, infinity, supervisor, [esockd_dtls_listener_sup]}.

-spec(start_child(supervisor:child_spec()) -> {ok, pid()} | {error, term()}).
start_child(ChildSpec) ->
	supervisor:start_child(?MODULE, ChildSpec).

-spec(stop_listener(atom(), esockd:listen_on()) -> ok | {error, term()}).
stop_listener(Proto, ListenOn) ->
    ChildId = child_id(Proto, ListenOn),
	case supervisor:terminate_child(?MODULE, ChildId) of
        ok    -> supervisor:delete_child(?MODULE, ChildId);
        Error -> Error
	end.

-spec(listeners() -> [{term(), pid()}]).
listeners() ->
    [{Id, Pid} || {{listener_sup, Id}, Pid, supervisor, _} <- supervisor:which_children(?MODULE)].

-spec(listener({atom(), esockd:listen_on()}) -> undefined | pid()).
listener({Proto, ListenOn}) ->
    ChildId = child_id(Proto, ListenOn),
    case [Pid || {Id, Pid, supervisor, _}
                 <- supervisor:which_children(?MODULE), Id =:= ChildId] of
        [] -> undefined;
        L  -> hd(L)
    end.

-spec(restart_listener(atom(), esockd:listen_on()) -> ok | {error, term()}).
restart_listener(Proto, ListenOn) ->
    ChildId = child_id(Proto, ListenOn),
    case supervisor:terminate_child(?MODULE, ChildId) of
        ok    -> supervisor:restart_child(?MODULE, ChildId);
        Error -> Error
    end.

child_id(Proto, ListenOn) -> {listener_sup, {Proto, ListenOn}}.

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    Server = #{id       => esockd_server,
               start    => {esockd_server, start_link, []},
               restart  => permanent,
               shutdown => 5000,
               type     => worker,
               modules  => [esockd_server]},
    {ok, {{one_for_one, 10, 100}, [Server]}}.

