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

-module(esockd).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-export([start/0]).

%% Core API
-export([open/4, child_spec/4, close/2, close/1, reopen/1, reopen/2]).

%% Management API
-export([listeners/0, listener/1]).
-export([get_stats/1, get_options/1, get_acceptors/1]).
-export([get_max_clients/1, set_max_clients/2, get_current_clients/1]).
-export([get_shutdown_count/1]).

%% Allow, Deny API
-export([get_access_rules/1, allow/2, deny/2]).

%% Utility functions...
-export([ulimit/0, fixaddr/1, to_string/1]).

-type(sock_fun() :: fun((esockd_transport:sock())
                        -> {ok, esockd_transport:sock()} | {error, term()})).

-type(mfargs() :: atom() | {atom(), atom()} | {module(), atom(), [term()]}).

-type(option() :: {acceptors, pos_integer()}
                | {max_clients, pos_integer()}
                | {access_rules, [esockd_access:rule()]}
                | {shutdown, brutal_kill | infinity | pos_integer()}
                | tune_buffer | {tune_buffer, boolean()}
                | proxy_protocol | {proxy_protocol, boolean()}
                | {proxy_protocol_timeout, timeout()}
                | {ssl_options, [ssl:ssl_option()]}
                | {tcp_options, [gen_tcp:listen_option()]}
                | {udp_options, [gen_udp:option()]}).

-type(host() :: inet:ip_address() | string()).

-type(listen_on() :: inet:port_number() | {host(), inet:port_number()}).

