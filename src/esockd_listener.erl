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

-module(esockd_listener).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-behaviour(gen_server).

-export([start_link/4, options/1, get_port/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {protocol  :: atom(),
                listen_on :: esockd:listen_on(),
                options   :: [esockd:option()],
                lsock     :: inet:socket(),
                laddress  :: inet:ip_address(),
                lport     :: inet:port_number()}).

-define(ACCEPTOR_POOL, 16).

-define(DEFAULT_SOCKOPTS,
        [{nodelay, true},
         {reuseaddr, true},
         {send_timeout, 30000},
         {send_timeout_close, true}]).

%% @doc Start Listener
-spec(start_link(atom(), esockd:listen_on(), [esockd:option()], pid())
      -> {ok, pid()} | ignore | {error, term()}).
start_link(Protocol, ListenOn, Options, AcceptorSup) ->
    gen_server:start_link(?MODULE, {Protocol, ListenOn, Options, AcceptorSup}, []).

-spec(options(pid()) -> [esockd:option()]).
options(Listener) ->
    gen_server:call(Listener, options).

-spec(get_port(pid()) -> inet:port_number()).
get_port(Listener) ->
    gen_server:call(Listener, get_port).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init({Protocol, ListenOn, Options, AcceptorSup}) ->
    Port = port(ListenOn),
    process_flag(trap_exit, true),
    %% Don't active the socket...
    SockOpts = merge_addr(ListenOn, sockopts(Options)),
    case esockd_transport:listen(Port, [{active, false} | proplists:delete(active, SockOpts)]) of
        {ok, LSock} ->
            SockFun = esockd_transport:ssl_upgrade_fun(proplists:get_value(sslopts, Options)),
			AcceptorNum = proplists:get_value(acceptors, Options, ?ACCEPTOR_POOL),
			lists:foreach(fun (_) ->
				{ok, _APid} = esockd_acceptor_sup:start_acceptor(AcceptorSup, LSock, SockFun)
			end, lists:seq(1, AcceptorNum)),
            {ok, {LAddress, LPort}} = inet:sockname(LSock),
            io:format("~s listen on ~s:~p with ~p acceptors.~n",
                      [Protocol, esockd_net:ntoab(LAddress), LPort, AcceptorNum]),
            {ok, #state{protocol = Protocol, listen_on = ListenOn, options = Options,
                        lsock = LSock, laddress = LAddress, lport = LPort}};
        {error, Reason} ->
            error_logger:error_msg("~s failed to listen on ~p - ~p (~s)",
                                   [Protocol, Port, Reason, inet:format_error(Reason)]),
            {stop, {cannot_listen, Port, Reason}}
    end.

sockopts(Options) ->
    esockd_util:merge_opts(?DEFAULT_SOCKOPTS, proplists:get_value(sockopts, Options, [])).

port(Port) when is_integer(Port) -> Port;
port({_Addr, Port}) -> Port.

merge_addr(Port, SockOpts) when is_integer(Port) ->
    SockOpts;
merge_addr({Addr, _Port}, SockOpts) ->
    lists:keystore(ip, 1, SockOpts, {ip, Addr}).

handle_call(options, _From, State = #state{options = Options}) ->
    {reply, Options, State};

handle_call(get_port, _From, State = #state{lport = LPort}) ->
    {reply, LPort, State};

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{protocol = Protocol, listen_on = ListenOn, lsock = LSock}) ->
    {ok, {IPAddress, Port}} = esockd_transport:sockname(LSock),
    esockd_transport:close(LSock),
    %% Print on console
    io:format("stopped ~s on ~s:~p~n",
              [Protocol, esockd_net:ntoab(IPAddress), Port]),
    %%TODO: depend on esockd_server?
    esockd_server:del_stats({Protocol, ListenOn}),
	ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

