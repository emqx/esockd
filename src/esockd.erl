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
%%% eSockd Main API.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

%% Start Application.
-export([start/0]).

%% Core API
-export([open/4, child_spec/4, close/2, close/1]).

%% Management API
-export([listeners/0, listener/1,
         get_stats/1,
         get_options/1,
         get_acceptors/1,
         get_max_clients/1,
         set_max_clients/2,
         get_current_clients/1,
         get_shutdown_count/1]).

%% Allow, Deny API
-export([get_access_rules/1, allow/2, deny/2]).

%% Utility functions...
-export([ulimit/0, fixaddr/1, to_string/1]).

-type(ssl_socket() :: #ssl_socket{}).

-type(proxy_socket() :: #proxy_socket{}).

-type(tune_fun() :: fun((inet:socket()) -> ok | {error, any()})).

-type(sock_fun() :: fun((inet:socket()) -> {ok, inet:socket() | ssl_socket()} | {error, any()})).

-type(sock_args() :: {atom(), inet:socket(), sock_fun()}).

-type(mfargs() :: atom() | {atom(), atom()} | {module(), atom(), [term()]}).

-type(connopt() :: {rate_limit, string()}
                 | proxy_protocol
                 | {proxy_protocol, boolean()}
                 | {proxy_protocol_timeout, timeout()}).

-type(option() :: {acceptors, pos_integer()}
                | {max_clients, pos_integer()}
                | {access, [esockd_access:rule()]}
                | {shutdown, brutal_kill | infinity | pos_integer()}
                | {tune_buffer, false | true}
                | {logger, gen_logger:logcfg()}
                | {sslopts, [ssl:ssl_option()]}
                | {connopts, [connopt()]}
                | {sockopts, [gen_tcp:listen_option()]}).

-type(listen_on() :: inet:port_number() | {inet:ip_address() | string(), inet:port_number()}).

-export_type([ssl_socket/0, proxy_socket/0, sock_fun/0, sock_args/0, tune_fun/0,
              mfargs/0, option/0, listen_on/0]).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start eSockd Application.
-spec(start() -> ok).
start() ->
    {ok, _} = application:ensure_all_started(esockd), ok.

%% @doc Open a Listener.
-spec(open(atom(), listen_on(), [option()], mfargs()) -> {ok, pid()} | {error, any()}).
open(Protocol, Port, Options, MFArgs) when is_integer(Port) ->
	esockd_sup:start_listener(Protocol, Port, Options, MFArgs);

open(Protocol, {Address, Port}, Options, MFArgs) when is_integer(Port) ->
    {IPAddr, _Port}  = fixaddr({Address, Port}),
    OptAddr = proplists:get_value(ip, proplists:get_value(sockopts, Options, [])),
    if
        (OptAddr == undefined) or (OptAddr == IPAddr) -> ok;
        true -> error(badmatch_ipaddress)
    end,
	esockd_sup:start_listener(Protocol, {IPAddr, Port}, Options, MFArgs).

%% @doc Child Spec for a Listener.
-spec(child_spec(atom(), listen_on(), [option()], mfargs()) -> supervisor:child_spec()).
child_spec(Protocol, ListenOn, Options, MFArgs) ->
    esockd_sup:child_spec(Protocol, fixaddr(ListenOn), Options, MFArgs).

%% @doc Close the Listener
-spec(close({atom(), listen_on()}) -> ok).
close({Protocol, ListenOn}) when is_atom(Protocol) ->
    close(Protocol, ListenOn).

-spec(close(atom(), listen_on()) -> ok).
close(Protocol, ListenOn) when is_atom(Protocol) ->
	esockd_sup:stop_listener(Protocol, fixaddr(ListenOn)).

%% @doc Get listeners.
-spec listeners() -> [{{atom(), listen_on()}, pid()}].
listeners() -> esockd_sup:listeners().

%% @doc Get one listener.
-spec(listener({atom(), listen_on()}) -> pid() | undefined).
listener({Protocol, ListenOn}) ->
    esockd_sup:listener({Protocol, fixaddr(ListenOn)}).

%% @doc Get stats
-spec(get_stats({atom(), listen_on()}) -> [{atom(), non_neg_integer()}]).
get_stats({Protocol, ListenOn}) ->
    esockd_server:get_stats({Protocol, fixaddr(ListenOn)}).

%% @doc Get options
-spec(get_options({atom(), listen_on()}) -> undefined | pos_integer()).
get_options({Protocol, ListenOn}) ->
    with_listener({Protocol, ListenOn}, fun get_options/1);
get_options(LSup) when is_pid(LSup) ->
    esockd_listener:options(esockd_listener_sup:listener(LSup)).

%% @doc Get Acceptors Number
-spec(get_acceptors({atom(), listen_on()}) -> undefined | pos_integer()).
get_acceptors({Protocol, ListenOn}) ->
    with_listener({Protocol, ListenOn}, fun get_acceptors/1);
get_acceptors(LSup) when is_pid(LSup) ->
    AcceptorSup = esockd_listener_sup:acceptor_sup(LSup),
    esockd_acceptor_sup:count_acceptors(AcceptorSup).

%% @doc Get max clients
-spec(get_max_clients({atom(), listen_on()} | pid()) -> undefined | pos_integer()).
get_max_clients({Protocol, ListenOn}) ->
    with_listener({Protocol, ListenOn}, fun get_max_clients/1);
get_max_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_max_clients(ConnSup).

%% @doc Set max clients
-spec(set_max_clients({atom(), listen_on()} | pid(), pos_integer()) -> undefined | pos_integer()).
set_max_clients({Protocol, ListenOn}, MaxClients) ->
    with_listener({Protocol, ListenOn}, fun set_max_clients/2, [MaxClients]);
set_max_clients(LSup, MaxClients) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:set_max_clients(ConnSup, MaxClients).

%% @doc Get current clients
-spec(get_current_clients({atom(), listen_on()}) -> undefined | pos_integer()).
get_current_clients({Protocol, ListenOn}) ->
    with_listener({Protocol, ListenOn}, fun get_current_clients/1);
get_current_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:count_connections(ConnSup).

%% @doc Get shutdown count
-spec(get_shutdown_count({atom(), listen_on()}) -> undefined | pos_integer()).
get_shutdown_count({Protocol, ListenOn}) ->
    with_listener({Protocol, ListenOn}, fun get_shutdown_count/1);
get_shutdown_count(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_shutdown_count(ConnSup).

%% @doc Get access rules
-spec(get_access_rules({atom(), listen_on()}) -> [esockd_access:rule()] | undefined).
get_access_rules({Protocol, ListenOn}) ->
    with_listener({Protocol, ListenOn}, fun get_access_rules/1);
get_access_rules(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:access_rules(ConnSup).

%% @doc Allow access address
-spec(allow({atom(), listen_on()}, all | esockd_cidr:cidr_string()) -> ok | {error, any()}).
allow({Protocol, ListenOn}, CIDR) ->
    LSup = listener({Protocol, ListenOn}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:allow(ConnSup, CIDR).

%% @doc Deny access address
-spec(deny({atom(), listen_on()}, all | esockd_cidr:cidr_string()) -> ok | {error, any()}).
deny({Protocol, ListenOn}, CIDR) ->
    LSup = listener({Protocol, ListenOn}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:deny(ConnSup, CIDR).

%% @doc System 'ulimit -n'
-spec(ulimit() -> pos_integer()).
ulimit() ->
    proplists:get_value(max_fds, erlang:system_info(check_io)).

%% @doc With Listener.
%% @private
with_listener({Protocol, ListenOn}, Fun) ->
    with_listener({Protocol, ListenOn}, Fun, []).

with_listener({Protocol, ListenOn}, Fun, Args) ->
    LSup = listener({Protocol, ListenOn}),
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
%% @private
fixaddr(Port) when is_integer(Port) ->
    Port;
fixaddr({Addr, Port}) when is_list(Addr) and is_integer(Port) ->
    {ok, IPAddr} = inet:parse_address(Addr), {IPAddr, Port};
fixaddr({Addr, Port}) when is_tuple(Addr) and is_integer(Port) ->
    case esockd_cidr:is_ipv6(Addr) or esockd_cidr:is_ipv4(Addr) of
        true  -> {Addr, Port};
        false -> error(invalid_ipaddress)
    end.

