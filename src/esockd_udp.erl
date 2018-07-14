%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_udp).

-behaviour(gen_server).

-export([server/4, count_peers/1, stop/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {proto, sock, port, peers, mfa}).

-define(ERROR_MSG(Format, Args),
        error_logger:error_msg("[~s]: " ++ Format, [?MODULE | Args])).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

-spec(server(atom(), esockd:listen_on(), [gen_udp:option()], mfa())
      -> {ok, pid()} | {error, term()}).
server(Proto, Port, Opts, MFA) when is_integer(Port) ->
    gen_server:start_link(?MODULE, [Proto, Port, Opts, MFA], []);
server(Proto, {Host, Port}, Opts, MFA) when is_integer(Port) ->
    IfAddr = case proplists:get_value(ip, Opts) of
                 undefined -> proplists:get_value(ifaddr, Opts);
                 Addr      -> Addr
             end,
    (IfAddr == undefined) orelse (IfAddr = Host),
    gen_server:start_link(?MODULE, [Proto, Port, merge_addr(Host, Opts), MFA], []).

merge_addr(Addr, Opts) ->
    lists:keystore(ip, 1, Opts, {ip, Addr}).

-spec(count_peers(pid()) -> integer()).
count_peers(Pid) ->
    gen_server:call(Pid, count_peers).

-spec(stop(pid()) -> ok).
stop(Pid) ->
    gen_server:stop(Pid, normal, infinity).

%%------------------------------------------------------------------------------
%% gen_server callbacks
%%------------------------------------------------------------------------------

init([Proto, Port, Opts, MFA]) ->
    process_flag(trap_exit, true),
    case gen_udp:open(Port, esockd_util:merge_opts([binary, {reuseaddr, true}], Opts)) of
        {ok, Sock} ->
            %% Trigger the udp_passive event
            inet:setopts(Sock, [{active, 1}]),
            io:format("~s opened on udp ~p~n", [Proto, Port]),
            {ok, #state{proto = Proto, sock = Sock, port = Port, peers = #{}, mfa = MFA}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call(count_peers, _From, State = #state{peers = Peers}) ->
    {reply, maps:size(Peers) div 2, State, hibernate};

handle_call(Req, _From, State) ->
    ?ERROR_MSG("unexpected call: ~p", [Req]),
    {reply, ignored, State}.

handle_cast(Msg, State) ->
    ?ERROR_MSG("unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({udp, Sock, IP, InPortNo, Packet},
            State = #state{sock = Sock, peers = Peers, mfa = {M, F, Args}}) ->
    Peer = {IP, InPortNo},
    case maps:find(Peer, Peers) of
        {ok, Pid} ->
            Pid ! {datagram, self(), Packet},
            {noreply, State};
        error ->
            case catch erlang:apply(M, F, [{udp, self(), Sock}, Peer | Args]) of
                {ok, Pid} ->
                    _Ref = erlang:monitor(process, Pid),
                    Pid ! {datagram, self(), Packet},
                    {noreply, store_peer(Peer, Pid, State)};
                {Err, Reason} when Err =:= error; Err =:= 'EXIT' ->
                    ?ERROR_MSG("Failed to start udp channel: ~s, reason: ~p",
                               [esockd_net:format(Peer), Reason]),
                    {noreply, State}
            end
    end;

handle_info({udp_passive, Sock}, State) ->
    %% TODO: rate limit here?
    inet:setopts(Sock, [{active, 100}]),
    {noreply, State, hibernate};

handle_info({'DOWN', _MRef, process, DownPid, _Reason}, State = #state{peers = Peers}) ->
    case maps:find(DownPid, Peers) of
        {ok, Peer} -> {noreply, erase_peer(Peer, DownPid, State)};
        error      -> {noreply, State}
    end;

handle_info({datagram, Peer = {IP, Port}, Packet}, State = #state{sock = Sock}) ->
    case gen_udp:send(Sock, IP, Port, Packet) of
        ok -> ok;
        {error, Reason} ->
            ?ERROR_MSG("Dropped packet to: ~s, reason: ~s", [esockd_net:format(Peer), Reason])
    end,
    {noreply, State};

handle_info(Info, State) ->
    ?ERROR_MSG("unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{sock = Sock}) ->
    gen_udp:close(Sock).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%-----------------------------------------------------------------------------
%% Internel functions
%%-----------------------------------------------------------------------------

store_peer(Peer, Pid, State = #state{peers = Peers}) ->
    State#state{peers = maps:put(Pid, Peer, maps:put(Peer, Pid, Peers))}.

erase_peer(Peer, Pid, State = #state{peers = Peers}) ->
    State#state{peers = maps:remove(Peer, maps:remove(Pid, Peers))}.

