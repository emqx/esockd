%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2017 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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
%%% eSockd Listener.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_listener).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-behaviour(gen_server).

-export([start_link/5, options/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {protocol  :: atom(),
                listen_on :: esockd:listen_on(),
                options   :: [esockd:option()],
                lsock     :: inet:socket(),
                logger    :: gen_logger:logmod()}).

-define(ACCEPTOR_POOL, 16).

%% @doc Start Listener
-spec(start_link(Protocol, ListenOn, Options, AcceptorSup, Logger) -> {ok, pid()} | {error, any()} | ignore when 
    Protocol    :: atom(),
    ListenOn    :: esockd:listen_on(),
    Options	    :: [esockd:option()],
    AcceptorSup :: pid(),
    Logger      :: gen_logger:logmod()).
start_link(Protocol, ListenOn, Options, AcceptorSup, Logger) ->
    gen_server:start_link(?MODULE, {Protocol, ListenOn, Options, AcceptorSup, Logger}, []).

-spec(options(pid()) -> [esockd:option()]).
options(Listener) ->
    gen_server:call(Listener, options).

%%------------------------------------------------------------------------------
%% gen_server Callbacks
%%------------------------------------------------------------------------------

init({Protocol, ListenOn, Options, AcceptorSup, Logger}) ->
    Port = port(ListenOn),
    process_flag(trap_exit, true),
    %%Don't active the socket...
    SockOpts = merge_addr(ListenOn, proplists:get_value(sockopts, Options, [{reuseaddr, true}])),
    case esockd_transport:listen(Port, [{active, false} | proplists:delete(active, SockOpts)]) of
        {ok, LSock} ->
            SockFun = esockd_transport:ssl_upgrade_fun(proplists:get_value(sslopts, Options)),
			AcceptorNum = proplists:get_value(acceptors, Options, ?ACCEPTOR_POOL),
			lists:foreach(fun (_) ->
				{ok, _APid} = esockd_acceptor_sup:start_acceptor(AcceptorSup, LSock, SockFun)
			end, lists:seq(1, AcceptorNum)),
            {ok, {LIPAddress, LPort}} = inet:sockname(LSock),
            io:format("~s listen on ~s:~p with ~p acceptors.~n",
                      [Protocol, esockd_net:ntoab(LIPAddress), LPort, AcceptorNum]),
            {ok, #state{protocol = Protocol, listen_on = ListenOn, options = Options,
                        lsock = LSock, logger = Logger}};
        {error, Reason} ->
            Logger:error("~s failed to listen on ~p - ~p (~s)~n",
                         [Protocol, Port, Reason, inet:format_error(Reason)]),
            {stop, {cannot_listen, Port, Reason}}
    end.

port(Port) when is_integer(Port) -> Port;
port({_Addr, Port}) -> Port.

merge_addr(Port, SockOpts) when is_integer(Port) ->
    SockOpts;
merge_addr({Addr, _Port}, SockOpts) ->
    lists:keystore(ip, 1, SockOpts, {ip, Addr}).

handle_call(options, _From, State = #state{options = Options}) ->
    {reply, Options, State};

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

