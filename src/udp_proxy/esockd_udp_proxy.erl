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

-module(esockd_udp_proxy).

-behaviour(gen_server).

-include("include/esockd_proxy.hrl").

%% API
-export([start_link/3, send/2, close/1]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-export_type([connection_options/0]).

-define(NOW, erlang:system_time(second)).
-define(ERROR_MSG(Format, Args),
    error_logger:error_msg("[~s]: " ++ Format, [?MODULE | Args])
).
-define(DEF_HEARTBEAT, 60).

-type timespan() :: non_neg_integer().

%%--------------------------------------------------------------------
%%  Definitions
%%--------------------------------------------------------------------

-type state() :: #{
    connection_mod := connection_module(),
    connection_id := connection_id() | undefined,
    connection_state := connection_state(),
    connection_options := connection_options(),
    %% last source's connection active time
    last_time := pos_integer(),
    transport := proxy_transport(),
    peer := peer()
}.

%%--------------------------------------------------------------------
%%- API
%%--------------------------------------------------------------------

start_link(Transport, Peer, Opts) ->
    gen_server:start_link(?MODULE, [Transport, Peer, Opts], []).

-spec send(proxy_id(), binary()) -> ok.
send(ProxyId, Data) ->
    gen_server:cast(ProxyId, {send, Data}).

close(ProxyId) ->
    case erlang:is_process_alive(ProxyId) of
        true ->
            gen_server:call(ProxyId, close);
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
%%- gen_server callbacks
%%--------------------------------------------------------------------

