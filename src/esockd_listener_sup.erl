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

-export([start_link/4]).

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
-spec start_link(Protocol       :: atom(), 
                 Port           :: inet:port_number(),
                 Options		:: list(esockd:option()),
                 Callback       :: esockd:callback()) -> {ok, pid()}.
start_link(Protocol, Port, Options, Callback) ->
    {ok, Sup} = supervisor:start_link({local, name(listener_sup, {Protocol, Port})}, ?MODULE, []),
	{ok, ClientSup} = supervisor:start_child(Sup, 
		{client_sup, 
			{esockd_client_sup, start_link, [name(client_sup, {Protocol, Port}), Options, Callback]},
				transient, infinity, supervisor, [esockd_client_sup]}),
	{ok, AcceptorSup} = supervisor:start_child(Sup, 
		{acceptor_sup, 
			{esockd_acceptor_sup, start_link, [name(acceptor_sup, {Protocol, Port}), ClientSup]},
				transient, infinity, supervisor, [esockd_acceptor_sup]}),
	{ok, _Listener} = supervisor:start_child(Sup, 
		{listener, 
			{esockd_listener, start_link, [Protocol, Port, Options, AcceptorSup]},
				transient, 16#ffffffff, worker, [esockd_listener]}),
	{ok, Sup}.


%%%=============================================================================
%% Supervisor callbacks
%%%=============================================================================

init([]) ->
    %%TODO: one_for_all??
    {ok, {{one_for_all, 10, 10}, []}}.


%%%=============================================================================
%% Internal functions
%%%=============================================================================
-spec name(Mod, {Protocol, Port}) -> atom() when
    Mod      :: atom(),
    Protocol :: atom(),
    Port     :: inet:port_number().
name(Mod, {Protocol, Port}) ->
    list_to_atom(lists:concat([Mod, ':', Protocol, ':', Port])).
