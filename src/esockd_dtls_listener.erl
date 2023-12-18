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

-module(esockd_dtls_listener).

-behaviour(gen_server).

-include("esockd.hrl").

-export([ start_link/3
        , start_supervised/1
        ]).

-export([ options/1
        , get_port/1
        , get_state/1
        , set_options/2
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-record(state, {
          proto     :: atom(),
          listen_on :: esockd:listen_on(),
          lsock     :: ssl:sslsocket(),
          laddr     :: inet:ip_address(),
          lport     :: inet:port_number()
         }).

-type option() :: {dtls_options, [gen_tcp:option()]}.

-define(DEFAULT_DTLS_OPTIONS,
        [{protocol, dtls},
         {mode, binary},
         {reuseaddr, true}]).

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

-spec(options(pid()) -> [esockd:option()]).
options(Listener) ->
    gen_server:call(Listener, options).

-spec(get_port(pid()) -> inet:port_number()).
get_port(Listener) ->
    gen_server:call(Listener, get_port).

-spec get_state(pid())  -> proplists:proplist().
get_state(Listener) ->
    gen_server:call(Listener, get_state).

-spec set_options(pid(), [option()])  -> ok.
set_options(Listener, Opts) ->
    gen_server:call(Listener, {set_options, Opts}).
    
%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init({Proto, ListenOn, Opts}) ->
    Port = port(ListenOn),
    process_flag(trap_exit, true),
    esockd_server:ensure_stats({Proto, ListenOn}),
    SockOpts = merge_addr(ListenOn, dltsopts(Opts)),
    %% Don't active the socket...
    case ssl:listen(Port, esockd:merge_opts(?DEFAULT_DTLS_OPTIONS, SockOpts)) of
    %%case ssl:listen(Port, [{active, false} | proplists:delete(active, SockOpts)]) of
        {ok, LSock} ->
            {ok, {LAddr, LPort}} = ssl:sockname(LSock),
            %%error_logger:info_msg("~s listen on ~s:~p with ~p acceptors.~n",
            %%                      [Proto, inet:ntoa(LAddr), LPort, AcceptorNum]),
            {ok, #state{proto = Proto, listen_on = ListenOn,
                        lsock = LSock, laddr = LAddr, lport = LPort}};
        {error, Reason} ->
            error_logger:error_msg("~s failed to listen on ~p - ~p (~s)",
                                   [Proto, Port, Reason, inet:format_error(Reason)]),
            {stop, Reason}
    end.

dltsopts(Opts) ->
    %% Filter out `esockd:ssl_custom_option()`, otherwise DTLS listener will
    %% fail to start.
    DTLSOpts = lists:foldl(
        fun proplists:delete/2,
        proplists:get_value(dtls_options, Opts, []),
        [handshake_timeout, gc_after_handshake]
    ),
    SockOpts = proplists:get_value(udp_options, Opts, []),
    SockOpts ++ DTLSOpts.

port(Port) when is_integer(Port) -> Port;
port({_Addr, Port}) -> Port.

merge_addr(Port, SockOpts) when is_integer(Port) ->
    SockOpts;
merge_addr({Addr, _Port}, SockOpts) ->
    lists:keystore(ip, 1, SockOpts, {ip, Addr}).

handle_call(get_port, _From, State = #state{lport = LPort}) ->
    {reply, LPort, State};

handle_call(get_state, _From, State = #state{lsock = LSock, lport = LPort}) ->
    Reply = [ {listen_sock, LSock}
            , {listen_port, LPort}
            ],
    {reply, Reply, State};

handle_call({set_options, Opts}, _From, State = #state{lsock = LSock}) ->
    case ssl:setopts(LSock, dltsopts(Opts)) of
        ok ->
            {reply, ok, State};
        Error = {error, _} ->
            %% Setting dTLS options on listening socket always succeeds,
            %% even if the options are invalid.
            {reply, Error, State}
    end;

handle_call(Req, _From, State) ->
    error_logger:error_msg("[~s] Unexpected call: ~p", [?MODULE, Req]),
    {noreply, State}.

handle_cast(Msg, State) ->
    error_logger:error_msg("[~s] Unexpected cast: ~p", [?MODULE, Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    error_logger:error_msg("[~s] Unexpected info: ~p", [?MODULE, Info]),
    {noreply, State}.

terminate(_Reason, #state{proto = Proto, listen_on = ListenOn,
                          lsock = LSock, laddr = Addr, lport = Port}) ->
    error_logger:info_msg("~s stopped on ~s~n", [Proto, esockd:format({Addr, Port})]),
    esockd_limiter:delete({listener, Proto, ListenOn}),
    esockd_server:del_stats({Proto, ListenOn}),
    esockd_transport:fast_close(LSock).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

