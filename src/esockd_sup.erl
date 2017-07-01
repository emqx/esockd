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
%%% eSockd Supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

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
-spec(start_link() -> {ok, pid()} | {error, any()}).
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
-spec(start_listener(Protocol, ListenOn, Options, MFArgs) -> {ok, pid()} | {error, any()} when
      Protocol :: atom(),
      ListenOn :: esockd:listen_on(),
      Options  :: [esockd:option()],
      MFArgs   :: esockd:mfargs()).
start_listener(Protocol, ListenOn, Options, MFArgs) ->
    start_child(child_spec(Protocol, ListenOn, Options, MFArgs)).

-spec(start_child(supervisor:child_spec()) -> {ok, pid()} | {error, any()}).
start_child(ChildSpec) ->
	supervisor:start_child(?MODULE, ChildSpec).

%% @doc Stop the listener.
-spec(stop_listener(atom(), esockd:listen_on()) -> ok | {error, any()}).
stop_listener(Protocol, ListenOn) ->
    ChildId = child_id(Protocol, ListenOn),
	case supervisor:terminate_child(?MODULE, ChildId) of
    ok ->
        supervisor:delete_child(?MODULE, ChildId);
    {error, Reason} ->
        {error, Reason}
	end.

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

-spec(restart_listener(atom(), esockd:listen_on()) -> ok | {error, any()}).
restart_listener(Protocol, ListenOn) ->
    ChildId = child_id(Protocol, ListenOn),
    case supervisor:terminate_child(?MODULE, ChildId) of
        ok    -> supervisor:restart_child(?MODULE, ChildId);
        Error -> Error
    end.

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 10, 100}, [?CHILD(esockd_server, worker)]}}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

%% @doc Listener ChildId.
%% @private
child_id(Protocol, ListenOn) ->
    {listener_sup, {Protocol, ListenOn}}.

