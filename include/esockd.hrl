%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2014-2017 Feng Lee <feng@emqtt.io>. All Rights Reserved.
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

-record(proxy_socket, {inet     :: inet4 | inet6,
                       socket   :: inet:socket() | #ssl_socket{},
                       src_addr :: inet:ip_address(),
                       dst_addr :: inet:ip_address(),
                       src_port :: inet:port_number(),
                       dst_port :: inet:port_number()}).

