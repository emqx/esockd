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

-include("esockd.hrl").

-behaviour(supervisor).

%% API
-export([start_link/0, 
		start_listener/5,
		stop_listener/2]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

%%
%% @doc start supervisor
%%
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor2:start_link({local, ?MODULE}, ?MODULE, []).

%%
%% @doc start listener
%%
-spec start_listener(Protocol       :: atom(), 
                     Port           :: inet:port_number(),
                     SocketOpts     :: list(tuple()), 
                     AcceptorNum    :: integer(),
                     Callback       :: callback()) -> {ok, pid()}.
start_listener(Protocol, Port, SocketOpts, AcceptorNum, Callback) ->
    ChildId = {listener_sup, Protocol, Port},
    Args = [Protocol, Port, SocketOpts, AcceptorNum, Callback],
	MFA = {esockd_listener_sup, start_link, Args}, 
	ChildSpec = {ChildId, MFA, transient, infinity, supervisor, [esockd_listener_sup]},
	supervisor2:start_child(?MODULE, ChildSpec).

%%
%% @doc stop the listener
%%
-spec stop_listener(Protocol :: atom(),
                    Port     :: inet:port_number()) -> ok | {error, any()}.
stop_listener(Protocol, Port) ->
    ChildId = {listener_sup, Protocol, Port},
	case supervisor2:terminate_child(?MODULE, ChildId) of
    ok -> supervisor2:delete_child(?MODULE, ChildId);
    {error, Reason} -> {error, Reason}
	end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================
init([]) ->
    {ok, { {one_for_one, 5, 10}, [?CHILD(esockd_manager, worker)]} }.


%% ===================================================================
%% Internal functions
%% ===================================================================

