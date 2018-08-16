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

-export([server/4, stop/1]).

%% gen_server.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {proto, sock, mfa, peers, logger}).

-define(SOCKOPTS, [binary, {active, once}, {reuseaddr, true}]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(server(atom(), inet:port() | {inet:ip_address(), inet:port()},
             list(gen_udp:option()), mfa()) -> {ok, pid()}).
server(Protocol, Port, Opts, MFA) when is_integer(Port) ->
    gen_server:start_link(?MODULE, [Protocol, Port, Opts, MFA], []);

server(Protocol, {Address, Port}, Opts, MFA) when is_integer(Port) ->
    {IPAddr, _Port}  = fixaddr({Address, Port}),
    OptAddr = proplists:get_value(ip, proplists:get_value(sockopts, Opts, [])),
    if
        (OptAddr == undefined) or (OptAddr == IPAddr) -> ok;
        true -> error(badmatch_ipaddress)
    end,
    gen_server:start_link(?MODULE, [Protocol, Port, merge_addr(IPAddr, Opts), MFA], []).

stop(Server) ->
    gen_server:call(Server, stop).

%%--------------------------------------------------------------------
%% gen_server Callbacks
%%--------------------------------------------------------------------

init([Protocol, Port, Opts, MFA]) ->
    process_flag(trap_exit, true),
    Logger = init_logger(Opts),
    %% Delete {logger, LogMod}, {active, false}
    Opts1 = proplists:delete(logger, proplists:delete(active, Opts)),
    case gen_udp:open(Port, esockd_util:merge_opts(?SOCKOPTS, Opts1)) of
        {ok, Sock} ->
            io:format("~s opened on udp ~p~n", [Protocol, Port]),
            {ok, #state{proto = Protocol, sock = Sock, mfa = MFA,
                        peers = dict:new(), logger = Logger}};
        {error, Reason} ->
            {stop, Reason}
    end.

init_logger(Opts) ->
    Default = application:get_env(esockd, logger, {error_logger, info}),
    gen_logger:new(proplists:get_value(logger, Opts, Default)).

handle_call(stop, _From, State) ->
	{stop, normal, ok, State};

handle_call(_Req, _From, State) ->
	{reply, ignored, State}.

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({udp, Socket, IP, InPortNo, Packet},
            State = #state{peers = Peers,mfa = {M, F, Args}, logger = Logger}) ->
    Peer = {IP, InPortNo},
    inet:setopts(Socket, [{active, once}]),
    case dict:find(Peer, Peers) of
        {ok, Pid} ->
            Pid ! {datagram, self(), Packet},
            noreply(State);
        error ->
            case catch apply(M, F, [Socket, Peer | Args]) of
                {ok, Pid} ->
                    link(Pid), put(Pid, Peer),
                    Pid ! {datagram, self(),Packet},
                    noreply(store_peer(Peer, Pid, State));
                {Err, Reason} when Err == error orelse Err == 'EXIT' ->
                    log_error(Logger, Peer, Reason), 
                    noreply(State)
            end
    end;

handle_info({'EXIT', Pid, _Reason}, State) ->
    noreply(case get(Pid) of
                undefined -> State;
                Peer      -> erase(Pid),
                             erase_peer(Peer, State)
            end);

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
    State#state{peers = dict:store(Peer, Pid, Peers)}.

erase_peer(Peer, State = #state{peers = Peers}) ->
    State#state{peers = dict:erase(Peer, Peers)}.

noreply(State) -> {noreply, State, hibernate}.

log_error(Logger, Peer, Reason) ->
    Logger:error("Failed to start client for udp ~s, reason: ~p",
                 [esockd_net:format(Peer), Reason]).


%% @doc Parse Address
%% @private
fixaddr(Port) when is_integer(Port) ->
    Port;
fixaddr({Addr, Port}) when is_list(Addr) and is_integer(Port) ->
    {ok, IPAddr} = inet:parse_address(Addr), {IPAddr, Port};
fixaddr({Addr, Port}) when is_tuple(Addr) and is_integer(Port) ->
    case esockd_cidr:is_ipv6(Addr) or esockd_cidr:is_ipv4(Addr) of
        true  -> {Addr, Port};
        false -> error(invalid_ipaddress)
    end.


merge_addr(Addr, SockOpts) ->
    lists:keystore(ip, 1, SockOpts, {ip, Addr}).


-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

store_peer_test() ->
    Peer = {{127,0,0,1}, 9000},
    State = store_peer(Peer, self(), #state{peers = dict:new()}),
    ?assertEqual({ok, self()}, dict:find(Peer, State#state.peers)),
    State1 = erase_peer(Peer, State),
    ?assertEqual(error, dict:find(Peer, State1#state.peers)).

log_error_test() ->
    Logger = gen_logger:new({console, info}),
    log_error(Logger, {{127,0,0,1}, 18381}, badmatch).

-endif.

