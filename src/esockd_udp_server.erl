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

-module(esockd_udp_server).

-behaviour(gen_server).

-export([start_link/4, count_peers/1, stop/1]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {proto, sock, mfa, peers}).

-define(DEFAULT_OPTS, [binary, {reuseaddr, true}]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(start_link(atom(), esockd:listen_on(), [gen_udp:option()], mfa())
      -> {ok, pid()} | {error, term()}).
start_link(Proto, Port, Opts, MFA) when is_integer(Port) ->
    gen_server:start_link(?MODULE, [Proto, Port, Opts, MFA], []);
start_link(Proto, {Addr, Port}, Opts, MFA) when is_integer(Port) ->
    IfAddr = proplists:get_value(ip, Opts),
    (IfAddr == undefined) orelse (IfAddr = Addr),
    gen_server:start_link(?MODULE,  [Proto, Port, merge_addr(Addr, Opts), MFA], []).

count_peers(Pid) ->
    gen_server:call(Pid, count_peers).

stop(Server) ->
    gen_server:stop(Server, normal, infinity).

%%--------------------------------------------------------------------
%% gen_server Callbacks
%%--------------------------------------------------------------------

init([Proto, Port, Opts, MFA]) ->
    process_flag(trap_exit, true),
    case gen_udp:open(Port, esockd_util:merge_opts(?DEFAULT_OPTS, Opts)) of
        {ok, Sock} ->
            inet:setopts(Sock, [{active, 10}]),
            io:format("~s opened on udp ~p~n", [Proto, Port]),
            {ok, #state{proto = Proto, sock = Sock, mfa = MFA, peers = #{}}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(count_peers, _From, State = #state{peers = Peers}) ->
    {reply, maps:size(Peers) div 2, State};

handle_call(Req, _From, State) ->
    error_logger:error_msg("[~s]: Unexpected call: ~p", [?MODULE, Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    error_logger:error_msg("[~s]: Unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.

handle_info({udp, Sock, IP, InPortNo, Packet},
            State = #state{sock = Sock, peers = Peers, mfa = {M, F, Args}}) ->
    Peer = {IP, InPortNo},
    case maps:find(Peer, Peers) of
        {ok, Pid} ->
            Pid ! {datagram, self(), Packet},
            {noreply, State};
        error ->
            case catch apply(M, F, [self(), Peer | Args]) of
                {ok, Pid} ->
                    link(Pid),
                    Pid ! {datagram, self(), Packet},
                    {noreply, store_peer(Peer, Pid, State)};
                {Err, Reason} when Err =:= error; Err =:= 'EXIT' ->
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

handle_info({datagram, {IP, Port}, Data}, State = #state{sock = Sock}) ->
    gen_udp:send(Sock, IP, Port, Data),
    {noreply, State};

handle_info(Info, State) ->
    error_logger:error_msg("[~s]: Unexpected info: ~p", [?MODULE, Info]),
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

merge_addr(Addr, Opts) ->
    lists:keystore(ip, 1, Opts, {ip, Addr}).

