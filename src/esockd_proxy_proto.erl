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

-export([recv/2]).

%% Protocol Command
-define(LOCAL, 16#0).
-define(PROXY, 16#1).

%% Address families
-define(UNSPEC, 16#0).
-define(INET,   16#1).
-define(INET6,  16#2).
-define(UNIX,   16#3).

-define(STREAM, 16#1).
-define(DGRAM,  16#2).

-define(SPACE, 16#20).

-define(TIMEOUT, 5000).

%% Protocol signature:
%% 16#0D,16#0A,16#00,16#0D,16#0A,16#51,16#55,16#49,16#54,16#0A
-define(SIG, "\r\n\0\r\nQUIT\n").

-spec(recv(inet:socket() | #ssl_socket{}, list(tuple())) ->
      {ok, #proxy_socket{}} | {error, any()}).
recv(Sock, Opts) ->
    Timeout = proplists:get_value(proxy_protocol_timeout, Opts, ?TIMEOUT),
    {ok, OriginOpts} = esockd_transport:getopts(Sock, [active, packet]),
    ok = esockd_transport:setopts(Sock, [{active, once}, {packet, line}]),
    receive
        %% V1 TCP
        {_, _Sock, <<"PROXY TCP", Proto, ?SPACE, ProxyInfo/binary>>} ->
            esockd_transport:setopts(Sock, OriginOpts),
            parse_v1(ProxyInfo, #proxy_socket{inet = inet_family(Proto), socket = Sock});
        %% V1 Unknown
        {_, _Sock, <<"PROXY UNKNOWN", _ProxyInfo/binary>>} ->
            esockd_transport:setopts(Sock, OriginOpts),
            {ok, Sock};
        %% V2 TCP
        {_, _Sock, <<"\r\n">>} ->
            esockd_transport:setopts(Sock, [{active, false}, {packet, raw}]),
            {ok, Header} = esockd_transport:recv(Sock, 14, 1000),
            <<?SIG, 2:4, Cmd:4, AF:4, Trans:4, Len:16>> = Header,
            {ok, ProxyInfo} = esockd_transport:recv(Sock, Len, 1000),
            esockd_transport:setopts(Sock, OriginOpts),
            %%io:format("ProxyInfo V2: ~p~n", [ProxyInfo]),
            parse_v2(Cmd, Trans, ProxyInfo, #proxy_socket{inet = inet_family(AF), socket = Sock});
        {_, _Sock, ProxyInfo} ->
            esockd_transport:fast_close(Sock),
            {error, {invalid_proxy_info, ProxyInfo}}
    after
        Timeout ->
            esockd_transport:fast_close(Sock),
            {error, proxy_proto_timeout}
    end.

parse_v1(ProxyInfo, ProxySock) ->
    [SrcAddrBin, DstAddrBin, SrcPortBin, DstPortBin]
        = binary:split(ProxyInfo, [<<" ">>, <<"\r\n">>], [global, trim]),
    {ok, SrcAddr} = inet:parse_address(binary_to_list(SrcAddrBin)),
    {ok, DstAddr} = inet:parse_address(binary_to_list(DstAddrBin)),
    SrcPort = list_to_integer(binary_to_list(SrcPortBin)),
    DstPort = list_to_integer(binary_to_list(DstPortBin)),
    {ok, ProxySock#proxy_socket{src_addr = SrcAddr, dst_addr = DstAddr,
                                src_port = SrcPort, dst_port = DstPort}}.

parse_v2(?LOCAL, _Trans, _ProxyInfo, #proxy_socket{socket = Sock}) ->
    {ok, Sock};

parse_v2(?PROXY, ?STREAM, ProxyInfo, ProxySock = #proxy_socket{inet = inet4}) ->
    <<A:8, B:8, C:8, D:8, W:8, X:8, Y:8, Z:8,
      SrcPort:16, DstPort:16, _/binary>> = ProxyInfo,
    {ok, ProxySock#proxy_socket{src_addr = {A, B, C, D}, src_port = SrcPort,
                                dst_addr = {W, X, Y, Z}, dst_port = DstPort}};

parse_v2(?PROXY, ?STREAM, ProxyInfo, ProxySock = #proxy_socket{inet = inet6}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16,
      R:16, S:16, T:16, U:16, V:16, W:16, X:16, Y:16,
      SrcPort:16, DstPort:16, _/binary>> = ProxyInfo,
    {ok, ProxySock#proxy_socket{src_addr = {A, B, C, D, E, F, G, H}, src_port = SrcPort,
                                dst_addr = {R, S, T, U, V, W, X, Y}, dst_port = DstPort}};

parse_v2(_, _, _, #proxy_socket{socket = Sock}) ->
    esockd_transport:fast_close(Sock),
    {error, unsupported_proto_v2}.

%% V1
inet_family($4) -> inet4;
inet_family($6) -> inet6;
%% V2
inet_family(?UNSPEC) -> unspec;
inet_family(?INET)   -> inet4;
inet_family(?INET6)  -> inet6;
inet_family(?UNIX)   -> unix.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

parse_proxy_info_test() ->
    ?assertEqual({{255,255,255,255}, {255,255,255,255}, 65535, 65535}, parse_proxy_v1(<<"255.255.255.255 255.255.255.255 65535 65535\r\n">>)),
    ?assertEqual({{0,0,0,0,0,0,0,1}, {0,0,0,0,0,0,0,1}, 6000, 50000},
                 parse_proxy_v2(<<"::1 ::1 6000 50000\r\n">>)).
-endif.

