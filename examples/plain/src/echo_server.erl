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
%%% @doc
%%% Simple Echo Server.
%%%
%%% @end
%%%===================================================================

-module(echo_server).

-export([start/0, start/1]).
-export([accept/2, recvloop/1]).

%% @doc Start echo server.
start() -> start(5000).
%% shell
start([Port]) when is_atom(Port) ->
    start(list_to_integer(atom_to_list(Port)));
start(Port) when is_integer(Port) ->
    _ = application:start(sasl),
    {ok, LSock} = gen_tcp:listen(Port, [{active, false}]),
    io:format("Listening on ~p~n", [Port]),
    self() ! accept,
    mainloop(self(), LSock).

mainloop(Parent, LSock) ->
    receive
        accept ->
            spawn(?MODULE, accept, [Parent, LSock]),
            mainloop(Parent, LSock);
        stop -> stop
    end.

accept(Parent, LSock) ->
    {ok, Sock} = gen_tcp:accept(LSock),
    {ok, Peername} = inet:peername(Sock),
    io:format("Connection from ~p~n", [Peername]),
    Parent ! accept,
    recvloop(Sock).

recvloop(Sock) ->
	case gen_tcp:recv(Sock, 0, 30000) of
		{ok, Data} ->
			{ok, Peername} = inet:peername(Sock),
            io:format("Data from ~s: ~s~n",
                      [esockd_net:format(peername, Peername), Data]),
			gen_tcp:send(Sock, Data),
			recvloop(Sock);
		{error, Reason} ->
			io:format("TCP closed for ~s~n", [Reason]),
			{stop, Reason}
	end.

