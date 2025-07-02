%%--------------------------------------------------------------------
%% Copyright (c) 2019 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-ifndef(ESOCKD_HRL).
-define(ESOCKD_HRL, true).

%%--------------------------------------------------------------------
%% Default Timeout
%%--------------------------------------------------------------------

-define(SSL_CLOSE_TIMEOUT, 5000).
-define(SSL_HANDSHAKE_TIMEOUT, 15000).
-define(PROXY_RECV_TIMEOUT, 5000).

%%--------------------------------------------------------------------
%% SSL socket wrapper
%%--------------------------------------------------------------------

-record(ssl_socket, {tcp :: inet:socket() | undefined, %% dtls
                     ssl :: ssl:sslsocket()}).

-define(IS_SSL(Sock), is_record(Sock, ssl_socket)).

%%--------------------------------------------------------------------
%% Proxy-Protocol Socket Wrapper
%%--------------------------------------------------------------------

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

-record(proxy_socket, {inet     :: inet4 | inet6 | 'unix' | 'unspec',
                       socket   :: inet:socket() | #ssl_socket{} | socket:socket(),
                       src_addr :: inet:ip_address() | undefined,
                       dst_addr :: inet:ip_address() | undefined,
                       src_port :: inet:port_number() | undefined,
                       dst_port :: inet:port_number() | undefined,
                       %% Proxy protocol v2 addtional fields
                       pp2_additional_info = [] :: list(pp2_additional_field())}).

-define(IS_PROXY(Sock), is_record(Sock, proxy_socket)).

-if(?OTP_RELEASE >= 26).
-type ssl_option() :: ssl:tls_option().
-else.
-type ssl_option() :: ssl:ssl_option().
-endif. % OTP_RELEASE


-define(ERROR_MAXLIMIT, maxlimit).

-define(ARG_ACCEPTED, accepted).
-define(ARG_CLOSED_SYS_LIMIT, closed_sys_limit).
-define(ARG_CLOSED_MAX_LIMIT, closed_max_limit).
-define(ARG_CLOSED_OVERLOADED, closed_overloaded).
-define(ARG_CLOSED_RATE_LIMITED, closed_rate_limited).
-define(ARG_CLOSED_OTHER_REASONS, closed_other_reasons).

-define(ACCEPT_RESULT_GROUPS,
        [
            ?ARG_ACCEPTED,
            ?ARG_CLOSED_SYS_LIMIT,
            ?ARG_CLOSED_MAX_LIMIT,
            ?ARG_CLOSED_OVERLOADED,
            ?ARG_CLOSED_RATE_LIMITED,
            ?ARG_CLOSED_OTHER_REASONS
        ]).

-endif. % ESOCKD_HRL
