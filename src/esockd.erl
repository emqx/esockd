%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2016 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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
%%% eSockd main api.
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
         get_current_clients/1,
         get_shutdown_count/1]).

%% Allow, Deny API
-export([get_access_rules/1, allow/2, deny/2]).

%% Utility functions...
-export([ulimit/0]).

-type(ssl_socket() :: #ssl_socket{}).
-type(tune_fun()   :: fun((inet:socket()) -> ok | {error, any()})).
-type(sock_fun()   :: fun((inet:socket()) -> {ok, inet:socket() | ssl_socket()} | {error, any()})).
-type(sock_args()  :: {atom(), inet:socket(), sock_fun()}).
-type(mfargs()     :: atom() | {atom(), atom()} | {module(), atom(), [term()]}).
-type(option()     :: {acceptors, pos_integer()}
                    | {max_clients, pos_integer()}
                    | {access, [esockd_access:rule()]}
                    | {shutdown, brutal_kill | infinity | pos_integer()}
                    | {tune_buffer, false | true}
                    | {logger, gen_logger:logcfg()}
                    | {ssl, list()} %%TODO: [ssl:ssloption()]
                    | {sockopts, [gen_tcp:listen_option()]}).

-type(port_or_pair() :: inet:port_number() | {inet:ip_address(), inet:port_number()}).

-export_type([ssl_socket/0, sock_fun/0, sock_args/0, tune_fun/0, mfargs/0, option/0, port_or_pair/0]).

%%------------------------------------------------------------------------------
%% API
%%------------------------------------------------------------------------------

%% @doc Start eSockd Application.
-spec(start() -> ok).
start() -> application:start(esockd).

%% @doc Open a Listener.
-spec(open(Protocol, Port | {Address, Port}, Options, MFArgs) -> {ok, pid()} | {error, any()} when
      Protocol :: atom(),
      Address  :: string() | inet:ip_address(),
      Port     :: inet:port_number(),
      Options  :: [option()],
      MFArgs   :: mfargs()).
open(Protocol, Port, Options, MFArgs) when is_atom(Protocol) andalso is_integer(Port) ->
	esockd_sup:start_listener(Protocol, Port, Options, MFArgs);

open(Protocol, {Address, Port}, Options, MFArgs) when is_atom(Protocol) andalso is_integer(Port) ->
    {IPAddr, _Port}  = fixaddr({Address, Port}),
    OptAddr = addr_opt(Options),
    if
        (OptAddr == undefined) or (OptAddr == IPAddr) ->
            ok;
        true ->
            error(badmatch_ipaddress)
    end,
	esockd_sup:start_listener(Protocol, {IPAddr, Port}, Options, MFArgs).

%% @private
addr_opt(Options) ->
    proplists:get_value(ip, proplists:get_value(sockopts, Options, [])).

%% @doc Close the Listener
-spec(close({atom(), port_or_pair()}) -> ok).
close({Protocol, PortOrPair}) when is_atom(Protocol) ->
    close(Protocol, PortOrPair).

-spec(close(atom(), port_or_pair()) -> ok).
close(Protocol, PortOrPair) when is_atom(Protocol) ->
	esockd_sup:stop_listener(listener_id(Protocol, PortOrPair)).

%% @doc Get listeners.
-spec listeners() -> [{{atom(), port_or_pair()}, pid()}].
listeners() -> esockd_sup:listeners().

%% @doc Get one listener.
-spec(listener({atom(), port_or_pair()}) -> pid() | undefined).
listener({Protocol, PortOrPair}) ->
    esockd_sup:listener(listener_id(Protocol, PortOrPair)).

listener_id(Protocol, Port) when is_integer(Port) ->
    {Protocol, Port};

listener_id(Protocol, {Address, Port}) when is_integer(Port) ->
    {Protocol, {parse_addr(Address), Port}}.

%% @doc Get stats
-spec(get_stats({atom(), port_or_pair()}) -> [{atom(), non_neg_integer()}]).
get_stats({Protocol, PortOrPair}) ->
    esockd_server:get_stats(listener_id(Protocol, PortOrPair)).

%% @doc Get Acceptors Number
-spec(get_acceptors({atom(), port_or_pair()}) -> undefined | pos_integer()).
get_acceptors({Protocol, PortOrPair}) ->
    with_listener(listener_id(Protocol, PortOrPair), fun get_acceptors/1);
get_acceptors(LSup) when is_pid(LSup) ->
    AcceptorSup = esockd_listener_sup:acceptor_sup(LSup),
    esockd_acceptor_sup:count_acceptors(AcceptorSup).

%% @doc Get max clients
-spec(get_max_clients({atom(), port_or_pair()} | pid()) -> undefined | pos_integer()).
get_max_clients({Protocol, PortOrPair}) ->
    with_listener(listener_id(Protocol, PortOrPair), fun get_max_clients/1);
get_max_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_max_clients(ConnSup).

%% @doc Set max clients
-spec(set_max_clients({atom(), port_or_pair()} | pid(), pos_integer()) -> undefined | pos_integer()).
set_max_clients({Protocol, PortOrPair}, MaxClients) ->
    with_listener(listener_id(Protocol, PortOrPair), fun set_max_clients/2, [MaxClients]);
set_max_clients(LSup, MaxClients) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:set_max_clients(ConnSup, MaxClients).

%% @doc Get current clients
-spec(get_current_clients({atom(), port_or_pair()}) -> undefined | pos_integer()).
get_current_clients({Protocol, PortOrPair}) ->
    with_listener(listener_id(Protocol, PortOrPair), fun get_current_clients/1);
get_current_clients(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:count_connections(ConnSup).

%% @doc Get shutdown count
-spec(get_shutdown_count({atom(), port_or_pair()}) -> undefined | pos_integer()).
get_shutdown_count({Protocol, PortOrPair}) ->
    with_listener(listener_id(Protocol, PortOrPair), fun get_shutdown_count/1);
get_shutdown_count(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:get_shutdown_count(ConnSup).

%% @doc Get access rules
-spec(get_access_rules({atom(), port_or_pair()}) -> [esockd_access:rule()] | undefined).
get_access_rules({Protocol, PortOrPair}) ->
    with_listener(listener_id(Protocol, PortOrPair), fun get_access_rules/1);
get_access_rules(LSup) when is_pid(LSup) ->
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:access_rules(ConnSup).

%% @doc Allow access address
-spec(allow({atom(), port_or_pair()}, all | esockd_cidr:cidr_string()) -> ok | {error, any()}).
allow({Protocol, Port}, CIDR) ->
    LSup = listener({Protocol, Port}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:allow(ConnSup, CIDR).

%% @doc Deny access address
-spec(deny({atom(), inet:port_number()}, all | esockd_cidr:cidr_string()) -> ok | {error, any()}).
deny({Protocol, Port}, CIDR) ->
    LSup = listener({Protocol, Port}),
    ConnSup = esockd_listener_sup:connection_sup(LSup),
    esockd_connection_sup:deny(ConnSup, CIDR).

%% @doc System 'ulimit -n'
-spec(ulimit() -> pos_integer()).
ulimit() ->
    proplists:get_value(max_fds, erlang:system_info(check_io)).

%% @doc With Listener.
%% @private
with_listener({Protocol, Port}, Fun) ->
    with_listener({Protocol, Port}, Fun, []).

with_listener({Protocol, Port}, Fun, Args) ->
    LSup = listener({Protocol, Port}),
    with_listener(LSup, Fun, Args);
with_listener(undefined, _Fun, _Args) ->
    undefined;
with_listener(LSup, Fun, Args) when is_pid(LSup) ->
    apply(Fun, [LSup|Args]).

%% @doc Merge Options
merge_opts(Defaults, Options) ->
    lists:foldl(
        fun({Opt, Val}, Acc) ->
                case lists:keymember(Opt, 1, Acc) of
                    true  -> lists:keyreplace(Opt, 1, Acc, {Opt, Val});
                    false -> [{Opt, Val}|Acc]
                end;
            (Opt, Acc) ->
                case lists:member(Opt, Acc) of
                    true  -> Acc;
                    false -> [Opt | Acc]
                end
        end, Defaults, Options).

fixaddr(Port) when is_integer(Port) ->
    Port;
fixaddr({Addr, Port}) when is_list(Addr) and is_integer(Port) ->
    {ok, IPAddr} = inet:parse_address(Addr), {IPAddr, Port};
fixaddr({Addr, Port}) when is_tuple(Addr) and is_integer(Port) ->
    case esockd_cidr:is_ipv6(Addr) or esockd_cidr:is_ipv4(Addr) of
        true  -> {Addr, Port};
        false -> error(invalid_ipaddress)
    end.

