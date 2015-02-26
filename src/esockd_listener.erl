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

-behaviour(gen_server).

-export([start_link/4]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {sock, protocol}).

-define(DEFAULT_ACCEPTOR_NUM , 10).

%%
%% @doc start listener
%%
-spec start_link(Protocol       :: atom(),
                 Port           :: inet:port_number(),
                 Options		:: list(esockd:option()),
                 AcceptorSup    :: pid()) -> {ok, pid()}.
start_link(Protocol, Port, Options, AcceptorSup) ->
    gen_server:start_link({local, name({Protocol, Port})},
        ?MODULE, {Protocol, Port, Options, AcceptorSup}, []).

%%--------------------------------------------------------------------
init({Protocol, Port, Options, AcceptorSup}) ->
    process_flag(trap_exit, true),
    %%don't active the socket...
	SocketOpts = esockd_option:sockopts(Options),
    case esockd_transport:listen(Port, [{active, false} | proplists:delete(active, SocketOpts)]) of
        {ok, LSock} ->
			AcceptorNum = esockd_option:getopt(acceptor_pool, Options, ?DEFAULT_ACCEPTOR_NUM),
			lists:foreach(fun (_) ->
				{ok, _APid} = supervisor:start_child(AcceptorSup, [LSock])
			end, lists:seq(1, AcceptorNum)),
            {ok, {LIPAddress, LPort}} = inet:sockname(LSock),
            lager:info("listen on ~s:~p with ~p acceptors.~n", [esockd_net:ntoab(LIPAddress), LPort, AcceptorNum]),
            {ok, #state{sock = LSock, protocol = Protocol}};
        {error, Reason} ->
            lager:info("failed to listen on ~p - ~p (~s)~n",
				[Port, Reason, inet:format_error(Reason)]),
            {stop, {cannot_listen, Port, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{sock=LSock, protocol=Protocol}) ->
    {ok, {IPAddress, Port}} = inet:sockname(LSock),
    esockd_transport:close(LSock),
    %%error report
    lager:info("stopped ~s on ~s:~p~n",
           [Protocol, esockd_net:ntoab(IPAddress), Port]),
	ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%% Internal functions
%%%=============================================================================
name({Protocol, Port}) ->
    list_to_atom(lists:concat([listener, ':', Protocol, ':', Port])).