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
%%% eSockd connection supervisor.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd_connection_sup).

-author('feng@emqtt.io').

-behaviour(supervisor).

%% API
-export([start_link/1, start_connection/2, count_connection/1]).

%% supervisor callback
-export([init/1]).

start_link(Callback) ->
    supervisor:start_link(?MODULE, [Callback]).

start_connection(Sup, SockArgs) ->
    supervisor:start_child(Sup, [SockArgs]).

count_connection(Sup) ->
    Children = supervisor:count_children(Sup), 
    proplists:get_value(workers, Children).

init([Callback]) ->
    ChildSpec = {connection,
                    {esockd_connection, start_link, [Callback]},
                        temporary, 5000, worker, [mod(Callback)]},
    {ok, {{simple_one_for_one, 0, 3600}, [ChildSpec]}}.

mod(M) when is_atom(M) -> M;
mod({M, _F}) when is_atom(M) -> M;
mod({M, _F, _A}) when is_atom(M) -> M.

