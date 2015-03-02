%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2014-2015, Feng Lee <feng@emqtt.io>
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

-author('feng@emqtt.io').

-include("esockd.hrl").

-behaviour(gen_server).

-export([start_link/4]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {protocol  :: atom(),
                lsock     :: inet:socket()}).

-define(ACCEPTOR_POOL, 10).

%%------------------------------------------------------------------------------
%% @doc 
%% Start Listener
%%
%% @end
%%------------------------------------------------------------------------------
-spec start_link(Protocol, Port, Options, AcceptorSup) -> {ok, pid()} | {error, any()} | ignore when 
    Protocol    :: atom(),
    Port        :: inet:port_number(),
    Options	    :: [esockd:option()],
    AcceptorSup :: pid().
start_link(Protocol, Port, Options, AcceptorSup) ->
    gen_server:start_link(?MODULE, {Protocol, Port, Options, AcceptorSup}, []).

init({Protocol, Port, Options, AcceptorSup}) ->
    process_flag(trap_exit, true),
    %%don't active the socket...
	SockOpts = esockd:sockopts(Options),
    case esockd_transport:listen(Port, [{active, false} | proplists:delete(active, SockOpts)]) of
        {ok, LSock} ->
            SockFun = esockd_transport:ssl_upgrade_fun(proplists:get_value(ssl, Options)),
			AcceptorNum = proplists:get_value(acceptor_pool, Options, ?ACCEPTOR_POOL),
			lists:foreach(fun (_) ->
				{ok, _APid} = supervisor:start_child(AcceptorSup, [LSock, SockFun])
			end, lists:seq(1, AcceptorNum)),
            {ok, {LIPAddress, LPort}} = inet:sockname(LSock),
            error_logger:info_msg("~s listen on ~s:~p with ~p acceptors.", 
                                  [Protocol, esockd_net:ntoab(LIPAddress), LPort, AcceptorNum]),
            {ok, #state{protocol = Protocol, lsock = LSock}};
        {error, Reason} ->
            error_logger:info_msg("~s failed to listen on ~p - ~p (~s)~n",
				[Protocol, Port, Reason, inet:format_error(Reason)]),
            {stop, {cannot_listen, Port, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{lsock=LSock, protocol=Protocol}) ->
    {ok, {IPAddress, Port}} = esockd_transport:sockname(LSock),
    esockd_transport:close(LSock),
    %%error report
    error_logger:info_msg("stopped ~s on ~s:~p~n",
           [Protocol, esockd_net:ntoab(IPAddress), Port]),
	ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================


