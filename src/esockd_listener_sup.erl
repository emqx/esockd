%%%===================================================================
%%% Copyright (c) 2013-2018 EMQ Inc. All rights reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%===================================================================

-module(esockd_listener_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

-export([start_link/4, listener/1, acceptor_sup/1, connection_sup/1]).

-export([init/1]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start Listener Supervisor
-spec(start_link(atom(), esockd:listen_on(), [esockd:option()], esockd:mfargs())
      -> {ok, pid()}).
start_link(Protocol, ListenOn, Options, MFArgs) ->
    {ok, Sup} = supervisor:start_link(?MODULE, []),
	{ok, ConnSup} = supervisor:start_child(Sup,
		{connection_sup,
			{esockd_connection_sup, start_link, [Options, MFArgs]},
				transient, infinity, supervisor, [esockd_connection_sup]}),
    AcceptStatsFun = esockd_server:stats_fun({Protocol, ListenOn}, accepted),
    BufferTuneFun = buffer_tune_fun(
                      proplists:get_value(buffer, Options),
                      proplists:get_value(tune_buffer, Options, false)),
	{ok, AcceptorSup} = supervisor:start_child(Sup,
		{acceptor_sup,
			{esockd_acceptor_sup, start_link, [ConnSup, AcceptStatsFun, BufferTuneFun]},
				transient, infinity, supervisor, [esockd_acceptor_sup]}),
	{ok, _Listener} = supervisor:start_child(Sup,
		{listener,
			{esockd_listener, start_link, [Protocol, ListenOn, Options, AcceptorSup]},
				transient, 16#ffffffff, worker, [esockd_listener]}),
	{ok, Sup}.

%% @doc Get Listener.
listener(Sup) ->
    child_pid(Sup, listener).

%% @doc Get connection supervisor.
connection_sup(Sup) ->
    child_pid(Sup, connection_sup).

%% @doc Get acceptor supervisor.
acceptor_sup(Sup) ->
    child_pid(Sup, acceptor_sup).

%% @doc Get child pid with id.
%% @private
child_pid(Sup, ChildId) ->
    hd([Pid || {Id, Pid, _, _} <- supervisor:which_children(Sup), Id =:= ChildId]).

%%------------------------------------------------------------------------------
%% Supervisor callbacks
%%------------------------------------------------------------------------------

init([]) ->
    {ok, {{rest_for_one, 10, 3600}, []}}.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

%% when 'buffer' is undefined, and 'tune_buffer' is true...
buffer_tune_fun(undefined, true) ->
    fun(Sock) ->
        case inet:getopts(Sock, [sndbuf, recbuf, buffer]) of
            {ok, BufSizes} ->
                BufSz = lists:max([Sz || {_Opt, Sz} <- BufSizes]),
                inet:setopts(Sock, [{buffer, BufSz}]);
            Error -> Error
        end
    end;

buffer_tune_fun(_, _) ->
    fun(_Sock) -> ok end.

