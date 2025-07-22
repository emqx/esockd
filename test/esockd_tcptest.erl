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

-module(esockd_tcptest).

-export([start/1]).
-export([command/1]).

-export([start_connection/2]).
-export([init_connection/2]).

-define(COMMAND_SIZE, 64).

-define(RECV_TIMEOUT_MS, 5_000).
-define(SLEEP_TIME_MS, 15_000).

%%

start(Args) ->
    {ok, _} = application:ensure_all_started(esockd),
    Port = list_to_integer(argv(1, Args)),
    ok = logger:set_primary_config(level, info),
    {ok, Pid} = esockd:open(tcp, {"0.0.0.0", Port}, [
        {acceptors, 4},
        {backlog, 8},
        {buffer, 8192},
        {send_timeout, 5000},
        {tcp_options, [binary, {show_econnreset, true}]},
        {connection_mfargs, {?MODULE, start_connection}}
    ]),
    logger:info("Started esockd ~p on port ~p", [Pid, Port]),
    ok.

argv(N, Args) ->
    to_string(lists:nth(N, Args)).

to_string(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
to_string(Binary) when is_binary(Binary) ->
    binary_to_list(Binary);
to_string(String) when is_list(String) ->
    String.

%%

command({sleep, Time} = Command) when is_integer(Time) ->
    encode_command(Command);
command(echo) ->
    encode_command(echo);
command(close) ->
    encode_command(close).

encode_command(Command) ->
    Serial = term_to_binary(Command),
    <<Serial/bytes, 0:(?COMMAND_SIZE - byte_size(Serial))/integer-unit:8>>.

decode_command(Command) ->
    binary_to_term(Command).

%%

start_connection(Transport, SockIn) ->
    {ok, spawn_link(?MODULE, init_connection, [Transport, SockIn])}.

init_connection(Transport, SockIn) ->
    case Transport:wait(SockIn) of
        {ok, Sock} ->
            before_loop(Transport, Sock);
        {error, Reason} ->
            {error, Reason}
    end.

before_loop(Transport, Sock) ->
    logger:info("[~s] Waiting for command", [format_peername(Transport, Sock)]),
    case Transport:recv(Sock, ?COMMAND_SIZE, ?RECV_TIMEOUT_MS) of
        {ok, Packet} ->
            Command = decode_command(Packet),
            logger:info("[~s] Incoming command: ~0p", [format_peername(Transport, Sock), Command]),
            case Command of
                {sleep, Time} ->
                    ok = timer:sleep(Time),
                    echo_loop(Transport, Sock);
                echo ->
                    echo_loop(Transport, Sock);
                close ->
                    Transport:close(Sock)
            end;
        {error, timeout} ->
            logger:info("[~s] Command timeout", [format_peername(Transport, Sock)]),
            Transport:close(Sock);
        {error, Reason} ->
            logger:info("[~s] Connection error: ~0p", [format_peername(Transport, Sock), Reason]),
            ok
    end.

echo_loop(Transport, Sock) ->
    case Transport:recv(Sock, 0, infinity) of
        {ok, Data} ->
            logger:info("[~s] Echoing back: ~0P", [format_peername(Transport, Sock), Data, 100]),
            Transport:send(Sock, Data),
            echo_loop(Transport, Sock);
        {error, Reason} ->
            logger:info("[~s] Connection error: ~0p", [format_peername(Transport, Sock), Reason]),
            ok
    end.

format_peername(Transport, Sock) ->
    case Transport:peername(Sock) of
        {ok, Peername} ->
            esockd:format(Peername);
        {error, Reason} ->
            io_lib:format("~0p", [Reason])
    end.
