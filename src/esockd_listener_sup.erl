%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2014-2015, Feng Lee <feng@emqtt.io>
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
%%% eSockd Listener Supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_listener_sup).

-author('feng@emqtt.io').

-behaviour(supervisor).

-export([start_link/4, connection_sup/1, manager/1, acceptor_sup/1]).

-export([init/1]).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Start listener supervisor
%%
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Protocol, Port, Options, Callback) -> {ok, pid()} when
    Protocol  :: atom(),
    Port      :: inet:port_number(),
    Options	  :: [esockd:option()],
    Callback  :: esockd:callback().
start_link(Protocol, Port, Options, Callback) ->
    Logger = logger(Options),
    {ok, Sup} = supervisor:start_link(?MODULE, []),
	{ok, ConnSup} = supervisor:start_child(Sup,
		{connection_sup,
			{esockd_connection_sup, start_link, [Callback]},
				transient, infinity, supervisor, [esockd_connection_sup]}),
    %
    %{ok, Manager} = supervisor:start_child(Sup,
    %    {manager,
    %        {esockd_manager, start_link, [Options, ConnSup]},
    %            transient, 16#ffffffff, worker, [esockd_manager]}),
    AcceptStatsFun = esockd_server:stats_fun({Protocol, Port}, accepted),
	{ok, AcceptorSup} = supervisor:start_child(Sup,
		{acceptor_sup,
			{esockd_acceptor_sup, start_link, [ConnSup, AcceptStatsFun, Logger]},
				transient, infinity, supervisor, [esockd_acceptor_sup]}),
	{ok, _Listener} = supervisor:start_child(Sup,
		{listener,
			{esockd_listener, start_link, [Protocol, Port, Options, AcceptorSup, Logger]},
				transient, 16#ffffffff, worker, [esockd_listener]}),
	{ok, Sup}.

%%------------------------------------------------------------------------------
%% @doc
%% Get connection supervisor.
%%
%% @end
%%------------------------------------------------------------------------------
connection_sup(Sup) ->
    child_pid(Sup, connection_sup).

%%------------------------------------------------------------------------------
%% @doc
%% Get manager.
%%
%% @end
%%------------------------------------------------------------------------------
manager(Sup) ->
    child_pid(Sup, manager).

%%------------------------------------------------------------------------------
%% @doc
%% Get acceptor supervisor.
%%
%% @end
%%------------------------------------------------------------------------------
acceptor_sup(Sup) ->
    child_pid(Sup, acceptor_sup).

%%------------------------------------------------------------------------------
%% @doc
%% @private
%% Get child pid with id.
%%
%% @end
%%------------------------------------------------------------------------------
child_pid(Sup, ChildId) ->
    hd([Pid || {Id, Pid, _, _} <- supervisor:which_children(Sup), Id =:= ChildId]).
    
%%%=============================================================================
%% Supervisor callbacks
%%%=============================================================================
init([]) ->
    {ok, {{rest_for_one, 10, 100}, []}}.

%%%=============================================================================
%% Internal functions
%%%=============================================================================
logger(Options) ->
    {ok, Default} = application:get_env(esockd, logger),
    gen_logger:new(proplists:get_value(logger, Options, Default)).

