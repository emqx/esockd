%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%--------------------------------------------------------------------

-module(const_server).

-export([start_link/3]).

%% Callbacks
-export([init/3, loop/3]).

start_link(Transport, RawSock, Resp) ->
	{ok, spawn_link(?MODULE, init, [Transport, RawSock, Resp])}.

init(Transport, RawSock, Resp) ->
    case Transport:wait(RawSock) of
        {ok, Sock} ->
            loop(Transport, Sock, Resp);
        {error, Reason} ->
            {error, Reason}
    end.

loop(Transport, Sock, Resp) ->
	case Transport:recv(Sock, 0) of
        {ok, _Data} ->
            Transport:send(Sock, Resp),
            loop(Transport, Sock, Resp);
        {shutdown, Reason} ->
            exit({shutdown, Reason});
        {error, Reason} ->
            exit({shutdown, Reason})
	end.

