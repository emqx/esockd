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

-module(esockd_udp).

-behaviour(gen_server).

-import(esockd_listener_sup, [conn_rate_limiter/1, conn_limiter_opts/2, conn_limiter_opt/2]).

-export([ server/3
        , count_peers/1
        , stop/1
        ]).

%% get/set
-export([ get_options/2
        , get_acceptors/1
        , get_max_connections/1
        , get_max_conn_rate/3
        , get_current_connections/1
        , get_shutdown_count/1
        ]).

-export([ set_options/3
        , set_max_connections/3
        , set_max_conn_rate/3
        ]).

-export([ get_access_rules/1
        , allow/2
        , deny/2
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-export([proxy_request/1]).

%%-type(maybe(T) :: undefined | T).

-record(state, {
          proto        :: atom(),
          sock         :: inet:socket(),
          port         :: inet:port_number(),
          rate_limit   :: esockd_rate_limit:bucket() | undefined,
          conn_limiter :: esockd_generic_limiter:limiter(),
          limit_timer  :: reference() | undefined,
          max_peers    :: infinity | pos_integer(),
          peers        :: map(),
          options      :: [esockd:option()],
          access_rules :: list(),
          mfa          :: esockd:mfargs(),
          health_check_request :: binary() | undefined,
          health_check_reply :: binary() | undefined
         }).

-define(ACTIVE_N, 100).
-define(ENABLED(X), (X =/= undefined)).
-define(DEFAULT_OPTS, [binary, {reuseaddr, true}]).
-define(ERROR_MSG(Format, Args),
        error_logger:error_msg("[~s]: " ++ Format, [?MODULE | Args])).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

-spec(server(atom(), esockd:listen_on(), [esockd:option()])
      -> {ok, pid()} | {error, term()}).
server(Proto, ListenOn, Opts) ->
    gen_server:start_link(?MODULE, [Proto, ListenOn, Opts], []).

resolve_addr(Port, SockOpts) when is_integer(Port) ->
    SockOpts;
resolve_addr({Addr, _Port}, SockOpts) ->
    IfAddr = case proplists:get_value(ip, SockOpts) of
                 undefined -> proplists:get_value(ifaddr, SockOpts);
                 Addr      -> Addr
             end,
    case (IfAddr =:= undefined) orelse (IfAddr =:= Addr) of
        true -> ok;
        _ -> error({badarg, inconsistent_addr})
    end,
    lists:keystore(ip, 1, SockOpts, {ip, Addr}).

-spec(count_peers(pid()) -> integer()).
count_peers(Pid) ->
    gen_server:call(Pid, count_peers).

-spec(stop(pid()) -> ok).
stop(Pid) -> gen_server:stop(Pid).

proxy_request(Fun) ->
    Parent = gen:get_parent(),
    gen_server:call(Parent, {?FUNCTION_NAME, Fun}, infinity).

%%--------------------------------------------------------------------
%% GET/SET APIs
%%--------------------------------------------------------------------

get_options(_ListenerRef, Pid) ->
    gen_server:call(Pid, options).

get_acceptors(_Pid) ->
    1.

get_max_connections(Pid) ->
    gen_server:call(Pid, max_peers).

get_max_conn_rate(_Pid, Proto, ListenOn) ->
    case esockd_limiter:lookup({listener, Proto, ListenOn}) of
        undefined ->
            {error, not_found};
        #{capacity := Capacity, interval := Interval} ->
            {Capacity, Interval}
    end.

get_current_connections(Pid) ->
    gen_server:call(Pid, count_peers).

get_shutdown_count(_Pid) ->
    [].

set_options(_ListenerRef, _Pid, _Opts) ->
    {error, not_supported}.

set_max_connections(_ListenerRef, Pid, MaxLimit) when is_integer(MaxLimit) ->
    gen_server:call(Pid, {max_peers, MaxLimit}).

set_max_conn_rate(_ListenerRef = {Proto, ListenOn}, Pid, Opts) ->
    gen_server:call(Pid, {max_conn_rate, Proto, ListenOn, Opts}).

get_access_rules(Pid) ->
    gen_server:call(Pid, access_rules).

allow(Pid, CIDR) ->
    gen_server:call(Pid, {add_rule, {allow, CIDR}}).

deny(Pid, CIDR) ->
    gen_server:call(Pid, {add_rule, {deny, CIDR}}).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([Proto, ListenOn, Opts]) ->
    process_flag(trap_exit, true),
    put(incoming_peers, 0),

    MFA = proplists:get_value(connection_mfargs, Opts),
    RawRules = proplists:get_value(access_rules, Opts, [{allow, all}]),
    AccessRules = [esockd_access:compile(Rule) || Rule <- RawRules],

    Port = port(ListenOn),
    UdpOpts = resolve_addr(ListenOn, sockopts(Opts)),
    case gen_udp:open(Port, esockd:merge_opts(?DEFAULT_OPTS, UdpOpts)) of
        {ok, Sock} ->
            %% Trigger the udp_passive event
            ok = inet:setopts(Sock, [{active, 1}]),
            Limiter = conn_rate_limiter(conn_limiter_opts(Opts, {listener, Proto, ListenOn})),
            MaxPeers = proplists:get_value(max_connections, Opts, infinity),
            init_health_check(#state{proto = Proto,
                                     sock = Sock,
                                     port = Port,
                                     max_peers = MaxPeers,
                                     peers = #{},
                                     access_rules = AccessRules,
                                     conn_limiter = Limiter,
                                     options = Opts,
                                     mfa = MFA},
                              Opts);
        {error, Reason} ->
            {stop, Reason}
    end.

port(Port) when is_integer(Port) -> Port;
port({_Addr, Port}) -> Port.

sockopts(Opts) ->
    esockd:merge_opts(
      ?DEFAULT_OPTS,
      proplists:get_value(udp_options, Opts, [])
     ).

handle_call(count_peers, _From, State = #state{peers = Peers}) ->
    {reply, maps:size(Peers) div 2, State};

handle_call(max_peers, _From, State = #state{max_peers = MaxLimit}) ->
    {reply, MaxLimit, State};

handle_call({max_peers, MaxLimit}, _From, State) ->
    {reply, ok, State#state{max_peers = MaxLimit}};

handle_call({max_conn_rate, Proto, ListenOn, Opts}, _From, State) ->
    Limiter = conn_rate_limiter(conn_limiter_opt(Opts, {listener, Proto, ListenOn})),
    {reply, ok, State#state{conn_limiter = Limiter}};

handle_call(options, _From, State = #state{options = Opts}) ->
    {reply, Opts, State};

handle_call(access_rules, _From, State = #state{access_rules = Rules}) ->
    {reply, [raw(Rule) || Rule <- Rules], State};

handle_call({add_rule, RawRule}, _From, State = #state{access_rules = Rules}) ->
    try esockd_access:compile(RawRule) of
        Rule ->
            case lists:member(Rule, Rules) of
                true ->
                    {reply, {error, already_exists}, State};
                false ->
                    {reply, ok, State#state{access_rules = [Rule | Rules]}}
            end
    catch
        error:Reason ->
            ?ERROR_MSG("Bad access rule: ~p, compile errro: ~p", [RawRule, Reason]),
            {reply, {error, bad_access_rule}, State}
    end;

%% mimic the supervisor's which_children reply
handle_call(which_children, _From, State = #state{peers = Peers, mfa = {Mod, _Func, _Args}}) ->
     {reply, [{undefined, Pid, worker, [Mod]}
              || Pid <- maps:keys(Peers), is_pid(Pid), erlang:is_process_alive(Pid)], State};

handle_call({proxy_request, Fun}, _From, State) ->
    Result = Fun(),
    {reply, Result, State};

handle_call(Req, _From, State) ->
    ?ERROR_MSG("Unexpected call: ~p", [Req]),
    {reply, ignore, State}.

handle_cast(Msg, State) ->
    ?ERROR_MSG("Unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({udp, Sock, IP, Port, Request},
            State = #state{sock = Sock,
                           health_check_request = Request,
                           health_check_reply = Reply}) ->
    case gen_udp:send(Sock, IP, Port, Reply) of
        ok -> ok;
        {error, Reason} ->
            ?ERROR_MSG("Health check response to: ~s failed, reason: ~s",
                       [esockd:format({IP, Port}), Reason])
    end,
    {noreply, State};
handle_info({udp, Sock, IP, InPortNo, Packet},
            State = #state{sock = Sock, peers = Peers, access_rules = Rules}) ->
    case maps:find(Peer = {IP, InPortNo}, Peers) of
        {ok, Pid} ->
            Pid ! {datagram, self(), Packet},
            {noreply, State};
        error ->
            case allowed(IP, Rules) of
                true ->
                    put(incoming_peers, get(incoming_peers) + 1),
                    try should_throttle(State) orelse
                        start_channel({udp, self(), Sock}, Peer, State) of
                        true ->
                            ?ERROR_MSG("Cannot create udp channel for peer ~s due to throttling.",
                                       [esockd:format(Peer)]),
                            {noreply, State};
                        {ok, Pid} ->
                            true = erlang:link(Pid),
                            Pid ! {datagram, self(), Packet},
                            {noreply, store_peer(Peer, Pid, State)};
                        {error, Reason} ->
                            ?ERROR_MSG("Failed to start udp channel for peer ~s, reason: ~p",
                                       [esockd:format(Peer), Reason]),
                            {noreply, State}
                    catch
                        _Error:Reason ->
                            ?ERROR_MSG("Exception occurred when starting udp channel for peer ~s, reason: ~p",
                                       [esockd:format(Peer), Reason]),
                            {noreply, State}
                    end;
                false ->
                    {noreply, State}
            end
    end;

handle_info({udp_passive, Sock}, State = #state{sock = Sock, rate_limit = Rl}) ->
    NState = case ?ENABLED(Rl) andalso
                  esockd_rate_limit:check(put(incoming_peers, 0), Rl) of
                 false ->
                     activate_sock(State);
                 {0, Rl1} ->
                     activate_sock(State#state{rate_limit = Rl1});
                 {Pause, Rl1} ->
                     ?ERROR_MSG("Pause ~w(ms) due to rate limit.", [Pause]),
                     TRef = erlang:start_timer(Pause, self(), activate_sock),
                     State#state{rate_limit = Rl1, limit_timer = TRef}
             end,
    {noreply, NState, hibernate};

handle_info({udp_error, Sock, Reason}, State = #state{sock = Sock}) ->
  {stop, {udp_error, Reason}, State};
handle_info({udp_closed, Sock}, State = #state{sock = Sock}) ->
  {stop, udp_closed, State};

handle_info({timeout, TRef, activate_sock}, State = #state{limit_timer = TRef}) ->
    NState = State#state{limit_timer = undefined},
    {noreply, activate_sock(NState)};

handle_info({'DOWN', _MRef, process, DownPid, _Reason}, State = #state{peers = Peers}) ->
    handle_peer_down(DownPid, Peers, State);

handle_info({'EXIT', DownPid, _Reason}, State = #state{peers = Peers}) ->
    handle_peer_down(DownPid, Peers, State);

handle_info({datagram, Peer = {IP, Port}, Packet}, State = #state{sock = Sock}) ->
    case gen_udp:send(Sock, IP, Port, Packet) of
        ok -> ok;
        {error, Reason} ->
            ?ERROR_MSG("Dropped packet to: ~s, reason: ~s", [esockd:format(Peer), Reason])
    end,
    {noreply, State};
handle_info(Info, State) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{sock = Sock}) ->
    gen_udp:close(Sock).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internel functions
%%--------------------------------------------------------------------

handle_peer_down(DownPid, Peers, State) ->
    case maps:find(DownPid, Peers) of
        {ok, Peer} ->
            {noreply, erase_peer(Peer, DownPid, State)};
        error ->
            {noreply, State}
    end.

-compile({inline,
          [ allowed/2
          , should_throttle/1
          , start_channel/3
          , activate_sock/1
          , store_peer/3
          , erase_peer/3
          , raw/1
          ]}).

allowed(Addr, Rules) ->
    case esockd_access:match(Addr, Rules) of
        nomatch          -> true;
        {matched, allow} -> true;
        {matched, deny}  -> false
    end.

should_throttle(#state{max_peers = infinity}) -> false;
should_throttle(#state{max_peers = MaxLimit, peers = Peers}) ->
    (maps:size(Peers) div 2) > MaxLimit.

start_channel(Transport, Peer, #state{mfa = MFA}) ->
    esockd:start_mfargs(MFA, Transport, Peer).

activate_sock(State = #state{sock = Sock}) ->
    ok = inet:setopts(Sock, [{active, ?ACTIVE_N}]), State.

store_peer(Peer, Pid, State = #state{peers = Peers}) ->
    State#state{peers = maps:put(Pid, Peer, maps:put(Peer, Pid, Peers))}.

erase_peer(Peer, Pid, State = #state{peers = Peers}) ->
    State#state{peers = maps:remove(Peer, maps:remove(Pid, Peers))}.

raw({allow, CIDR = {_Start, _End, _Len}}) ->
     {allow, esockd_cidr:to_string(CIDR)};
raw({deny, CIDR = {_Start, _End, _Len}}) ->
     {deny, esockd_cidr:to_string(CIDR)};
raw(Rule) ->
     Rule.

init_health_check(State, Opts) ->
    case proplists:get_value(health_check, Opts) of
        #{request := Request, reply := Reply} when is_binary(Request), is_binary(Reply) ->
            {ok, State#state{health_check_request = Request, health_check_reply = Reply}};
        undefined ->
            {ok, State};
        Any ->
            {error, {invalid_health_check_data, Any}}
    end.
