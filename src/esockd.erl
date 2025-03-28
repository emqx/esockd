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

-module(esockd).

-include("esockd.hrl").

-export([start/0]).

%% Core API
-export([ open/3
        , open_udp/3
        , open_dtls/3
        , close/2
        , close/1
        %% Legacy API
        , open/4
        , open_udp/4
        , open_dtls/4
        ]).

-export([ reopen/1
        , reopen/2
        ]).

-export([ child_spec/3
        , udp_child_spec/3
        , dtls_child_spec/3
        %% Legacy API
        , child_spec/4
        , udp_child_spec/4
        , dtls_child_spec/4
        ]).

%% Management API
-export([ listeners/0
        , listener/1
        ]).

-export([ get_stats/1
        , get_options/1
        , set_options/2
        , reset_options/2
        , get_acceptors/1
        ]).

-export([ get_max_connections/1
        , set_max_connections/2
        , get_current_connections/1
        , get_max_conn_rate/1
        , set_max_conn_rate/2
        ]).

-export([get_shutdown_count/1]).

%% Allow, Deny API
-export([ get_access_rules/1
        , allow/2
        , deny/2
        ]).

%% Utility functions
-export([ merge_opts/2
        , changed_opts/2
        , parse_opt/1
        , start_mfargs/3
        , ulimit/0
        , fixaddr/1
        , to_string/1
        , format/1
        ]).

-export_type([ proto/0
             , transport/0
             , udp_transport/0
             , socket/0
             , sock_fun/0
             , mfargs/0
             , option/0
             , listen_on/0
             , listener_ref/0
             ]).

-type(proto() :: atom()).
-type(transport() :: module()).
-type(udp_transport() :: {udp | dtls, pid(), inet:socket()}).
-type(socket() :: esockd_transport:socket()).
-type(mfargs() :: atom() | {atom(), atom()} | {module(), atom(), [term()]}).
-type(sock_fun() :: {function(), list()}).
-type(conn_limit() :: map() | {pos_integer(), pos_integer()}).
-type(options() :: [option()]).
-type(option() :: {acceptors, pos_integer()}
                | {max_connections, pos_integer()}
                | {max_conn_rate, conn_limit()}
                | {connection_mfargs, mfargs()}
                | {access_rules, [esockd_access:rule()]}
                | {shutdown, brutal_kill | infinity | pos_integer()}
                | tune_buffer | {tune_buffer, boolean()}
                | proxy_protocol | {proxy_protocol, boolean()}
                | {proxy_protocol_timeout, timeout()}
                | {ssl_options, ssl_options()}
                | {tcp_options, [gen_tcp:listen_option()]}
                | {udp_options, [gen_udp:option()]}
                | {dtls_options, dtls_options()}).

-type(host() :: inet:ip_address() | string()).
-type(listen_on() :: inet:port_number() | {host(), inet:port_number()}).
-type ssl_options() :: [ssl_custom_option() | ssl_option()].
-type dtls_options() :: [ssl_custom_option() | ssl_option()].
-type ssl_custom_option() :: {handshake_timeout, pos_integer()}
                           | {gc_after_handshake, boolean()}.
-type listener_ref() :: {proto(), listen_on()}.

%%--------------------------------------------------------------------
%% APIs
%%--------------------------------------------------------------------

%% @doc Start esockd application.
-spec(start() -> ok).
start() ->
    {ok, _} = application:ensure_all_started(esockd), ok.

%%--------------------------------------------------------------------
%% Open & Close

%% @doc Open a TCP or SSL listener
%% @end
%% TODO: Check if Opts is valid before start_child.
%% ssl_options check implemented by esockd_acceptor_sup
%% max_connections check implemented by esockd_connection_sup
%% access_rules check implemented by esockd_connection_sup
-spec open(atom(), listen_on(), options()) -> {ok, pid()} | {error, term()}.
open(Proto, Port, Opts) when is_atom(Proto), is_integer(Port) ->
	esockd_sup:start_child(child_spec(Proto, Port, Opts));
