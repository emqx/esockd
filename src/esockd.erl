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
%%% esockd main api.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(esockd).

-author("feng@emqtt.io").

-include("esockd.hrl").

%% Start Application.
-export([start/0]).

%% Core API
-export([open/4, close/2, close/1]).

%% Management API
-export([listeners/0, listener/1,
         get_stats/1,
         get_acceptor_pool/1,
         get_max_clients/1,
         set_max_clients/2,
         get_current_clients/1]).

%% Utility functions...
-export([sockopts/1, ulimit/0]).

-type ssl_socket() :: #ssl_socket{}.

-type sock_fun() :: fun((inet:socket()) -> {ok, inet:socket() | ssl_socket()} | {error, any()}).

-type sock_args()  :: {atom(), inet:socket(), sock_fun()}.

-type mfargs() :: {module(), atom(), [term()]}.

-type callback() :: atom() | {atom(), atom()} | mfargs().

-type option() ::
		{acceptor_pool, pos_integer()} |
		{max_clients, pos_integer()} | 
        {logger, atom() | {atom(), atom()}} |
        {ssl, [ssl:ssloption()]} |
        gen_tcp:listen_option().

-export_type([ssl_socket/0, sock_fun/0, sock_args/0, callback/0, option/0]).

%%------------------------------------------------------------------------------
%% @doc
%% Start esockd application.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:start(esockd).

%%------------------------------------------------------------------------------
%% @doc
%% Open a listener.
%%
%% @end
%%------------------------------------------------------------------------------
-spec open(Protocol, Port, Options, Callback) -> {ok, pid()} | {error, any()} when
    Protocol     :: atom(),
    Port         :: inet:port_number(),
    Options		 :: [option()], 
    Callback     :: callback().
open(Protocol, Port, Options, Callback)  ->
	esockd_sup:start_listener(Protocol, Port, Options, Callback).

%%------------------------------------------------------------------------------
%% @doc
%% Close the listener.
%%
%% @end
%%------------------------------------------------------------------------------
-spec close({Protocol, Port}) -> ok when
    Protocol    :: atom(),
    Port        :: inet:port_number().
close({Protocol, Port}) when is_atom(Protocol) and is_integer(Port) ->
    close(Protocol, Port).

-spec close(Protocol, Port) -> ok when 
    Protocol    :: atom(),
    Port        :: inet:port_number().
close(Protocol, Port) when is_atom(Protocol) and is_integer(Port) ->
	esockd_sup:stop_listener(Protocol, Port).

%%------------------------------------------------------------------------------
%% @doc
%% Get listeners.
%%
%% @end
%%------------------------------------------------------------------------------
listeners() ->
    esockd_sup:listeners().

%%------------------------------------------------------------------------------
%% @doc
%% Get one listener.
%%
%% @end
%%------------------------------------------------------------------------------
listener({Protocol, Port}) ->
    esockd_sup:listener({Protocol, Port}).

%%------------------------------------------------------------------------------
%% @doc
%% Get stats.
%%
%% @end
%%------------------------------------------------------------------------------
-spec get_stats({atom(), inet:port_number()}) -> [{atom(), non_neg_integer()}].
get_stats({Protocol, Port}) ->
    esockd_server:get_stats({Protocol, Port}).

%%------------------------------------------------------------------------------
%% @doc
%% Get acceptor_pool size.
%%
%% @end
%%------------------------------------------------------------------------------
-spec get_acceptor_pool({atom(), inet:port_number()}) -> undefined | pos_integer().
get_acceptor_pool({Protocol, Port}) ->
    LSup = listener({Protocol, Port}),
    get_acceptor_pool(LSup); 
get_acceptor_pool(undefined) ->
    undefined;
get_acceptor_pool(LSup) when is_pid(LSup) ->
    AcceptorSup = esockd_listener_sup:acceptor_sup(LSup),
    esockd_acceptor_sup:count_acceptors(AcceptorSup).

%%------------------------------------------------------------------------------
%% @doc
%% Get max clients.
%%
%% @end
%%------------------------------------------------------------------------------
-spec get_max_clients({atom(), inet:port_number()}) -> undefined | pos_integer().
get_max_clients({Protocol, Port}) ->
    LSup = listener({Protocol, Port}),
    get_max_clients(LSup);
get_max_clients(undefined) ->
    undefined;
get_max_clients(LSup) when is_pid(LSup) ->
    Manager = esockd_listener_sup:manager(LSup),
    esockd_manager:get_max_clients(Manager).

%%------------------------------------------------------------------------------
%% @doc
%% Set max clients.
%%
%% @end
%%------------------------------------------------------------------------------
-spec set_max_clients({atom(), inet:port_number()}, pos_integer()) -> undefined | pos_integer().
set_max_clients({Protocol, Port}, MaxClients) ->
    LSup = listener({Protocol, Port}),
    set_max_clients(LSup, MaxClients);
set_max_clients(undefined, _MaxClients) ->
    undefined;
set_max_clients(LSup, MaxClients) when is_pid(LSup) ->
    Manager = esockd_listener_sup:manager(LSup),
    esockd_manager:set_max_clients(Manager, MaxClients).

%%------------------------------------------------------------------------------
%% @doc
%% Get current clients.
%%
%% @end
%%------------------------------------------------------------------------------
-spec get_current_clients({atom(), inet:port_number()}) -> undefined | pos_integer().
get_current_clients({Protocol, Port}) ->
    LSup = listener({Protocol, Port}),
    get_current_clients(LSup);
get_current_clients(undefined) ->
    undefined;
get_current_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:count_connection(ConnSup).

%%------------------------------------------------------------------------------
%% @doc
%% Filter socket options.
%%
%% @end
%%------------------------------------------------------------------------------
sockopts(Opts) ->
	sockopts(Opts, []).
sockopts([], Acc) ->
	Acc;
sockopts([{max_clients, _}|Opts], Acc) ->
	sockopts(Opts, Acc);
sockopts([{acceptor_pool, _}|Opts], Acc) ->
	sockopts(Opts, Acc);
sockopts([{ssl, _}|Opts], Acc) ->
    sockopts(Opts, Acc);
sockopts([Opt|Opts], Acc) ->
	sockopts(Opts, [Opt|Acc]).

%%------------------------------------------------------------------------------
%% @doc
%% System `ulimit -n`
%% 
%%------------------------------------------------------------------------------
-spec ulimit() -> pos_integer().
ulimit() ->
    proplists:get_value(max_fds, erlang:system_info(check_io)).

