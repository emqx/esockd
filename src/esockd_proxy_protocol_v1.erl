%%--------------------------------------------------------------------
%% Copyright (c) 2020-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_proxy_protocol_v1).

-include("esockd.hrl").

-export([parse/2, parse_tcp_line/3, recv_socket/2]).

-define(SPACE, 16#20).

parse_tcp_line(Proto, ProxyInfo, Sock) ->
    parse(ProxyInfo, #proxy_socket{inet = inet_family(Proto), socket = Sock}).

recv_socket(Sock, Deadline) ->
    case socket_recvline(Sock, _MaxLine = 108, Deadline) of
        %% NOTE: "PR" was already received.
        {ok, <<"OXY TCP", Proto, ?SPACE, ProxyInfo/binary>>} ->
            parse_tcp_line(Proto, ProxyInfo, Sock);
        {ok, <<"OXY UNKNOWN", _ProxyInfo/binary>>} ->
            {ok, Sock};
        {ok, Header} ->
            {error, {invalid_proxy_info, <<"PR", Header/binary>>}};
        {error, _} = Error ->
            Error
    end.

parse(ProxyInfo, ProxySock) ->
    [SrcAddrBin, DstAddrBin, SrcPortBin, DstPortBin]
        = binary:split(ProxyInfo, [<<" ">>, <<"\r\n">>], [global, trim]),
    {ok, SrcAddr} = inet:parse_address(binary_to_list(SrcAddrBin)),
    {ok, DstAddr} = inet:parse_address(binary_to_list(DstAddrBin)),
    SrcPort = list_to_integer(binary_to_list(SrcPortBin)),
    DstPort = list_to_integer(binary_to_list(DstPortBin)),
    {ok, ProxySock#proxy_socket{
            src_addr = SrcAddr,
            dst_addr = DstAddr,
            src_port = SrcPort,
            dst_port = DstPort
        }}.

socket_recvline(Sock, MaxLine, Deadline) ->
    case socket:recv(Sock, 0, [peek], timeout_left(Deadline)) of
        {ok, Bytes} ->
            MatchOpts =
                case byte_size(Bytes) of
                    N when N > MaxLine -> [{scope, {0, MaxLine}}];
                    _ -> []
                end,
            case binary:match(Bytes, <<"\r\n">>, MatchOpts) of
                {Pos, _} ->
                    _ = socket:recv(Sock, Pos + 2, [], timeout_left(Deadline)),
                    {ok, binary:part(Bytes, {0, Pos})};
                nomatch when byte_size(Bytes) < MaxLine ->
                    socket_recvline(Sock, MaxLine, Deadline);
                nomatch ->
                    {error, {invalid_proxy_info, Bytes}}
            end;
        {error, Reason} ->
            map_tcpsocket_error(Reason)
    end.

map_tcpsocket_error(closed) ->
    {error, proxy_proto_close};
map_tcpsocket_error(timeout) ->
    {error, proxy_proto_timeout};
map_tcpsocket_error({closed, _}) ->
    {error, proxy_proto_close};
map_tcpsocket_error({timeout, _}) ->
    {error, proxy_proto_timeout};
map_tcpsocket_error({Reason, _}) ->
    {error, {recv_proxy_info_error, Reason}};
map_tcpsocket_error(Reason) ->
    {error, {recv_proxy_info_error, Reason}}.

timeout_left(infinity) ->
    infinity;
timeout_left(Deadline) ->
    max(0, Deadline - erlang:monotonic_time(millisecond)).

inet_family($4) -> inet4;
inet_family($6) -> inet6.
