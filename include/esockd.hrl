%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2013-2017 EMQ Enterprise, Inc. (http://emqtt.io)
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
%%% eSockd Header.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

%% Extract socket from esockd_connection
-define(ESOCK(Sock), {esockd_connection, [Sock, _, _]}).

%%------------------------------------------------------------------------------
%% SSL Socket Wrapper.
%%------------------------------------------------------------------------------

-record(ssl_socket, {tcp :: inet:socket(),
                     ssl :: ssl:sslsocket()}).

-define(IS_SSL(Sock), is_record(Sock, ssl_socket)).

%%------------------------------------------------------------------------------
%% Proxy-Protocol Socket Wrapper
%%------------------------------------------------------------------------------

-type(pp2_additional_ssl_field() :: {pp2_ssl_client,           boolean()}
                                  | {pp2_ssl_client_cert_conn, boolean()}
                                  | {pp2_ssl_client_cert_sess, boolean()}
                                  | {pp2_ssl_verify,  success | failed}
                                  | {pp2_ssl_version, binary()}  % US-ASCII string
                                  | {pp2_ssl_cn,      binary()}  % UTF8-encoded string
                                  | {pp2_ssl_cipher,  binary()}  % US-ASCII string
                                  | {pp2_ssl_sig_alg, binary()}  % US-ASCII string
                                  | {pp2_ssl_key_alg, binary()}).% US-ASCII string

-type(pp2_additional_field() :: {pp2_alpn,      binary()}  % byte sequence
                              | {pp2_authority, binary()}  % UTF8-encoded string
                              | {pp2_crc32c,    integer()} % 32-bit number
                              | {pp2_netns,     binary()}  % US-ASCII string
                              | {pp2_ssl,       list(pp2_additional_ssl_field())}).

-record(proxy_socket, {inet     :: inet4 | inet6,
                       socket   :: inet:socket() | #ssl_socket{},
                       src_addr :: inet:ip_address(),
                       dst_addr :: inet:ip_address(),
                       src_port :: inet:port_number(),
                       dst_port :: inet:port_number(),
                       %% Proxy protocol v2 addtional fields
                       pp2_additional_info = [] :: list(pp2_additional_field())}).

-define(IS_PROXY(Sock), is_record(Sock, proxy_socket)).

