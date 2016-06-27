%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2016 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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
%%% eSockd UDP Server.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_udp).

-author("Feng Lee <feng@emqtt.io>").

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
    gen_server:start_link(?MODULE, [Protocol, Port, Opts, MFA], []).

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
    case gen_udp:open(Port, merge_opts(?SOCKOPTS, Opts1)) of
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
            Pid ! {datagram, Packet},
            noreply(State);
        error ->
            case catch apply(M, F, [Socket, Peer | Args]) of
                {ok, Pid} ->
                    link(Pid), put(Pid, Peer),
                    Pid ! {datagram, Packet},
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

terminate(_Reason, State = #state{sock = Sock}) ->
    gen_udp:close(Sock).

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% Internel functions
%%--------------------------------------------------------------------

merge_opts(Defaults, Options) ->
    lists:foldl(
        fun({Opt, Val}, Acc) ->
                case lists:keymember(Opt, 1, Acc) of
                    true  -> lists:keyreplace(Opt, 1, Acc, {Opt, Val});
                    false -> [{Opt, Val}|Acc]
                end;
            (Opt, Acc) ->
                case lists:member(Opt, Acc) of
                    true  -> Acc;
                    false -> [Opt | Acc]
                end
    end, Defaults, Options).

store_peer(Peer, Pid, State = #state{peers = Peers}) ->
    State#state{peers = dict:store(Peer, Pid, Peers)}.

erase_peer(Peer, State = #state{peers = Peers}) ->
    State#state{peers = dict:erase(Peer, Peers)}.

noreply(State) -> {noreply, State, hibernate}.

log_error(Logger, Peer, Reason) ->
    Logger:error("Failed to start client for udp ~s, reason: ~p",
                 [esockd_net:format(Peer), Reason]).

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