init([Transport, Peer, #{esockd_proxy_opts := Opts} = COpts]) ->
    #{connection_mod := Mod} = Opts,
    heartbeat(maps:get(heartbeat, Opts, ?DEF_HEARTBEAT)),
    init_transport(Transport, Peer, #{
        last_time => ?NOW,
        connection_mod => Mod,
        connection_options => COpts,
        connection_state => esockd_udp_proxy_connection:initialize(Mod, COpts),
        connection_id => undefined
    }).

handle_call(close, _From, State) ->
    {stop, {shutdown, close_transport}, ok, State};
handle_call(Request, _From, State) ->
    ?ERROR_MSG("Unexpected call: ~p", [Request]),
    {reply, ok, State}.

handle_cast({send, Data}, #{transport := Transport, peer := Peer} = State) ->
    case send(Transport, Peer, Data) of
        ok ->
            {noreply, State};
        {error, Reason} ->
            ?ERROR_MSG("Send failed, Reason: ~0p", [Reason]),
            {stop, {sock_error, Reason}, State}
    end;
handle_cast(Request, State) ->
    ?ERROR_MSG("Unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info({datagram, _SockPid, Data}, State) ->
    {noreply, handle_incoming(Data, State)};
handle_info({ssl, _Socket, Data}, State) ->
    {noreply, handle_incoming(Data, State)};
handle_info({heartbeat, Span}, #{last_time := LastTime} = State) ->
    Now = ?NOW,
    case Now - LastTime > Span of
        true ->
            {stop, normal, State};
        _ ->
            heartbeat(Span),
            {noreply, State}
    end;
handle_info({ssl_error, _Sock, Reason}, State) ->
    {stop, Reason, socket_exit(State)};
handle_info({ssl_closed, _Sock}, State) ->
    {stop, ssl_closed, socket_exit(State)};
handle_info(
    {'DOWN', _, process, _, _Reason},
    State
) ->
    {stop, {shutdown, connection_closed}, State};
handle_info(Info, State) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(Reason, #{transport := Transport} = State) ->
    close_transport(Transport),
    Clear =
        case Reason of
            close_transport ->
                false;
            connection_closed ->
                false;
            _ ->
                true
        end,
    detach(State, Clear).

%%--------------------------------------------------------------------
%%- Internal functions
%%--------------------------------------------------------------------
-spec handle_incoming(socket_packet(), state()) -> state().
handle_incoming(
    Data,
    #{transport := Transport, peer := Peer, connection_mod := Mod, connection_state := CState} =
        State
) ->
    State2 = State#{last_time := ?NOW},
    case esockd_udp_proxy_connection:get_connection_id(Mod, Transport, Peer, CState, Data) of
        {ok, CId, Packet, CState2} ->
            dispatch(Mod, CId, Data, Packet, State2#{connection_state := CState2});
        invalid ->
            ?ERROR_MSG("Can't get connection id, Transport:~0p, Peer:~0p, Mod:~0p", [
                Transport, Peer, Mod
            ]),
            State2
    end.

-spec dispatch(
    connection_module(),
    esockd_transport:socket(),
    connection_id(),
    connection_packet(),
    state()
) ->
    state().
dispatch(
    Mod,
    CId,
    Data,
    Packet,
    #{
        transport := Transport,
        peer := Peer,
        connection_state := CState,
        connection_options := Opts
    } =
        State
) ->
    case lookup(Mod, Transport, Peer, CId, Opts) of
        {ok, Pid} ->
            esockd_udp_proxy_connection:dispatch(
                Mod, Pid, CState, {Transport, Data, Packet}
            ),
            attach(CId, State);
        {error, Reason} ->
            ?ERROR_MSG("Dispatch failed, Reason:~0p", [Reason]),
            State
    end.

-spec attach(connection_id(), state()) -> state().
attach(CId, #{connection_mod := Mod, connection_id := undefined} = State) ->
    esockd_udp_proxy_db:attach(Mod, CId),
    State#{connection_id := CId};
attach(CId, #{connection_id := OldId} = State) when CId =/= OldId ->
    State2 = detach(State),
    attach(CId, State2);
attach(_CId, State) ->
    State.

-spec detach(state()) -> state().
detach(State) ->
    detach(State, true).

-spec detach(state(), boolean()) -> state().
detach(#{connection_id := undefined} = State, _Clear) ->
    State;
detach(#{connection_id := CId, connection_mod := Mod, connection_state := CState} = State, Clear) ->
    case esockd_udp_proxy_db:detach(Mod, CId) of
        {Clear, Pid} ->
            case erlang:is_process_alive(Pid) of
                true ->
                    esockd_udp_proxy_connection:close(Mod, Pid, CState);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    State#{connection_id := undefined}.

-spec socket_exit(state()) -> state().
socket_exit(State) ->
    detach(State).

-spec heartbeat(timespan()) -> ok.
heartbeat(Span) ->
    erlang:send_after(timer:seconds(Span), self(), {?FUNCTION_NAME, Span}),
    ok.

-spec lookup(
    connection_module(),
    proxy_transport(),
    peer(),
    connection_id(),
    connection_options()
) -> {ok, pid()} | {error, Reason :: term()}.
lookup(Mod, Transport, Peer, CId, Opts) ->
    case esockd_udp_proxy_db:lookup(Mod, CId) of
        {ok, _} = Ok ->
            Ok;
        undefined ->
            case esockd_udp_proxy_connection:create(Mod, Transport, Peer, Opts) of
                {ok, Pid} ->
                    esockd_udp_proxy_db:insert(Mod, CId, Pid),
                    _ = erlang:monitor(process, Pid),
                    {ok, Pid};
                ignore ->
                    {error, ignore};
                Error ->
                    Error
            end
    end.

-spec send(proxy_transport(), peer(), binary()) -> _.
send({?PROXY_TRANSPORT, _, Socket}, {IP, Port}, Data) when is_port(Socket) ->
    gen_udp:send(Socket, IP, Port, Data);
send({?PROXY_TRANSPORT, _, Socket}, _Peer, Data) ->
    esockd_transport:send(Socket, Data).

init_transport({udp, _, Sock}, Peer, State) ->
    {ok, State#{
        transport => {?PROXY_TRANSPORT, self(), Sock},
        peer => Peer
    }};
init_transport(esockd_transport, Sock, State) ->
    case esockd_transport:wait(Sock) of
        {ok, NSock} ->
            {ok, State#{
                transport => {?PROXY_TRANSPORT, self(), NSock},
                peer => esockd_transport:peername(NSock)
            }};
        Error ->
            Error
    end.

close_transport({?PROXY_TRANSPORT, _, Sock}) when is_port(Sock) ->
    ok;
close_transport({?PROXY_TRANSPORT, _, Sock}) ->
    esockd_transport:fast_close(Sock).
