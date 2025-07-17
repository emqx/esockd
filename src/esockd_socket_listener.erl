%%--------------------------------------------------------------------
%% Copyright (c) 2025 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_socket_listener).

-behaviour(gen_server).

-include("esockd.hrl").

-define(DEFAULT_DOMAIN, inet).

-export([ start_link/3
        , start_supervised/1
        ]).

-export([ get_port/1
        , get_lsock/1
        , get_state/1
        , set_options/2
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        ]).

-record(state, {
          listener_ref :: esockd:listener_ref(),
          lsock        :: socket:socket(),
          laddr        :: inet:ip_address(),
          lport        :: inet:port_number(),
          sockopts     :: [socket:socket_option()]
         }).

-define(DEFAULT_SOCK_OPTIONS, [{reuseaddr, true}]).

-type option() :: {tcp_options, [{reuseaddr, boolean()}]}.

-spec start_link(atom(), esockd:listen_on(), [esockd:option()])
      -> {ok, pid()} | ignore | {error, term()}.
start_link(Proto, ListenOn, Opts) ->
    gen_server:start_link(?MODULE, {Proto, ListenOn, Opts}, []).

-spec start_supervised(esockd:listener_ref())
      -> {ok, pid()} | ignore | {error, term()}.
start_supervised(ListenerRef = {Proto, ListenOn}) ->
    Opts = esockd_server:get_listener_prop(ListenerRef, options),
    case start_link(Proto, ListenOn, Opts) of
        {ok, Pid} ->
            _ = esockd_server:set_listener_prop(ListenerRef, listener, {?MODULE, Pid}),
            {ok, Pid};
        Error ->
            Error
    end.

-spec get_port(pid()) -> inet:port_number().
get_port(Listener) ->
    gen_server:call(Listener, get_port).

-spec get_lsock(pid())  -> inet:socket().
get_lsock(Listener) ->
    gen_server:call(Listener, get_lsock).

-spec get_state(pid())  -> proplists:proplist().
get_state(Listener) ->
    gen_server:call(Listener, get_state).

-spec set_options(pid(), [option()])  -> ok.
set_options(_Listener, _Opts) ->
    ok.

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init({Proto, ListenOn, Opts}) ->
    process_flag(trap_exit, true),
    ListenerRef = {Proto, ListenOn},
    Port = port(ListenOn),
    esockd_server:ensure_stats(ListenerRef),
    TcpOpts = merge_defaults(proplists:get_value(tcp_options, Opts, [])),
    case listen(ListenOn, TcpOpts) of
        {ok, LSock, SockOpts} ->
            _MRef = socket:monitor(LSock),
            case esockd_socket:sockname(LSock) of
                {ok, {LAddr, LPort}} ->
                    {ok, #state{listener_ref = ListenerRef, lsock = LSock,
                                laddr = LAddr, lport = LPort, sockopts = SockOpts}};
                {error, Reason} ->
                    error_logger:error_msg("~s failed to get sockname: ~p (~s)",
                                           [Proto, Reason, inet:format_error(Reason)]),
                    {stop, Reason}
            end;
        {error, Reason = {invalid, What}} ->
            error_logger:error_msg("~s failed to listen on ~p - invalid option: ~0p",
                                   [Proto, Port, What]),
            {stop, Reason};
        {error, Reason} ->
            error_logger:error_msg("~s failed to listen on ~p - ~p (~s)",
                                   [Proto, Port, Reason, inet:format_error(Reason)]),
            {stop, Reason}
    end.

listen(ListenOn, TcpOpts) ->
    SockAddr = sock_addr(ListenOn),
    SockDomain = case [O || O <- TcpOpts, O == inet orelse O == inet6] of
        [_ | _] = Families -> lists:last(Families);
        [] -> maps:get(family, SockAddr, ?DEFAULT_DOMAIN)
    end,
    SockOpts = lists:flatten([sock_listen_opt(O) || O <- TcpOpts]),
    Backlog = proplists:get_value(backlog, TcpOpts, 128),
    try
        LSock = ensure(socket:open(SockDomain, stream, tcp)),
        ok = ensure(esockd_socket:setopts(LSock, SockOpts)),
        ok = ensure(socket:bind(LSock, SockAddr#{family => SockDomain})),
        ok = ensure(socket:listen(LSock, Backlog)),
        {ok, LSock, SockOpts}
    catch
        Error -> Error
    end.

sock_addr(0) ->
    #{addr => any, port => 0};
sock_addr(Port) when is_integer(Port) ->
    #{addr => any, port => Port};
sock_addr({Host, Port}) when tuple_size(Host) =:= 4 ->
    #{family => inet, addr => Host, port => Port};
sock_addr({Host, Port}) when tuple_size(Host) =:= 8 ->
    #{family => inet6, addr => Host, port => Port}.

sock_listen_opt({reuseaddr, Flag}) ->
    {{socket, reuseaddr}, Flag};
sock_listen_opt(_) ->
    [].

merge_defaults(SockOpts) ->
    esockd:merge_opts(?DEFAULT_SOCK_OPTIONS, SockOpts).

ensure(ok) -> ok;
ensure({ok, Result}) -> Result;
ensure(Error) -> throw(Error).

port(Port) when is_integer(Port) ->
    Port;
port({_Addr, Port}) ->
    Port.

handle_call(get_port, _From, State = #state{lport = LPort}) ->
    {reply, LPort, State};

handle_call(get_lsock, _From, State = #state{lsock = LSock}) ->
    {reply, LSock, State};

handle_call(get_state, _From, State = #state{lsock = LSock, lport = LPort}) ->
    Reply = [ {listen_sock, LSock}
            , {listen_port, LPort}
            ],
    {reply, Reply, State};

handle_call(Req, _From, State) ->
    error_logger:error_msg("[~s] Unexpected call: ~p", [?MODULE, Req]),
    {noreply, State}.

handle_cast(Msg, State) ->
    error_logger:error_msg("[~s] Unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.

handle_info({'DOWN', _MRef, socket, LSock, Info}, #state{lsock = LSock} = State) ->
    error_logger:error_msg("[~s] Socket ~p closed: ~p", [?MODULE, LSock, Info]),
    {stop, Info, State};
handle_info(Info, State) ->
    error_logger:error_msg("[~s] Unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.

terminate(_Reason, #state{listener_ref = ListenerRef = {Proto, ListenOn},
                          lsock = LSock, laddr = Addr, lport = Port}) ->
    error_logger:info_msg("~s stopped on ~s~n", [Proto, esockd:format({Addr, Port})]),
    esockd_limiter:delete({listener, Proto, ListenOn}),
    esockd_server:del_stats(ListenerRef),
    esockd_socket:fast_close(LSock).
