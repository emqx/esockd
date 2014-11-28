%%------------------------------------------------------------------------------
%% Copyright (c) 2014, Feng Lee <feng.lee@slimchat.io>
%% 
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%% 
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%------------------------------------------------------------------------------

-module(esockd_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, 
		start_listener/3, start_listener/4,
		stop_listener/1, stop_listener/2]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor2:start_link({local, ?MODULE}, ?MODULE, []).

start_listener(Port, SocketOpts, Callback) ->
	ChildSpec = listener_child(listener_name(Port), Port, SocketOpts, Callback),
	supervisor2:start_child(?MODULE, ChildSpec).

start_listener(Name, Port, SocketOpts, Callback) ->
	ChildSpec = listener_child(listener_name(Name, Port), Port, SocketOpts, Callback),
	supervisor2:start_child(?MODULE, ChildSpec).

stop_listener(Port) ->
	Name = listener_name(Port),
	case supervisor2:terminate_child(?MODULE, Name) of
	ok -> supervisor2:delete_child(?MODULE, Name);
	{error, Reason} -> {error, Reason}
	end.

stop_listener(Name, Port) ->
	supervisor2:terminate_child(?MODULE, listener_name(Name, Port)).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
init([]) ->
    {ok, { {one_for_one, 5, 10}, [?CHILD(esockd_manager, worker)]} }.


%% ===================================================================
%% Internal functions

%% ===================================================================
listener_child(Name, Port, SocketOpts, Callback) -> 
	MFA = {esockd_listener_sup, start_link, [Port, SocketOpts, Callback]}, 
	{Name, MFA, transient, infinity, supervisor, [esockd_listener_sup]}.

listener_name(Port) -> {listener_sup, Port}.

listener_name(Name, Port) -> {listener_sup, Name, Port}.