open(Proto, {Host, Port}, Opts) when is_atom(Proto), is_integer(Port) ->
    {IPAddr, _Port} = fixaddr({Host, Port}),
    case proplists:get_value(ip, tcp_options(Opts)) of
        undefined -> ok;
        IPAddr    -> ok;
        Other     -> error({badmatch, Other})
    end,
	esockd_sup:start_child(child_spec(Proto, {IPAddr, Port}, Opts)).

%% @private
tcp_options(Opts) ->
    proplists:get_value(tcp_options, Opts, []).

%% @doc Open a TCP or SSL listener
-spec open(atom(), listen_on(), [option()], mfargs()) -> {ok, pid()} | {error, term()}.
open(Proto, Port, Opts, MFA) ->
	open(Proto, Port, merge_mfargs(Opts, MFA)).

%% @doc Open a UDP listener
-spec open_udp(atom(), listen_on(), [option()])
      -> {ok, pid()} | {error, term()}.
open_udp(Proto, Port, Opts) ->
    esockd_sup:start_child(udp_child_spec(Proto, Port, Opts)).

%% @doc Open a UDP listener
-spec open_udp(atom(), listen_on(), [option()], mfargs())
      -> {ok, pid()} | {error, term()}.
open_udp(Proto, Port, Opts, MFA) ->
    open_udp(Proto, Port, merge_mfargs(Opts, MFA)).

%% @doc Open a DTLS listener
-spec open_dtls(atom(), listen_on(), options())
      -> {ok, pid()} | {error, term()}.
open_dtls(Proto, ListenOn, Opts) ->
    esockd_sup:start_child(dtls_child_spec(Proto, ListenOn, Opts)).

%% @doc Open a DTLS listener
-spec(open_dtls(atom(), listen_on(), options(), mfargs())
     -> {ok, pid()}
      | {error, term()}).
open_dtls(Proto, ListenOn, Opts, MFA) ->
    open_dtls(Proto, ListenOn, merge_mfargs(Opts, MFA)).

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

%%--------------------------------------------------------------------
%% Spec funcs

%% @doc Create a Child spec for a TCP/SSL Listener. It is a convenient method
%% for creating a Child spec to hang on another Application supervisor.
-spec child_spec(atom(), listen_on(), options())
      -> supervisor:child_spec().
child_spec(Proto, ListenOn, Opts) when is_atom(Proto) ->
    esockd_sup:child_spec(Proto, fixaddr(ListenOn), Opts).

-spec child_spec(atom(), listen_on(), options(), mfargs())
      -> supervisor:child_spec().
child_spec(Proto, ListenOn, Opts, MFA) when is_atom(Proto) ->
    child_spec(Proto, ListenOn, merge_mfargs(Opts, MFA)).

%% @doc Create a Child spec for a UDP Listener.
-spec udp_child_spec(atom(), listen_on(), options())
     -> supervisor:child_spec().
udp_child_spec(Proto, Port, Opts) ->
    esockd_sup:udp_child_spec(Proto, fixaddr(Port), Opts).

%% @doc Create a Child spec for a UDP Listener.
-spec udp_child_spec(atom(), listen_on(), options(), mfargs())
     -> supervisor:child_spec().
udp_child_spec(Proto, Port, Opts, MFA) ->
    udp_child_spec(Proto, Port, merge_mfargs(Opts, MFA)).

%% @doc Create a Child spec for a DTLS Listener.
-spec dtls_child_spec(atom(), listen_on(), options())
     -> supervisor:child_spec().
dtls_child_spec(Proto, ListenOn, Opts) ->
    esockd_sup:dtls_child_spec(Proto, fixaddr(ListenOn), Opts).

%% @doc Create a Child spec for a DTLS Listener.
-spec dtls_child_spec(atom(), listen_on(), options(), mfargs())
     -> supervisor:child_spec().
dtls_child_spec(Proto, ListenOn, Opts, MFA) ->
    dtls_child_spec(Proto, ListenOn, merge_mfargs(Opts, MFA)).

merge_mfargs(Opts, MFA) ->
    [{connection_mfargs, MFA} | proplists:delete(connection_mfargs, Opts)].

