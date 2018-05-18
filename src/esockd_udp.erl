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

-module(esockd_udp).

-author("Feng Lee <feng@emqtt.io>").

-export([server/4, count_peers/1, stop/1]).

%% gen_server.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {proto, sock, mfa, peers}).

-define(DEFAULT_OPTS, [binary, {reuseaddr, true}]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(server(atom(), inet:port() | {inet:ip_address(), inet:port()},
             list(gen_udp:option()), mfa()) -> {ok, pid()} | {error, term()}).
server(Proto, {Addr, Port}, Opts, MFA) when is_integer(Port) ->
    {IPAddr, _Port} = fixaddr({Addr, Port}),
    IfAddr = proplists:get_value(ip, udp_options(Opts)),
    if
        (IfAddr == undefined) or (IfAddr == IPAddr) -> ok;
        true -> error(badmatch_ipaddr)
    end,
    server(Proto, Port, merge_addr(IPAddr, Opts), MFA);

server(Proto, Port, Opts, MFA) when is_integer(Port) ->
    gen_server:start_link(?MODULE, [Proto, Port, Opts, MFA],
                          [{hibernate_after, 1000}]).

udp_options(Opts) ->
    proplists:get_value(udp_options, Opts, []).

count_peers(Pid) ->
    gen_server:call(Pid, count_peers).

stop(Server) ->
    gen_server:stop(Server, normal, infinity).

%%--------------------------------------------------------------------
%% gen_server Callbacks
%%--------------------------------------------------------------------

init([Proto, Port, Options, MFA]) ->
    process_flag(trap_exit, true),
    case gen_udp:open(Port, esockd_util:merge_opts(?DEFAULT_OPTS, Options)) of
        {ok, Sock} ->
            inet:setopts(Sock, [{active, 10}]),
            io:format("~s opened on udp ~p~n", [Proto, Port]),
            {ok, #state{proto = Proto, sock = Sock, mfa = MFA, peers = #{}}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(count_peers, _From, State = #state{peers = Peers}) ->
    {reply, maps:size(Peers) div 2, State};

handle_call(_Req, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, Socket, IP, InPortNo, Packet},
            State = #state{peers = Peers, mfa = {M, F, Args}}) ->
    Peer = {IP, InPortNo},
    case maps:find(Peer, Peers) of
        {ok, Pid} ->
            Pid ! {datagram, self(), Packet},
            {noreply, State};
        error ->
            case catch apply(M, F, [Socket, Peer | Args]) of
                {ok, Pid} ->
                    link(Pid),
                    Pid ! {datagram, self(), Packet},
                    {noreply, store_peer(Peer, Pid, State)};
                {Err, Reason} when Err == error; Err == 'EXIT' ->
                    error_logger:error_msg("Failed to start client for udp ~s, reason: ~p",
                                           [esockd_net:format(Peer), Reason]),
                    {noreply, State}
            end
    end;

handle_info({udp_passive, Sock}, State) ->
    inet:setopts(Sock, [{active, 100}]),
    {noreply, State, hibernate};

handle_info({'EXIT', Pid, _Reason}, State = #state{peers = Peers}) ->
    case maps:find(Pid, Peers) of
        {ok, Peer} -> {noreply, erase_peer(Peer, Pid, State)};
        error      -> {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{sock = Sock}) ->
    gen_udp:close(Sock).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internel functions
%%--------------------------------------------------------------------

store_peer(Peer, Pid, State = #state{peers = Peers}) ->
    State#state{peers = maps:put(Pid, Peer,
                                 maps:put(Peer, Pid, Peers))}.

erase_peer(Peer, Pid, State = #state{peers = Peers}) ->
    State#state{peers = maps:remove(Peer, maps:remove(Pid, Peers))}.

fixaddr(Port) when is_integer(Port) ->
    Port;
fixaddr({Addr, Port}) when is_list(Addr) and is_integer(Port) ->
    {ok, IPAddr} = inet:parse_address(Addr), {IPAddr, Port};
fixaddr({Addr, Port}) when is_tuple(Addr) and is_integer(Port) ->
    case esockd_cidr:is_ipv6(Addr) or esockd_cidr:is_ipv4(Addr) of
        true  -> {Addr, Port};
        false -> error(invalid_ipaddr)
    end.

merge_addr(Addr, Opts) ->
    lists:keystore(ip, 1, Opts, {ip, Addr}).

