%%%===================================================================
%%% Copyright (c) 2013-2018 EMQ Inc. All rights reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%===================================================================

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

