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

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

%% API
-export([start_link/0]).

-export([start_listener/4, stop_listener/2, listeners/0, listener/1,
         child_spec/4, start_child/1, restart_listener/2]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start the supervisor.
-spec(start_link() -> {ok, pid()} | {error, term()}).
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Child Spec
-spec(child_spec(Protocol, ListenOn, Options, MFArgs) -> supervisor:child_spec() when
      Protocol :: atom(),
      ListenOn :: esockd:listen_on(),
      Options  :: [esockd:option()],
      MFArgs   :: esockd:mfargs()).
child_spec(Protocol, ListenOn, Options, MFArgs) ->
	{child_id(Protocol, ListenOn),
        {esockd_listener_sup, start_link,
            [Protocol, ListenOn, Options, MFArgs]},
                transient, infinity, supervisor, [esockd_listener_sup]}.

%% @doc Start a Listener.
-spec(start_listener(Protocol, ListenOn, Options, MFArgs) -> {ok, pid()} | {error, term()} when
      Protocol :: atom(),
      ListenOn :: esockd:listen_on(),
      Options  :: [esockd:option()],
      MFArgs   :: esockd:mfargs()).
start_listener(Protocol, ListenOn, Options, MFArgs) ->
    start_child(child_spec(Protocol, ListenOn, Options, MFArgs)).

-spec(start_child(supervisor:child_spec()) -> {ok, pid()} | {error, term()}).
start_child(ChildSpec) ->
	supervisor:start_child(?MODULE, ChildSpec).

%% @doc Stop the listener.
-spec(stop_listener(atom(), esockd:listen_on()) -> ok | {error, term()}).
stop_listener(Protocol, ListenOn) ->
    ChildList = filter_child(Protocol, ListenOn),
    stop_listeners(ChildList).

stop_listener(Child) ->
    {ChildId, _, _, _} = Child,
    case supervisor:terminate_child(?MODULE, ChildId) of
        ok ->
            supervisor:delete_child(?MODULE, ChildId);
        {error, Reason} ->
            {error, Reason}
    end.


stop_listeners([Child | LeftChilds]) ->
    case stop_listener(Child) of
        ok ->
            stop_listeners(LeftChilds);
        {error, Reason} ->
            {error, Reason}
    end;
stop_listeners([]) ->
    ok.

%% @doc Get Listeners.
-spec(listeners() -> [{term(), pid()}]).
listeners() ->
    [{Id, Pid} || {{listener_sup, Id}, Pid, supervisor, _} <- supervisor:which_children(?MODULE)].

%% @doc Get Listener Pid.
-spec(listener({atom(), esockd:listen_on()}) -> undefined | pid()).
listener({Protocol, ListenOn}) ->
    ChildId = child_id(Protocol, ListenOn),
    case [Pid || {Id, Pid, supervisor, _} <- supervisor:which_children(?MODULE), Id =:= ChildId] of
        [] -> undefined;
        L  -> hd(L)
    end.

-spec(restart_listener(atom(), esockd:listen_on()) -> ok | {error, term()}).
restart_listener(Protocol, ListenOn) ->
    restart_listeners(filter_child(Protocol, ListenOn)).

restart_listener(Child) ->
    {ChildId, _, _, _} = Child,
    case supervisor:terminate_child(?MODULE, ChildId) of

        ok    -> supervisor:restart_child(?MODULE, ChildId);
        Error -> Error
    end.

restart_listeners(Childs) ->
    restart_listeners(Childs, {error, not_found}).

restart_listeners([], Result) ->
    Result;
restart_listeners([Child|Left], _Result) ->
    case restart_listener(Child) of
        OK = {ok, _} ->
            restart_listeners(Left, OK);
        Error -> Error
    end.

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 10, 100}, [?CHILD(esockd_server, worker),
                                   ?CHILD(esockd_rate_limiter, worker)]}}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

%% @doc Listener ChildId.
%% @private
child_id(Protocol, ListenOn) ->
    {listener_sup, {Protocol, ListenOn}}.

filter_child(Protocol1, ListenOn1) ->
    [Child || Child = {{listener_sup, {Protocol2, ListenOn2}}, _, _, _}
              <- supervisor:which_children(?MODULE),
              Protocol1 =:= Protocol2, same_port(ListenOn1, ListenOn2)].

same_port(ListenOn, ListenOn)   -> true;
same_port({_, Port}, {_, Port}) -> true;
same_port({_, Port}, Port)      -> true;
same_port(Port, {_, Port})      -> true;
same_port(_, _)                 -> false.

