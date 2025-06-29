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

-module(esockd_socket).

-include("esockd.hrl").

-export([controlling_process/2]).
-export([ready/3, wait/1]).
-export([sockname/1, peername/1]).
-export([peercert/1, peer_cert_subject/1, peer_cert_common_name/1, peersni/1]).

%% Internal callbacks
-export([proxy_upgrade_fun/1, proxy_upgrade/2]).

-type socket() :: socket:socket().

-spec controlling_process(socket(), pid()) -> ok | {error, Reason} when
      Reason :: closed | badarg | inet:posix().
controlling_process(Sock, NewOwner) ->
    socket:setopt(Sock, {otp, controlling_process}, NewOwner).

-spec(ready(pid(), socket(), [esockd:sock_fun()]) -> any()).
ready(Pid, Sock, UpgradeFuns) ->
    esockd_transport:ready(Pid, Sock, UpgradeFuns).

-spec(wait(socket()) -> {ok, socket()} | {error, term()}).
wait(Sock) ->
    esockd_transport:wait(Sock).

%% @doc Sockname
-spec sockname(socket()) -> {ok, {inet:ip_address(), inet:port_number()}}
                            | {error, inet:posix()}.
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
-spec peername(socket()) -> {ok, {inet:ip_address(), inet:port_number()}}
                            | {error, inet:posix()}.
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
-spec peer_cert_subject(socket()) -> undefined | binary().
peer_cert_subject(Sock) ->
    %% Common Name? Haproxy PP2 will not pass subject.
    peer_cert_common_name(Sock).

%% @doc Peercert common name
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