-export_type([sock_fun/0, mfargs/0, option/0, listen_on/0]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start esockd application.
-spec(start() -> ok).
start() ->
    {ok, _} = application:ensure_all_started(esockd), ok.

%% @doc Open a listener
-spec(open(atom(), listen_on(), [option()], mfargs())
      -> {ok, pid()} | {error, term()}).
open(Proto, Port, Options, MFArgs) when is_atom(Proto), is_integer(Port) ->
	esockd_sup:start_listener(Proto, Port, Options, MFArgs);
open(Proto, {Host, Port}, Options, MFArgs) when is_atom(Proto), is_integer(Port) ->
    {IPAddr, _Port} = fixaddr({Host, Port}),
    case proplists:get_value(ip, tcp_options(Options)) of
        undefined -> ok;
        IPAddr    -> ok;
        Other     -> error({badmatch, Other})
    end,
	esockd_sup:start_listener(Proto, {IPAddr, Port}, Options, MFArgs).

tcp_options(Options) ->
    proplists:get_value(tcp_options, Options, []).

%% @doc Child spec for a listener
-spec(child_spec(atom(), listen_on(), [option()], mfargs())
      -> supervisor:child_spec()).
child_spec(Proto, ListenOn, Options, MFArgs) when is_atom(Proto) ->
    esockd_sup:child_spec(Proto, fixaddr(ListenOn), Options, MFArgs).

%% @doc Close the listener
-spec(close({atom(), listen_on()}) -> ok | {error, term()}).
close({Proto, ListenOn}) when is_atom(Proto) ->
    close(Proto, ListenOn).

-spec(close(atom(), listen_on()) -> ok | {error, term()}).
close(Proto, ListenOn) when is_atom(Proto) ->
	esockd_sup:stop_listener(Proto, fixaddr(ListenOn)).

%% @doc Reopen the listener
-spec(reopen({atom(), listen_on()}) -> {ok, pid()} | {error, term()}).
reopen({Proto, ListenOn}) when is_atom(Proto) ->
    reopen(Proto, ListenOn).

-spec(reopen(atom(), listen_on()) -> {ok, pid()} | {error, term()}).
reopen(Proto, ListenOn) when is_atom(Proto) ->
    esockd_sup:restart_listener(Proto, fixaddr(ListenOn)).

%% @doc Get listeners.
-spec(listeners() -> [{{atom(), listen_on()}, pid()}]).
listeners() -> esockd_sup:listeners().

%% @doc Get one listener.
-spec(listener({atom(), listen_on()}) -> pid() | undefined).
listener({Proto, ListenOn}) when is_atom(Proto) ->
    esockd_sup:listener({Proto, fixaddr(ListenOn)}).

%% @doc Get stats
-spec(get_stats({atom(), listen_on()}) -> [{atom(), non_neg_integer()}]).
get_stats({Proto, ListenOn}) when is_atom(Proto) ->
    esockd_server:get_stats({Proto, fixaddr(ListenOn)}).

%% @doc Get options
-spec(get_options({atom(), listen_on()}) -> undefined | pos_integer()).
get_options({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, fun get_options/1);
get_options(LSup) when is_pid(LSup) ->
    esockd_listener:options(esockd_listener_sup:listener(LSup)).

%% @doc Get acceptors number
-spec(get_acceptors({atom(), listen_on()}) -> undefined | pos_integer()).
get_acceptors({Proto, ListenOn}) ->
    with_listener({Proto, ListenOn}, fun get_acceptors/1);
get_acceptors(LSup) when is_pid(LSup) ->
    AcceptorSup = esockd_listener_sup:acceptor_sup(LSup),
    esockd_acceptor_sup:count_acceptors(AcceptorSup).

%% @doc Get max clients
-spec(get_max_clients({atom(), listen_on()} | pid()) -> undefined | pos_integer()).
get_max_clients({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, fun get_max_clients/1);
get_max_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_max_clients(ConnSup).

%% @doc Set max clients
-spec(set_max_clients({atom(), listen_on()} | pid(), pos_integer())
      -> undefined | pos_integer()).
set_max_clients({Proto, ListenOn}, MaxClients) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, fun set_max_clients/2, [MaxClients]);
set_max_clients(LSup, MaxClients) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:set_max_clients(ConnSup, MaxClients).

%% @doc Get current clients
-spec(get_current_clients({atom(), listen_on()}) -> undefined | pos_integer()).
get_current_clients({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, fun get_current_clients/1);
get_current_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:count_connections(ConnSup).

%% @doc Get shutdown count
-spec(get_shutdown_count({atom(), listen_on()}) -> undefined | pos_integer()).
get_shutdown_count({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, fun get_shutdown_count/1);
get_shutdown_count(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_shutdown_count(ConnSup).

%% @doc Get access rules
-spec(get_access_rules({atom(), listen_on()}) -> [esockd_access:rule()] | undefined).
get_access_rules({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, fun get_access_rules/1);
get_access_rules(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:access_rules(ConnSup).

%% @doc Allow access address
-spec(allow({atom(), listen_on()}, all | esockd_cidr:cidr_string())
      -> ok | {error, term()}).
allow({Proto, ListenOn}, CIDR) when is_atom(Proto) ->
    LSup = listener({Proto, ListenOn}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:allow(ConnSup, CIDR).

%% @doc Deny access address
-spec(deny({atom(), listen_on()}, all | esockd_cidr:cidr_string())
      -> ok | {error, term()}).
deny({Proto, ListenOn}, CIDR) when is_atom(Proto) ->
    LSup = listener({Proto, ListenOn}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:deny(ConnSup, CIDR).

%% @doc System 'ulimit -n'
-spec(ulimit() -> pos_integer()).
ulimit() ->
    proplists:get_value(max_fds, erlang:system_info(check_io)).

with_listener({Proto, ListenOn}, Fun) ->
    with_listener({Proto, ListenOn}, Fun, []).

with_listener({Proto, ListenOn}, Fun, Args) ->
    LSup = listener({Proto, ListenOn}),
    with_listener(LSup, Fun, Args);
with_listener(undefined, _Fun, _Args) ->
    undefined;
with_listener(LSup, Fun, Args) when is_pid(LSup) ->
    apply(Fun, [LSup | Args]).

-spec(to_string(listen_on()) -> string()).
to_string(Port) when is_integer(Port) ->
    integer_to_list(Port);
to_string({Addr, Port}) ->
    {IPAddr, Port} = fixaddr({Addr, Port}),
    inet:ntoa(IPAddr) ++ ":" ++ integer_to_list(Port).

%% @doc Parse Address
fixaddr(Port) when is_integer(Port) ->
    Port;
fixaddr({Addr, Port}) when is_list(Addr) and is_integer(Port) ->
    {ok, IPAddr} = inet:parse_address(Addr), {IPAddr, Port};
fixaddr({Addr, Port}) when is_tuple(Addr) and is_integer(Port) ->
    case esockd_cidr:is_ipv6(Addr) or esockd_cidr:is_ipv4(Addr) of
        true  -> {Addr, Port};
        false -> error(invalid_ipaddr)
    end.