%%--------------------------------------------------------------------
%% Get/Set APIs

%% @doc Get listeners.
-spec(listeners() -> [{{atom(), listen_on()}, pid()}]).
listeners() -> esockd_sup:listeners().

%% @doc Get one listener.
-spec(listener({atom(), listen_on()}) -> pid()).
listener({Proto, ListenOn}) when is_atom(Proto) ->
    esockd_sup:listener({Proto, fixaddr(ListenOn)}).

%% @doc Get stats
-spec(get_stats({atom(), listen_on()}) -> [{atom(), non_neg_integer()}]).
get_stats({Proto, ListenOn}) when is_atom(Proto) ->
    esockd_server:get_stats({Proto, fixaddr(ListenOn)}).

%% @doc Get options
-spec(get_options({atom(), listen_on()}) -> options()).
get_options({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener_ref({Proto, ListenOn}, ?FUNCTION_NAME, []).

%% @doc Set applicable listener options, without affecting existing connections.
%% If some options could not be set, either because they are not applicable or
%% because they require a listener restart, function returns an error.
-spec set_options({atom(), listen_on()}, options()) ->
    ok | {error, not_supported | _UpdateErrorReason}.
set_options({Proto, _ListenOn} = ListenerRef, Options) when is_atom(Proto) ->
    OptionsWas = get_options(ListenerRef),
    OptionsMerged = merge_opts(OptionsWas, Options),
    with_listener_ref(ListenerRef, ?FUNCTION_NAME, [OptionsMerged]).

%% @doc Replace set of applicable listener options, without affecting existing
%% connections. In contrast to `set_options/2` existing options are not preserved,
%% and will be reset back to defaults if not present in `Options`.
%% See also: `set_options/2`.
-spec reset_options({atom(), listen_on()}, options()) ->
    ok | {error, not_supported | _UpdateErrorReason}.
reset_options({Proto, _ListenOn} = ListenerRef, Options) when is_atom(Proto) ->
    with_listener_ref(ListenerRef, set_options, [Options]).

%% @doc Get acceptors number
-spec(get_acceptors({atom(), listen_on()}) -> pos_integer()).
get_acceptors({Proto, ListenOn}) ->
    with_listener({Proto, ListenOn}, ?FUNCTION_NAME).

%% @doc Get max connections
-spec(get_max_connections({atom(), listen_on()} | pid()) -> pos_integer()).
get_max_connections({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, ?FUNCTION_NAME).

%% @doc Set max connections
-spec(set_max_connections({atom(), listen_on()}, pos_integer()) -> ok).
set_max_connections({Proto, ListenOn}, MaxConns) when is_atom(Proto) ->
    with_listener_ref({Proto, ListenOn}, ?FUNCTION_NAME, [MaxConns]).

%% @doc Set max connection rate
-spec(get_max_conn_rate({atom(), listen_on()}) -> conn_limit()).
get_max_conn_rate({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, ?FUNCTION_NAME, [Proto, ListenOn]).

%% @doc Set max connection rate
-spec(set_max_conn_rate({atom(), listen_on()}, conn_limit()) -> ok).
set_max_conn_rate({Proto, ListenOn}, Opt) when is_atom(Proto) ->
    with_listener_ref({Proto, ListenOn}, ?FUNCTION_NAME, [Opt]).

%% @doc Get current connections
-spec(get_current_connections({atom(), listen_on()}) -> non_neg_integer()).
get_current_connections({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, ?FUNCTION_NAME).

%% @doc Get shutdown count
-spec(get_shutdown_count({atom(), listen_on()}) -> pos_integer()).
get_shutdown_count({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, ?FUNCTION_NAME).

%% @doc Get access rules
-spec(get_access_rules({atom(), listen_on()}) -> [esockd_access:rule()]).
get_access_rules({Proto, ListenOn}) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, ?FUNCTION_NAME).

%% @doc Allow access address
-spec(allow({atom(), listen_on()}, all | esockd_cidr:cidr_string()) -> ok).
allow({Proto, ListenOn}, CIDR) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, ?FUNCTION_NAME, [CIDR]).

%% @doc Deny access address
-spec(deny({atom(), listen_on()}, all | esockd_cidr:cidr_string()) -> ok).
deny({Proto, ListenOn}, CIDR) when is_atom(Proto) ->
    with_listener({Proto, ListenOn}, ?FUNCTION_NAME, [CIDR]).

%%--------------------------------------------------------------------
%% Utils

-spec start_mfargs(mfargs(), _Arg1, _Arg2) -> _Ret.
start_mfargs(M, A1, A2) when is_atom(M) ->
    M:start_link(A1, A2);
start_mfargs({M, F}, A1, A2) when is_atom(M), is_atom(F) ->
    M:F(A1, A2);
start_mfargs({M, F, Args}, A1, A2) when is_atom(M), is_atom(F), is_list(Args) ->
    erlang:apply(M, F, [A1, A2 | Args]).

%% @doc Merge two options
-spec(merge_opts(proplists:proplist(), proplists:proplist())
      -> proplists:proplist()).
merge_opts(Opts1, Opts2) ->
    squash_opts(Opts1 ++ Opts2).

squash_opts([{Name, Value} | Rest]) ->
    Overrides = proplists:get_all_values(Name, Rest),
    Merged = lists:foldl(fun(O, V) -> merge_opt(Name, V, O) end, Value, Overrides),
    make_opt(Name, Merged) ++ squash_opts(proplists:delete(Name, Rest));
squash_opts([Name | Rest]) when is_atom(Name) ->
    [Name | squash_opts([Opt || Opt <- Rest, Opt =/= Name])];
squash_opts([]) ->
    [].

make_opt(_Name, undefined) -> [];
make_opt(Name, Value) -> [{Name, Value}].

merge_opt(ssl_options, Opts1, Opts2) -> merge_opts(Opts1, Opts2);
merge_opt(tcp_options, Opts1, Opts2) -> merge_opts(Opts1, Opts2);
merge_opt(udp_options, Opts1, Opts2) -> merge_opts(Opts1, Opts2);
merge_opt(dtls_options, Opts1, Opts2) -> merge_opts(Opts1, Opts2);
merge_opt(_, _Opt1, Opt2) -> Opt2.

-spec changed_opts(proplists:proplist(), proplists:proplist())
      -> proplists:proplist().
changed_opts(Opts, OptsRef) ->
    lists:filter(
        fun(Opt) ->
            [Name] = proplists:get_keys([Opt]),
            Value = proplists:get_value(Name, [Opt]),
            ValueRef = proplists:get_value(Name, OptsRef),
            ValueRef =/= Value orelse ValueRef == undefined
        end,
        Opts
    ).

%% @doc Parse option.
parse_opt(Options) ->
    parse_opt(Options, []).
parse_opt([], Acc) ->
    lists:reverse(Acc);
parse_opt([{acceptors, I}|Opts], Acc) when is_integer(I) ->
    parse_opt(Opts, [{acceptors, I}|Acc]);
parse_opt([{max_connections, I}|Opts], Acc) when is_integer(I) ->
    parse_opt(Opts, [{max_connections, I}|Acc]);
parse_opt([{max_conn_rate, Limit}|Opts], Acc) when Limit > 0 ->
    parse_opt(Opts, [{max_conn_rate, {Limit, 1}}|Acc]);
parse_opt([{max_conn_rate, {Limit, Period}}|Opts], Acc) when Limit > 0, Period >0 ->
    parse_opt(Opts, [{max_conn_rate, {Limit, Period}}|Acc]);
parse_opt([{access_rules, Rules}|Opts], Acc) ->
    parse_opt(Opts, [{access_rules, Rules}|Acc]);
parse_opt([{shutdown, I}|Opts], Acc) when I == brutal_kill; I == infinity; is_integer(I) ->
    parse_opt(Opts, [{shutdown, I}|Acc]);
parse_opt([tune_buffer|Opts], Acc) ->
    parse_opt(Opts, [{tune_buffer, true}|Acc]);
parse_opt([{tune_buffer, I}|Opts], Acc) when is_boolean(I) ->
    parse_opt(Opts, [{tune_buffer, I}|Acc]);
parse_opt([proxy_protocol|Opts], Acc) ->
    parse_opt(Opts, [{proxy_protocol, true}|Acc]);
parse_opt([{proxy_protocol, I}|Opts], Acc) when is_boolean(I) ->
    parse_opt(Opts, [{proxy_protocol, I}|Acc]);
parse_opt([{proxy_protocol_timeout, Timeout}|Opts], Acc) when is_integer(Timeout) ->
    parse_opt(Opts, [{proxy_protocol_timeout, Timeout}|Acc]);
parse_opt([{ssl_options, L}|Opts], Acc) when is_list(L) ->
    parse_opt(Opts, [{ssl_options, L}|Acc]);
parse_opt([{tcp_options, L}|Opts], Acc) when is_list(L) ->
    parse_opt(Opts, [{tcp_options, L}|Acc]);
parse_opt([{udp_options, L}|Opts], Acc) when is_list(L) ->
    parse_opt(Opts, [{udp_options, L}|Acc]);
parse_opt([{dtls_options, L}|Opts], Acc) when is_list(L) ->
    parse_opt(Opts, [{dtls_options, L}|Acc]);
parse_opt([_|Opts], Acc) ->
    parse_opt(Opts, Acc).

-define(MAGIC_MAX_FDS, 1023).
%% Magic!
%% According to Erlang/OTP doc, erlang:system_info(check_io)):
%% Returns a list containing miscellaneous information about the emulators
%% internal I/O checking. Notice that the content of the returned list can
%% vary between platforms and over time. It is only guaranteed that a list
%% is returned.

%% @doc System 'ulimit -n'
-spec(ulimit() -> pos_integer()).
ulimit() ->
    find_max_fd(erlang:system_info(check_io), ?MAGIC_MAX_FDS).

find_max_fd([], Acc) when is_integer(Acc) andalso Acc >= 0 ->
    Acc;
find_max_fd([CheckIoResult | More], Acc) ->
    case lists:keyfind(max_fds, 1, CheckIoResult) of
        {max_fds, N} when is_integer(N) andalso N > 0 ->
            find_max_fd(More, max(Acc, N));
        _ ->
            find_max_fd(More, Acc)
    end.

-spec(to_string(listen_on()) -> string()).
to_string(Port) when is_integer(Port) ->
    integer_to_list(Port);
to_string({Addr, Port}) ->
    format(fixaddr({Addr, Port})).

%% @doc Parse Address
fixaddr(Port) when is_integer(Port) ->
    Port;
fixaddr({Addr, Port}) when is_list(Addr), is_integer(Port) ->
    {ok, IPAddr} = inet:parse_address(Addr), {IPAddr, Port};
fixaddr({Addr, Port}) when is_tuple(Addr), is_integer(Port) ->
    case esockd_cidr:is_ipv6(Addr) or esockd_cidr:is_ipv4(Addr) of
        true  -> {Addr, Port};
        false -> error({invalid_ipaddr, Addr})
    end.

-spec(format({inet:ip_address(), inet:port_number()}) -> string()).
format({Addr, Port}) ->
    inet:ntoa(Addr) ++ ":" ++ integer_to_list(Port).

%%--------------------------------------------------------------------
%% Internal funcs
%%--------------------------------------------------------------------

with_listener({Proto, ListenOn}, Fun) ->
    with_listener({Proto, ListenOn}, Fun, []).

with_listener({Proto, ListenOn}, Fun, Args) ->
    case esockd_sup:listener_and_module({Proto, ListenOn}) of
        undefined ->
            error(not_found);
        {LSup, Mod} ->
            erlang:apply(Mod, Fun, [LSup | Args])
    end.

with_listener_ref(ListenerRef = {Proto, ListenOn}, Fun, Args) ->
    case esockd_sup:listener_and_module({Proto, ListenOn}) of
        undefined ->
            error(not_found);
        {LSup, Mod} ->
            erlang:apply(Mod, Fun, [ListenerRef, LSup | Args])
    end.
