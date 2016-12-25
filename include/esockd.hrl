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
%%% eSockd Header.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

%% Extract socket from esockd_connection
-define(ESOCK(Sock), {esockd_connection, [Sock, _, _]}).

%%------------------------------------------------------------------------------
%% SSL Sock Wrapper.
%%------------------------------------------------------------------------------
-record(ssl_socket, {tcp :: inet:socket(),
                     ssl :: ssl:sslsocket()}).

-define(IS_SSL(Sock), is_record(Sock, ssl_socket)).

%%------------------------------------------------------------------------------
%% Proxy-Protocol Sock Wrapper
%%------------------------------------------------------------------------------

-record(proxy_socket, {inet     :: inet4 | inet6,
                       socket   :: inet:socket() | #ssl_socket{},
                       src_addr :: inet:ip_address(),
                       dst_addr :: inet:ip_address(),
                       src_port :: inet:port_number(),
                       dst_port :: inet:port_number()}).

%%------------------------------------------------------------------------------
%% Macro definitions for Proxy-Protocol V2
%%------------------------------------------------------------------------------
%% Protocol signature
-define(PROXY_PROTO_V2_SIG, <<16#0D, 16#0A, 16#0D, 16#0A, 16#00, 16#0D, 16#0A, 16#51, 16#55, 16#49, 16#54, 16#0A>>).

%% Protocol Command
-define(PC_LOCAL, 16#0).
-define(PC_PROXY, 16#1).

%% Address families
-define(AF_UNSPEC, 16#0).
-define(AF_INET, 16#1).
-define(AF_INET6, 16#2).
-define(AF_UNIX, 16#3).

%% Transport protocols
-define(TP_UNSPEC, 16#0).
-define(TP_STREAM, 16#1).
-define(TP_DGRAM, 16#2).
