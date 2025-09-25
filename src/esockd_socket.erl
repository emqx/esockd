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

%% @doc This module deals with sockets coming from `esockd:open_tcpsocket/3`
%% listeners, where each socket is essentially `socket:socket()`.
%%
%% Compared to `esockd_transport`, this module *doesn't* provide adapters for
%% sending and receiving TCP stream data, closing, shutting down sockets.
%% This is done on purpose, users are expected to use `socket` APIs directly,
%% largely because `socket`-based connection loop is significantly different
%% from `esockd_transport`-based one, and not worth the effort to adapt due
%% to inevitable performance penalty.
-module(esockd_socket).

-include("esockd.hrl").

-export([type/1]).
-export([controlling_process/2]).
-export([getopts/2, setopts/2]).
-export([ready/3, wait/1]).
-export([fast_close/1]).
-export([sockname/1, peername/1]).
-export([peercert/1, peer_cert_subject/1, peer_cert_common_name/1, peersni/1]).

%% Internal callbacks
-export([proxy_upgrade_fun/1, proxy_upgrade/2]).

-export_type([socket/0]).

-type socket() :: socket:socket().

-spec type(socket()) -> tcp | proxy | {error, closed}.
type(Sock) ->
    case socket:getopt(Sock, {otp, meta}) of
        {ok, #{proxy_protocol := _}} -> proxy;
        {ok, _} -> tcp;
        Error -> Error
    end.

-spec controlling_process(socket(), pid()) -> ok | {error, Reason} when
      Reason :: closed | badarg | inet:posix().
controlling_process(Sock, NewOwner) ->
    socket:setopt(Sock, {otp, controlling_process}, NewOwner).

%% @doc Get socket options.
-spec getopts(socket(), [socket:socket_option()]) ->
    {ok, [{socket:socket_option(), any()}]} | {error, inet:posix() | {invalid, _} | closed}.
getopts(Sock, Opts) ->
    getopts(Sock, Opts, []).

getopts(_Sock, [Opt = {otp, meta} | _], _Acc) ->
    {error, {invalid, Opt}};
getopts(Sock, [Opt | Rest], Acc) ->
    case socket:getopt(Sock, Opt) of
        {ok, Value} ->
            getopts(Sock, Rest, [{Opt, Value} | Acc]);
        Error ->
            Error
    end;
getopts(_Sock, [], Acc) ->
    {ok, lists:reverse(Acc)}.

%% @doc Set socket options.
%% Note this operation is not atomic, and may fail mid-way.
-spec setopts(socket(), [{socket:socket_option(), any()}]) ->
    ok | {error, inet:posix() | {invalid, _} | closed}.
setopts(_Sock, [{Opt = {otp, OptName}, _Value} | _]) when OptName =:= meta;
                                                          OptName =:= controlling_process ->
    %% Disallow changing those options explicitly, to avoid conflicts.
    {error, {invalid, Opt}};
setopts(Sock, [{Opt, Value} | Rest]) ->
    case socket:setopt(Sock, Opt, Value) of
        ok -> setopts(Sock, Rest);
        Error -> Error
    end;
setopts(_Sock, []) ->
    ok.

-spec ready(pid(), socket(), [esockd:sock_fun()]) -> any().
ready(Pid, Sock, UpgradeFuns) ->
    %% NOTE: See `esockd_transport:ready/3'.
    Pid ! {sock_ready, Sock, UpgradeFuns}.

-spec wait(socket()) -> {ok, socket()} | {error, term()}.
wait(Sock) ->
    %% NOTE: See `esockd_transport:wait/1'.
    receive
        {sock_ready, Sock, UpgradeFuns} ->
            upgrade(Sock, UpgradeFuns)
    end.

-spec upgrade(socket(), [esockd:sock_fun()]) -> {ok, socket()} | {error, term()}.
upgrade(Sock, []) ->
    {ok, Sock};
upgrade(Sock, [{Fun, Args} | More]) ->
    case apply(Fun, [Sock | Args]) of
        {ok, NSock} -> upgrade(NSock, More);
        Error       -> fast_close(Sock), Error
    end.

-spec fast_close(socket()) -> ok.
fast_close(Sock) ->
    %% NOTE: Unexpected to fail on active socket.
    _ = socket:setopt(Sock, {socket, linger}, #{onoff => true, linger => 0}),
    socket:close(Sock).

%% @doc Sockname
%% Returns original destination address and port if proxy protocol is enabled.
%% Otherwise, returns the local address and port.
-spec sockname(socket()) -> {ok, {inet:ip_address(), inet:port_number()}}
                            | {error, inet:posix() | closed}.
sockname(Sock) ->
    case socket:getopt(Sock, {otp, meta}) of
        {ok, #{proxy_dst_addr := DstAddr, proxy_dst_port := DstPort}} ->
            {ok, {DstAddr, DstPort}};
        {ok, _} ->
            case socket:sockname(Sock) of
                {ok, #{addr := Addr, port := Port}} ->
                    {ok, {Addr, Port}};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Peername
%% Returns original source address and port if proxy protocol is enabled.
%% Otherwise, returns the local address and port.
-spec peername(socket()) -> {ok, {inet:ip_address(), inet:port_number()}}
                            | {error, inet:posix() | closed}.
peername(Sock) ->
    case socket:getopt(Sock, {otp, meta}) of
        {ok, #{proxy_src_addr := SrcAddr, proxy_src_port := SrcPort}} ->
            {ok, {SrcAddr, SrcPort}};
        {ok, _} ->
            case socket:peername(Sock) of
                {ok, #{addr := Addr, port := Port}} ->
                    {ok, {Addr, Port}};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Socket peercert
%% Returns the peer certificate if proxy protocol is enabled, and the proxy
%% middleware passed it as part of PPv2 exchange.
%% See also `esockd_transport:peercert/1'.
-spec peercert(socket()) -> nossl
                            | list(pp2_additional_ssl_field())
                            | {error, term()}.
peercert(Sock) ->
    case socket:getopt(Sock, {otp, meta}) of
        {ok, #{proxy_pp2_info := Info}} ->
            proplists:get_value(pp2_ssl, Info, []);
        {ok, _} ->
            nossl;
        Error ->
            Error
    end.

%% @doc Peercert subject
%% Returns the common name of the peer certificate if proxy protocol is enabled,
%% and the proxy middleware passed it as part of PPv2 exchange.
%% See also `esockd_transport:peer_cert_subject/1'.
-spec peer_cert_subject(socket()) -> undefined | binary().
peer_cert_subject(Sock) ->
    %% Common Name? Haproxy PP2 will not pass subject.
    peer_cert_common_name(Sock).

%% @doc Peercert common name
%% Returns the common name of the peer certificate if proxy protocol is enabled,
%% and the proxy middleware passed it as part of PPv2 exchange.
%% See also `esockd_transport:peer_cert_common_name/1'.
-spec peer_cert_common_name(socket()) -> undefined | binary().
peer_cert_common_name(Sock) ->
    case socket:getopt(Sock, {otp, meta}) of
        {ok, #{proxy_pp2_info := Info}} ->
            proplists:get_value(pp2_ssl_cn,
                                proplists:get_value(pp2_ssl, Info, []));
        {ok, _} ->
            undefined;
        Error ->
            Error
    end.

%% @doc Peersni
%% Returns the SNI of the peer TLS connection if proxy protocol is enabled,
%% and the proxy middleware passed it as part of PPv2 exchange.
%% See also `esockd_transport:peersni/1'.
-spec peersni(socket()) -> undefined | binary().
peersni(Sock) ->
    case socket:getopt(Sock, {otp, meta}) of
        {ok, #{proxy_pp2_info := Info}} ->
            proplists:get_value(pp2_authority, Info, undefined);
        {ok, _} ->
            undefined;
        Error ->
            Error
    end.

%% @doc TCP -> TCP Socket with Proxy Protocol in `{otp, meta}'.
proxy_upgrade_fun(Opts) ->
    Timeout = proxy_protocol_timeout(Opts),
    {fun ?MODULE:proxy_upgrade/2, [Timeout]}.

proxy_upgrade(Sock, Timeout) ->
    esockd_proxy_protocol:recv(?MODULE, Sock, Timeout).

proxy_protocol_timeout(Opts) ->
    proplists:get_value(proxy_protocol_timeout, Opts, ?PROXY_RECV_TIMEOUT).
