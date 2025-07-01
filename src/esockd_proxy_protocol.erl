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

%% @doc [Proxy Protocol](https://www.haproxy.org/download/1.8/doc/proxy-protocol.txt)
-module(esockd_proxy_protocol).

-include("esockd.hrl").

-export([recv/3]).
-export([get_proxy_attrs/1]).

-ifdef(TEST).
-export([parse_v1/2, parse_v2/4, parse_pp2_tlv/2, parse_pp2_ssl/1]).
-endif.

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

-define(MAX_TIMEOUT, 17000).

%% Proxy Protocol Additional Fields
-define(PP2_TYPE_ALPN,           16#01).
-define(PP2_TYPE_AUTHORITY,      16#02).
-define(PP2_TYPE_CRC32C,         16#03).
-define(PP2_TYPE_NOOP,           16#04).
-define(PP2_TYPE_SSL,            16#20).
-define(PP2_SUBTYPE_SSL_VERSION, 16#21).
-define(PP2_SUBTYPE_SSL_CN,      16#22).
-define(PP2_SUBTYPE_SSL_CIPHER,  16#23).
-define(PP2_SUBTYPE_SSL_SIG_ALG, 16#24).
-define(PP2_SUBTYPE_SSL_KEY_ALG, 16#25).
-define(PP2_TYPE_NETNS,          16#30).

%% Protocol signature:
%% 16#0D,16#0A,16#00,16#0D,16#0A,16#51,16#55,16#49,16#54,16#0A
-define(SIG, "\r\n\0\r\nQUIT\n").

-type maybe_proxy_socket() :: #proxy_socket{} | inet:socket() | #ssl_socket{}.

-spec recv
    (esockd_socket, socket:socket(), timeout()) ->
        {ok, socket:socket()} | {error, term()};
    (module(), inet:socket() | #ssl_socket{}, timeout()) ->
        {ok, maybe_proxy_socket()} | {error, term()}.
recv(esockd_socket, Sock, Timeout) ->
    recv_esockd_socket(Sock, Timeout);
recv(Transport, Sock, Timeout) ->
    {ok, OriginalOpts} = Transport:getopts(Sock, [mode, active, packet]),
    case do_recv(Transport, Sock, Timeout) of
        {ok, _} = OkResult ->
            Transport:setopts(Sock, OriginalOpts),
            OkResult;
        {error, _} = Error ->
            Error
    end.

do_recv(Transport, Sock, Timeout) ->
    Deadline = deadline(Timeout),
    ok = Transport:setopts(Sock, [binary, {active, once}, {packet, line}]),
    receive
        %% V1 TCP
        {_, _Sock, <<"PROXY TCP", Proto, ?SPACE, ProxyInfo/binary>>} ->
            parse_v1(ProxyInfo, #proxy_socket{inet = inet_family(Proto), socket = Sock});
        %% V1 Unknown
        {_, _Sock, <<"PROXY UNKNOWN", _ProxyInfo/binary>>} ->
            {ok, Sock};
        %% V2 TCP
        {_, _Sock, <<"\r\n">>} ->
            Transport:setopts(Sock, [{active, false}, {packet, raw}]),
            recv_v2(Transport, Sock, Deadline);
        {tcp_error, _Sock, Reason} ->
            {error, {recv_proxy_info_error, Reason}};
        {tcp_closed, _Sock} ->
            %% socket closed before any data is received
            %% return an atom here to avoid error level logging
            {error, proxy_proto_close};
        {_, _Sock, ProxyInfo} ->
            {error, {invalid_proxy_info, ProxyInfo}}
    after
        Timeout ->
            {error, proxy_proto_timeout}
    end.

recv_esockd_socket(Sock, Timeout) ->
    Deadline = deadline(Timeout),
    case socket:recv(Sock, 2, [], Timeout) of
        {ok, <<"\r\n">>} ->
            recv_v2_esockd_socket(Sock, Deadline);
        {ok, <<"PR">>} ->
            recv_v1_esockd_socket(Sock, Deadline);
        {ok, Header} ->
            {error, {invalid_proxy_info, Header}};
        {error, Reason} ->
            map_tcpsocket_error(Reason)
    end.

recv_v1_esockd_socket(Sock, Deadline) ->
    case socket_recvline(Sock, _MaxLine = 108, Deadline) of
        %% NOTE: "PR" was already received.
        {ok, <<"OXY TCP", Proto, ?SPACE, ProxyInfo/binary>>} ->
            {ok, ProxySock} = parse_v1(ProxyInfo,
                                       #proxy_socket{inet = inet_family(Proto), socket = Sock}),
            ok = set_socket_meta(ProxySock),
            {ok, Sock};
        {ok, <<"OXY UNKNOWN", _ProxyInfo/binary>>} ->
            {ok, Sock};
        {ok, Header} ->
            {error, {invalid_proxy_info, <<"PR", Header/binary>>}};
        {error, Reason} ->
            map_tcpsocket_error(Reason)
    end.

recv_v2_esockd_socket(Sock, Deadline) ->
    case recv_v2(socket, Sock, Deadline) of
        {ok, ProxySock} ->
            ok = set_socket_meta(ProxySock),
            {ok, Sock};
        {error, Reason} ->
            {error, Reason}
    end.

socket_recvline(Sock, MaxLine, Deadline) ->
    case socket:recv(Sock, 0, [peek], timeout_left(Deadline)) of
        {ok, Bytes} ->
            MatchOpts = case byte_size(Bytes) of
                N when N > MaxLine -> [{scope, {0, MaxLine}}];
                _                  -> []
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
map_tcpsocket_error({Reason, _}) ->
    {error, {recv_proxy_info_error, Reason}};
map_tcpsocket_error(Reason) ->
    {error, {recv_proxy_info_error, Reason}}.

set_socket_meta(ProxySocket = #proxy_socket{socket = Sock}) ->
    socket:setopt(Sock, {otp, meta}, get_proxy_attrs(ProxySocket)).

recv_v2(Transport, Sock, Deadline) ->
    with_remaining_timeout(Deadline, fun(HeaderTimeout) ->
        case Transport:recv(Sock, 14, HeaderTimeout) of
            {ok, <<?SIG, 2:4, Cmd:4, AF:4, Trans:4, Len:16>>} ->
                with_remaining_timeout(Deadline, fun(ProxyInfoTimeout) ->
                    case Transport:recv(Sock, Len, ProxyInfoTimeout) of
                        {ok, ProxyInfo} ->
                            parse_v2(Cmd, Trans, ProxyInfo, #proxy_socket{inet = inet_family(AF), socket = Sock});
                        {error, closed} ->
                            {error, proxy_proto_close};
                        {error, Reason} ->
                            {error, {recv_proxy_info_error, Reason}}
                    end
                end);
            {ok, UnknownHeader} ->
                {error, {invalid_proxy_info, UnknownHeader}};
            {error, closed} ->
                {error, proxy_proto_close};
            {error, Reason} ->
                {error, {recv_proxy_info_error, Reason}}
        end
    end).

mk_proxy_attrs(#proxy_socket{inet = Protocol,
                           src_addr = SrcAddr, dst_addr = DstAddr,
                           src_port = SrcPort, dst_port = DstPort,
                           pp2_additional_info = PP2Info}) ->
    #{proxy_protocol => Protocol,
      proxy_src_addr => SrcAddr, proxy_dst_addr => DstAddr,
      proxy_src_port => SrcPort, proxy_dst_port => DstPort,
      proxy_pp2_info => PP2Info}.

-spec get_proxy_attrs(maybe_proxy_socket() | socket:socket()) -> map().
get_proxy_attrs(ProxySocket = #proxy_socket{}) ->
    mk_proxy_attrs(ProxySocket);
get_proxy_attrs(Socket) when element(1, Socket) =:= '$socket' ->
    case socket:getopt(Socket, {otp, meta}) of
        {ok, Meta = #{}} ->
            Meta;
        _Otherwise ->
            #{}
    end;
get_proxy_attrs(_Socket) ->
    #{}.

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
      SrcPort:16, DstPort:16, AdditionalBytes/binary>> = ProxyInfo,
    parse_pp2_additional(AdditionalBytes, ProxySock#proxy_socket{
        src_addr = {A, B, C, D}, src_port = SrcPort,
        dst_addr = {W, X, Y, Z}, dst_port = DstPort});

parse_v2(?PROXY, ?STREAM, ProxyInfo, ProxySock = #proxy_socket{inet = inet6}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16,
      R:16, S:16, T:16, U:16, V:16, W:16, X:16, Y:16,
      SrcPort:16, DstPort:16, AdditionalBytes/binary>> = ProxyInfo,
    parse_pp2_additional(AdditionalBytes, ProxySock#proxy_socket{
        src_addr = {A, B, C, D, E, F, G, H}, src_port = SrcPort,
        dst_addr = {R, S, T, U, V, W, X, Y}, dst_port = DstPort});

parse_v2(_, _, _, #proxy_socket{socket = _Sock}) ->
    {error, unsupported_proto_v2}.

parse_pp2_additional(<<>>, ProxySock) ->
    {ok, ProxySock};
parse_pp2_additional(Bytes, ProxySock) when is_binary(Bytes) ->
    IgnoreGuard = fun(?PP2_TYPE_NOOP) -> false; (_Type) -> true end,
    AdditionalInfo = parse_pp2_tlv(fun pp2_additional_field/1, Bytes, IgnoreGuard),
    {ok, ProxySock#proxy_socket{pp2_additional_info = AdditionalInfo}}.

parse_pp2_tlv(Fun, Bytes) ->
    parse_pp2_tlv(Fun, Bytes, fun(_Any) -> true end).
parse_pp2_tlv(Fun, Bytes, Guard) ->
    [Fun({Type, Val}) || <<Type:8, Len:16, Val:Len/binary>> <= Bytes, Guard(Type)].

pp2_additional_field({?PP2_TYPE_ALPN, PP2_ALPN}) ->
    {pp2_alpn, PP2_ALPN};
pp2_additional_field({?PP2_TYPE_AUTHORITY, PP2_AUTHORITY}) ->
    {pp2_authority, PP2_AUTHORITY};
pp2_additional_field({?PP2_TYPE_CRC32C, PP2_CRC32C}) ->
    {pp2_crc32c, PP2_CRC32C};
pp2_additional_field({?PP2_TYPE_NETNS, PP2_NETNS}) ->
    {pp2_netns, PP2_NETNS};
pp2_additional_field({?PP2_TYPE_SSL, PP2_SSL}) ->
    {pp2_ssl, parse_pp2_ssl(PP2_SSL)};
pp2_additional_field({Field, Value}) ->
    {{pp2_raw, Field}, Value}.

parse_pp2_ssl(<<_Unused:5, PP2_CLIENT_CERT_SESS:1, PP2_CLIENT_CERT_CONN:1, PP2_CLIENT_SSL:1,
                PP2_SSL_VERIFY:32, SubFields/bitstring>>) ->
    [
     %% The PP2_CLIENT_SSL flag indicates that the client connected over SSL/TLS. When
     %% this field is present, the US-ASCII string representation of the TLS version is
     %% appended at the end of the field in the TLV format using the type PP2_SUBTYPE_SSL_VERSION.
     {pp2_ssl_client, bool(PP2_CLIENT_SSL)},

     %% PP2_CLIENT_CERT_CONN indicates that the client provided a certificate over the
     %% current connection.
     {pp2_ssl_client_cert_conn, bool(PP2_CLIENT_CERT_CONN)},

     %% PP2_CLIENT_CERT_SESS indicates that the client provided a
     %% certificate at least once over the TLS session this connection belongs to.
     {pp2_ssl_client_cert_sess, bool(PP2_CLIENT_CERT_SESS)},

     %% The <verify> field will be zero if the client presented a certificate
     %% and it was successfully verified, and non-zero otherwise.
     {pp2_ssl_verify, ssl_certificate_verified(PP2_SSL_VERIFY)}

     | parse_pp2_tlv(fun pp2_additional_ssl_field/1, SubFields)
    ].

pp2_additional_ssl_field({?PP2_SUBTYPE_SSL_VERSION, PP2_SSL_VERSION}) ->
    {pp2_ssl_version, PP2_SSL_VERSION};

%% In all cases, the string representation (in UTF8) of the Common Name field
%% (OID: 2.5.4.3) of the client certificate's Distinguished Name, is appended
%% using the TLV format and the type PP2_SUBTYPE_SSL_CN. E.g. "example.com".
pp2_additional_ssl_field({?PP2_SUBTYPE_SSL_CN, PP2_SSL_CN}) ->
    {pp2_ssl_cn, PP2_SSL_CN};
pp2_additional_ssl_field({?PP2_SUBTYPE_SSL_CIPHER, PP2_SSL_CIPHER}) ->
    {pp2_ssl_cipher, PP2_SSL_CIPHER};
pp2_additional_ssl_field({?PP2_SUBTYPE_SSL_SIG_ALG, PP2_SSL_SIG_ALG}) ->
    {pp2_ssl_sig_alg, PP2_SSL_SIG_ALG};
pp2_additional_ssl_field({?PP2_SUBTYPE_SSL_KEY_ALG, PP2_SSL_KEY_ALG}) ->
    {pp2_ssl_key_alg, PP2_SSL_KEY_ALG};
pp2_additional_ssl_field({Field, Val}) ->
    {{pp2_ssl_raw, Field}, Val}.

ssl_certificate_verified(0) -> success;
ssl_certificate_verified(_) -> failed.

%% V1
inet_family($4) -> inet4;
inet_family($6) -> inet6;

%% V2
inet_family(?UNSPEC) -> unspec;
inet_family(?INET)   -> inet4;
inet_family(?INET6)  -> inet6;
inet_family(?UNIX)   -> unix.

bool(1) -> true;
bool(_) -> false.

maybe_limit_timeout(infinity) -> ?MAX_TIMEOUT;
maybe_limit_timeout(Timeout) when is_integer(Timeout) andalso Timeout > ?MAX_TIMEOUT ->
    ?MAX_TIMEOUT;
maybe_limit_timeout(Timeout) when is_integer(Timeout) andalso Timeout > 0 ->
    Timeout.

deadline(Timeout) ->
    erlang:monotonic_time(millisecond) + maybe_limit_timeout(Timeout).

timeout_left(Deadline) ->
    Deadline - erlang:monotonic_time(millisecond).

with_remaining_timeout(Timer, Fun) ->
    case timeout_left(Timer) of
        Timeout when Timeout > 0 ->
            Fun(Timeout);
        _ ->
            {error, proxy_proto_timeout}
    end.
