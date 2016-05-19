%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2016 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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
%%% eSockd top supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

%% API
-export([start_link/0]).

-export([start_listener/4, stop_listener/2, listeners/0, listener/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%%%-----------------------------------------------------------------------------
%%% API
%%%-----------------------------------------------------------------------------

%% @doc Start supervisor.
-spec(start_link() -> {ok, pid()}).
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a listener.
-spec(start_listener(Protocol, Port, Options, MFArgs) -> {ok, pid()} when
      Protocol :: atom(),
      Port     :: inet:port_number(),
      Options  :: [esockd:option()],
      MFArgs   :: esockd:mfargs()).
start_listener(Protocol, Port, Options, MFArgs) ->
	MFA = {esockd_listener_sup, start_link,
            [Protocol, Port, Options, MFArgs]},
	ChildSpec = {child_id({Protocol, Port}), MFA,
                    transient, infinity, supervisor, [esockd_listener_sup]},
	supervisor:start_child(?MODULE, ChildSpec).

%% @doc Stop the listener.
-spec(stop_listener(Protocol, Port) -> ok | {error, any()} when
      Protocol :: atom(),
      Port     :: inet:port_number()).
stop_listener(Protocol, Port) ->
    ChildId = child_id({Protocol, Port}),
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
-spec(listener({atom(), inet:port_number()}) -> undefined | pid()).
listener({Protocol, Port}) ->
    ChildId = child_id({Protocol, Port}),
    case [Pid || {Id, Pid, supervisor, _} <- supervisor:which_children(?MODULE), Id =:= ChildId] of
        [] -> undefined;
        L  -> hd(L)
    end.

%%%-----------------------------------------------------------------------------
%%% Supervisor callbacks
%%%-----------------------------------------------------------------------------

init([]) ->
    {ok, {{one_for_one, 10, 100}, [?CHILD(esockd_server, worker)]} }.

%%%-----------------------------------------------------------------------------
%%% Internal functions
%%%-----------------------------------------------------------------------------

%% @doc Listener Child Id.
%% @private
child_id({Protocol, Port}) ->
    {listener_sup, {Protocol, Port}}.

