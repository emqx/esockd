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
%%% eSockd [Proxy Protocol](http://www.haproxy.org/download/1.5/doc/proxy-protocol.txt).
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(esockd_proxy_proto).

-author("Feng Lee <feng@emqtt.io>").

-include("esockd.hrl").

-export([parse/2]).

-define(PROXY_PROTO_V1, 1).

-define(PROXY_PROTO_V2, 2).

-define(PROXY_PROTO_TIMEOUT, 10000).

-spec parse(inet:socket() | #ssl_socket{}, list(tuple())) -> ignore | {ok, #proxy_socket{}} |{error, any()}. 
parse(Sock, Opts) ->
    Version = proplists:get_value(proxy_protocol, Opts, ?PROXY_PROTO_V1),
    Timeout = proplists:get_value(proxy_protocol_timeout, Opts, ?PROXY_PROTO_TIMEOUT),
    parse(Version, Sock, Timeout).

parse(?PROXY_PROTO_V1, Sock, Timeout) ->
    {ok, OriginOpts} = esockd_transport:getopts(Sock, [active, packet]),
    ok = esockd_transport:setopts(Sock, [{active, once}, {packet, line}]),
    receive
        {_, _Sock, <<"PROXY TCP", Proto, _Space, ProxyInfo/binary>>} ->
            io:format("~p~n", [ProxyInfo]),
            esockd_transport:setopts(Sock, OriginOpts),
            {SrcAddr, SrcPort, DstAddr, DstPort} = parse_proxy_info(ProxyInfo),
            {ok, #proxy_socket{inet     = parse_inet(Proto),
                               socket   = Sock,
                               src_addr = SrcAddr,
                               dst_addr = DstAddr,
                               src_port = SrcPort,
                               dst_port = DstPort}};
        {_, _Sock, <<"PROXY UNKNOWN", _ProxyInfo/binary>>} ->
            esockd_transport:setopts(Sock, OriginOpts), {ok, Sock};
        {_, _Sock, ProxyInfo} ->
            {error, {invalid_proxy_info, ProxyInfo}}
    after
        Timeout ->
            {error, proxy_proto_timeout}
    end;

parse(?PROXY_PROTO_V2, Sock, Timeout) ->
    ProxyProtoSignature = ?PROXY_PROTO_V2_SIG,
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, <<ProxyProtoSignature:12/binary, 16#2:4, ?PC_LOCAL:4, ?AF_UNSPEC:4, ?TP_UNSPEC:4, Len:16,
            _Rest/binary>> = Data} -> %% LOCAL Command
            Size = 16 + Len,
            % push the received data back into Sock
            gen_tcp:unrecv(Sock, Data),
            % we need to consume the appropriate amount of data from Sock
            {ok, _PPHdr} = gen_tcp:recv(Sock, Size, 10),
            {ok, Sock};
        {ok, <<ProxyProtoSignature:12/binary, 16#2:4, ?PC_PROXY:4, AddrFamily:4, TransProto:4, Len:16,
            Rest/binary>> = Data} -> %% PROXY Command

            PacketLen = byte_size(Data),
            Size = 16 + Len,

            if
                PacketLen < Size ->
                    {error, too_large_header};
                true ->
                    Result =
                    case AddrFamily of
                        ?AF_INET when Len >= 12, TransProto =:= ?TP_STREAM -> % TCP over IPv4
                            <<SrcAddrBin:32, DstAddrBin:32, SrcPort:16, DstPort:16, _AddiBytes/binary>>
                                = Rest,
                            <<SrcA, SrcB, SrcC, SrcD>> = <<SrcAddrBin:32>>,
                            <<DstA, DstB, DstC, DstD>> = <<DstAddrBin:32>>,
                            ProxySock = #proxy_socket{inet = inet4,
                                socket   = Sock,
                                src_addr = {SrcA, SrcB, SrcC, SrcD},
                                dst_addr = {DstA, DstB, DstC, DstD},
                                src_port = SrcPort,
                                dst_port = DstPort},
                            {ok, ProxySock};
                        ?AF_INET6 when Len >= 36, TransProto =:= ?TP_STREAM -> % TCP over IPv6
                            <<SrcAddrBin:128, DstAddrBin:128, SrcPort:16, DstPort:16, _AddiBytes/binary>>
                                = Rest,
                            <<SrcA:16, SrcB:16, SrcC:16, SrcD:16, SrcE:16, SrcF:16, SrcG:16, SrcH:16>>
                                = <<SrcAddrBin:128>>,
                            <<DstA:16, DstB:16, DstC:16, DstD:16, DstE:16, DstF:16, DstG:16, DstH:16>>
                                = <<DstAddrBin:128>>,
                            ProxySock = #proxy_socket{inet = inet6,
                                socket   = Sock,
                                src_addr = {SrcA, SrcB, SrcC, SrcD, SrcE, SrcF, SrcG, SrcH},
                                dst_addr = {DstA, DstB, DstC, DstD, DstE, DstF, DstG, DstH},
                                src_port = SrcPort,
                                dst_port = DstPort},
                            {ok, ProxySock};
                        _ -> %% unsupported protocols
                            {ok, Sock}
                    end,
                    % push the received data back into Sock
                    gen_tcp:unrecv(Sock, Data),
                    % we need to consume the appropriate amount of data from Sock
                    {ok, _PPHdr} = gen_tcp:recv(Sock, Size, 10),
                    Result
            end;
        {ok, <<ProxyProtoSignature:12/binary, 16#2:4, PROXY:4, _Rest/binary>>} -> %% not a supported command
            {error, {invalid_proto_cmd, PROXY}};
        {ok, MsgInvalidFormat} ->
            {error, {invalid_format, MsgInvalidFormat}};
        {error,timeout} ->
            {error, proxy_proto_timeout};
        {error,Reason} ->
            {error, Reason}
    end.

parse_inet($4) -> inet4;
parse_inet($6) -> inet6.

parse_proxy_info(ProxyInfo) ->
    [SrcAddrBin, DstAddrBin, SrcPortBin, DstPortBin]
        = binary:split(ProxyInfo, [<<" ">>, <<"\r\n">>], [global, trim]),
    {ok, SrcAddr} = inet:parse_address(binary_to_list(SrcAddrBin)),
    {ok, DstAddr} = inet:parse_address(binary_to_list(DstAddrBin)),
    SrcPort = list_to_integer(binary_to_list(SrcPortBin)),
    DstPort = list_to_integer(binary_to_list(DstPortBin)),
    {SrcAddr, DstAddr, SrcPort, DstPort}.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

parse_proxy_info_test() ->
    ?assertEqual({{255,255,255,255}, {255,255,255,255}, 65535, 65535}, parse_proxy_info(<<"255.255.255.255 255.255.255.255 65535 65535\r\n">>)),
    ?assertEqual({{0,0,0,0,0,0,0,1}, {0,0,0,0,0,0,0,1}, 6000, 50000},
                 parse_proxy_info(<<"::1 ::1 6000 50000\r\n">>)).
-endif.

