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

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

%% Start Application.
-export([start/0]).

%% Core API
-export([open/4, close/2, close/1]).

%% Management API
-export([listeners/0, listener/1,
         get_stats/1,
         get_acceptors/1,
         get_max_clients/1,
         set_max_clients/2,
         get_current_clients/1]).

%% Allow, Deny API
-export([get_access_rules/1, allow/2, deny/2]).

%% Utility functions...
-export([sockopts/1, ulimit/0]).

-type ssl_socket() :: #ssl_socket{}.

-type tune_fun() :: fun((inet:socket()) -> ok | {error, any()}).

-type sock_fun() :: fun((inet:socket()) -> {ok, inet:socket() | ssl_socket()} | {error, any()}).

-type sock_args()  :: {atom(), inet:socket(), sock_fun()}.

-type mfargs() :: atom() | {atom(), atom()} | {module(), atom(), [term()]}.

-type option() ::
		{acceptors, pos_integer()} |
		{max_clients, pos_integer()} |
        {access, [esockd_access:rule()]} |
        {shutdown, brutal_kill | infinity | pos_integer()} |
        {tune_buffer, false | true} |
        {logger, atom() | {atom(), atom()}} |
        {ssl, [ssl:ssloption()]} |
        gen_tcp:listen_option().

-export_type([ssl_socket/0, sock_fun/0, sock_args/0, tune_fun/0, option/0]).

%%------------------------------------------------------------------------------
%% @doc Start esockd application.
%%------------------------------------------------------------------------------
-spec start() -> ok.
start() ->
    application:start(esockd).

%%------------------------------------------------------------------------------
%% @doc Open a listener.
%%------------------------------------------------------------------------------
-spec open(Protocol, Port, Options, MFArgs) -> {ok, pid()} | {error, any()} when
    Protocol     :: atom(),
    Port         :: inet:port_number(),
    Options		 :: [option()], 
    MFArgs       :: mfargs().
open(Protocol, Port, Options, MFArgs) ->
	esockd_sup:start_listener(Protocol, Port, Options, MFArgs).

%%------------------------------------------------------------------------------
%% @doc Close the listener
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
%% @doc Get listeners
%%------------------------------------------------------------------------------
-spec listeners() -> [{atom(), inet:port_number()}].
listeners() ->
    esockd_sup:listeners().

%%------------------------------------------------------------------------------
%% @doc Get one listener
%%------------------------------------------------------------------------------
-spec listener({atom(), inet:port_number()}) -> pid() | undefined.
listener({Protocol, Port}) ->
    esockd_sup:listener({Protocol, Port}).

%%------------------------------------------------------------------------------
%% @doc Get stats
%%------------------------------------------------------------------------------
-spec get_stats({atom(), inet:port_number()}) -> [{atom(), non_neg_integer()}].
get_stats({Protocol, Port}) ->
    esockd_server:get_stats({Protocol, Port}).

%%------------------------------------------------------------------------------
%% @doc Get acceptors number
%%------------------------------------------------------------------------------
-spec get_acceptors({atom(), inet:port_number()}) -> undefined | pos_integer().
get_acceptors({Protocol, Port}) ->
    LSup = listener({Protocol, Port}),
    get_acceptors(LSup); 
get_acceptors(undefined) ->
    undefined;
get_acceptors(LSup) when is_pid(LSup) ->
    AcceptorSup = esockd_listener_sup:acceptor_sup(LSup),
    esockd_acceptor_sup:count_acceptors(AcceptorSup).

%%------------------------------------------------------------------------------
%% @doc Get max clients
%%------------------------------------------------------------------------------
-spec get_max_clients({atom(), inet:port_number()}) -> undefined | pos_integer().
get_max_clients({Protocol, Port}) ->
    LSup = listener({Protocol, Port}),
    get_max_clients(LSup);
get_max_clients(undefined) ->
    undefined;
get_max_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_max_clients(ConnSup).

%%------------------------------------------------------------------------------
%% @doc Set max clients
%%------------------------------------------------------------------------------
-spec set_max_clients({atom(), inet:port_number()}, pos_integer()) -> undefined | pos_integer().
set_max_clients({Protocol, Port}, MaxClients) ->
    LSup = listener({Protocol, Port}),
    set_max_clients(LSup, MaxClients);
set_max_clients(undefined, _MaxClients) ->
    undefined;
set_max_clients(LSup, MaxClients) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:set_max_clients(ConnSup, MaxClients).

%%------------------------------------------------------------------------------
%% @doc Get current clients
%%------------------------------------------------------------------------------
-spec get_current_clients({atom(), inet:port_number()}) -> undefined | pos_integer().
get_current_clients({Protocol, Port}) ->
    LSup = listener({Protocol, Port}),
    get_current_clients(LSup);
get_current_clients(undefined) ->
    undefined;
get_current_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:count_connections(ConnSup).

%%------------------------------------------------------------------------------
%% @doc Get access rules
%%------------------------------------------------------------------------------
-spec get_access_rules({atom(), inet:port_number()}) -> [esockd_access:rule()] | undefined.
get_access_rules({Protocol, Port}) ->
    LSup = listener({Protocol, Port}),
    get_access_rules(LSup);
get_access_rules(undefined) ->
    undefined;
get_access_rules(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:access_rules(ConnSup).

%%------------------------------------------------------------------------------
%% @doc Allow access address
%%------------------------------------------------------------------------------
-spec allow({atom(), inet:port_number()}, all | esockd_access:cidr()) -> ok | {error, any()}.
allow({Protocol, Port}, CIDR) ->
    LSup = listener({Protocol, Port}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:allow(ConnSup, CIDR).

%%------------------------------------------------------------------------------
%% @doc Deny access address
%%------------------------------------------------------------------------------
-spec deny({atom(), inet:port_number()}, all | esockd_access:cidr()) -> ok | {error, any()}.
deny({Protocol, Port}, CIDR) ->
    LSup = listener({Protocol, Port}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:deny(ConnSup, CIDR).
  
%%------------------------------------------------------------------------------
%% @doc Filter socket options
%%------------------------------------------------------------------------------
sockopts(Opts) ->
	sockopts(Opts, []).
sockopts([], Acc) ->
	Acc;
sockopts([{max_clients, _}|Opts], Acc) ->
	sockopts(Opts, Acc);
sockopts([{acceptors, _}|Opts], Acc) ->
	sockopts(Opts, Acc);
sockopts([{tune_buffer, _}|Opts], Acc) ->
	sockopts(Opts, Acc);
sockopts([{shutdown, _}|Opts], Acc) ->
	sockopts(Opts, Acc);
sockopts([{access, _}|Opts], Acc) ->
    sockopts(Opts, Acc);
sockopts([{ssl, _}|Opts], Acc) ->
    sockopts(Opts, Acc);
sockopts([Opt|Opts], Acc) ->
	sockopts(Opts, [Opt|Acc]).

%%------------------------------------------------------------------------------
%% @doc System `ulimit -n`
%%------------------------------------------------------------------------------
-spec ulimit() -> pos_integer().
ulimit() ->
    proplists:get_value(max_fds, erlang:system_info(check_io)).

