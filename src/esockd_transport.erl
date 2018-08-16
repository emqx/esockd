%% Copyright (c) 2018 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(esockd_transport).

-include("esockd.hrl").

-export([type/1, is_ssl/1]).

-export([listen/2, send/2, async_send/2, recv/2, recv/3, async_recv/2, async_recv/3,
         controlling_process/2, close/1, fast_close/1]).

-export([getopts/2, setopts/2, getstat/2]).

-export([sockname/1, peername/1, shutdown/2]).

%% Peercert
-export([peercert/1, peer_cert_subject/1, peer_cert_common_name/1]).

-export([gc/1]).

%% tcp -> sslsocket
-export([ssl_upgrade_fun/1]).

-type(sock() :: inet:socket() | esockd:ssl_socket() | esockd:proxy_socket()).

-define(SSL_CLOSE_TIMEOUT, 5000).

-define(SSL_HANDSHAKE_TIMEOUT, 15000).

%%-compile({no_auto_import,[port_command/2]}).

%% @doc socket type: tcp | ssl | proxy
-spec(type(sock()) -> tcp | ssl | proxy).
type(Sock) when is_port(Sock) ->
    tcp;
type(#ssl_socket{ssl = _SslSock})  ->
    ssl;
type(#proxy_socket{}) ->
    proxy.

-spec(is_ssl(sock()) -> boolean()).
is_ssl(Sock) when is_port(Sock) ->
    false;
is_ssl(#ssl_socket{})  ->
    true;
is_ssl(#proxy_socket{socket = Sock}) ->
    is_ssl(Sock).

%% @doc Listen
-spec(listen(Port, SockOpts) -> {ok, Sock} | {error, Reason} when
    Port     :: inet:port_number(),
    SockOpts :: [gen_tcp:listen_option()],
    Sock     :: inet:socket(),
    Reason   :: system_limit | inet:posix()).
listen(Port, SockOpts) ->
    gen_tcp:listen(Port, SockOpts).

%% @doc Set Controlling Process of Socket
-spec(controlling_process(Sock, NewOwener) -> ok | {error, Reason} when
    Sock      :: sock(),
    NewOwener :: pid(),
    Reason    :: closed | not_owner | badarg | inet:posix()).
controlling_process(Sock, NewOwner) when is_port(Sock) ->
    gen_tcp:controlling_process(Sock, NewOwner);
controlling_process(#ssl_socket{ssl = SslSock}, NewOwner) ->
    ssl:controlling_process(SslSock, NewOwner);
controlling_process(#proxy_socket{socket = Sock}, NewOwner) ->
    controlling_process(Sock, NewOwner).

-spec(close(sock()) -> ok | {error, term()}).
close(Sock) when is_port(Sock) ->
    gen_tcp:close(Sock);
close(#ssl_socket{ssl = SslSock}) ->
    ssl:close(SslSock);
close(#proxy_socket{socket = Sock}) ->
    close(Sock).

-spec(fast_close(sock()) -> ok).
fast_close(Sock) when is_port(Sock) ->
    catch port_close(Sock), ok;
fast_close(#ssl_socket{tcp = Sock, ssl = SslSock}) ->
    {Pid, MRef} = spawn_monitor(fun() -> ssl:close(SslSock) end),
    erlang:send_after(?SSL_CLOSE_TIMEOUT, self(), {Pid, ssl_close_timeout}),
    receive
        {Pid, ssl_close_timeout} ->
            erlang:demonitor(MRef, [flush]),
            exit(Pid, kill);
        {'DOWN', MRef, process, Pid, _Reason} ->
            ok
    end,
    catch port_close(Sock), ok;
fast_close(#proxy_socket{socket = Sock}) ->
    fast_close(Sock).

%% @doc Send data.
-spec(send(Sock :: sock(), Data :: iodata()) -> ok | {error, Reason} when
    Reason :: closed | timeout | inet:posix()).
send(Sock, Data) when is_port(Sock) ->
    gen_tcp:send(Sock, Data);
send(#ssl_socket{ssl = SslSock}, Data) ->
    ssl:send(SslSock, Data);
send(#proxy_socket{socket = Sock}, Data) ->
    send(Sock, Data).

%% @doc Port command to write data.
-spec(async_send(Sock :: sock(), Data :: iodata()) -> ok | {error, Reason} when
    Reason :: close | timeout | inet:posix()).
async_send(Sock, Data) when is_port(Sock) ->
    case erlang:port_command(Sock, Data, [nosuspend]) of
        true  -> ok;
        false -> {error, timeout} %%TODO: tcp window full?
    end;
async_send(Sock = #ssl_socket{ssl = SslSock}, Data) ->
    case ssl:send(SslSock, Data) of
        ok -> self() ! {inet_reply, Sock, ok}, ok;
        {error, Reason} -> {error, Reason}
    end;
async_send(#proxy_socket{socket = Sock}, Data) ->
    async_send(Sock, Data).

%% @doc Receive data.
-spec(recv(Sock, Length) -> {ok, Data} | {error, Reason} when
    Sock   :: sock(),
    Length :: non_neg_integer(),
    Data   :: string() | binary(),
    Reason :: closed | inet:posix()).
recv(Sock, Length) when is_port(Sock) ->
    gen_tcp:recv(Sock, Length);
recv(#ssl_socket{ssl = SslSock}, Length) ->
    ssl:recv(SslSock, Length);
recv(#proxy_socket{socket = Sock}, Length) ->
    recv(Sock, Length).

-spec(recv(Sock, Length, Timout) -> {ok, Data} | {error, Reason} when
    Sock   :: sock(),
    Length :: non_neg_integer(),
    Timout :: timeout(),
    Data   :: string() | binary(),
    Reason :: closed | inet:posix()).
recv(Sock, Length, Timeout) when is_port(Sock) ->
    gen_tcp:recv(Sock, Length, Timeout);
recv(#ssl_socket{ssl = SslSock}, Length, Timeout)  ->
    ssl:recv(SslSock, Length, Timeout);
recv(#proxy_socket{socket = Sock}, Length, Timeout) ->
    recv(Sock, Length, Timeout).

%% @doc Async Receive data.
-spec(async_recv(Sock, Length) -> {ok, Ref} when
    Sock   :: sock(),
    Length :: non_neg_integer(),
    Ref    :: reference()).
async_recv(Sock, Length) ->
    async_recv(Sock, Length, infinity).

-spec(async_recv(Sock, Length, Timeout) -> {ok, Ref} when
    Sock    :: sock(),
    Length  :: non_neg_integer(),
    Timeout :: non_neg_integer() | infinity,
    Ref     :: reference()).
async_recv(Sock = #ssl_socket{ssl = SslSock}, Length, Timeout) ->
    Self = self(),
    Ref = make_ref(),
    spawn(fun() -> Self ! {inet_async, Sock, Ref, ssl:recv(SslSock, Length, Timeout)} end),
    {ok, Ref};
async_recv(Sock, Length, infinity) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, -1);
async_recv(Sock, Length, Timeout) when is_port(Sock) ->
    prim_inet:async_recv(Sock, Length, Timeout);
async_recv(#proxy_socket{socket = Sock}, Length, Timeout) ->
    async_recv(Sock, Length, Timeout).

%% @doc Get socket options.
-spec(getopts(sock(), [inet:socket_getopt()]) ->
    {ok, [inet:socket_setopt()]} | {error, inet:posix()}).
getopts(Sock, OptionNames) when is_port(Sock) ->
    inet:getopts(Sock, OptionNames);
getopts(#ssl_socket{ssl = SslSock}, OptionNames) ->
    ssl:getopts(SslSock, OptionNames);
getopts(#proxy_socket{socket = Sock}, OptionNames) ->
    getopts(Sock, OptionNames).

%% @doc Set socket options
-spec(setopts(sock(), [inet:socket_setopt()]) -> ok | {error, inet:posix()}).
setopts(Sock, Options) when is_port(Sock) ->
    inet:setopts(Sock, Options);
setopts(#ssl_socket{ssl = SslSock}, Options) ->
    ssl:setopts(SslSock, Options);
setopts(#proxy_socket{socket = Socket}, Options) ->
    setopts(Socket, Options).

%% @doc Get socket stats
-spec(getstat(sock(), [inet:stat_option()]) -> {ok, [{inet:stat_option(), integer()}]} | {error, inet:posix()}).
getstat(Sock, Stats) when is_port(Sock) ->
    inet:getstat(Sock, Stats);
getstat(#ssl_socket{tcp = Sock}, Stats) ->
    inet:getstat(Sock, Stats);
getstat(#proxy_socket{socket = Sock}, Stats) ->
    getstat(Sock, Stats).

%% @doc Sock name
-spec(sockname(sock()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, inet:posix()}).
sockname(Sock) when is_port(Sock) ->
    inet:sockname(Sock);
sockname(#ssl_socket{ssl = SslSock}) ->
    ssl:sockname(SslSock);
sockname(#proxy_socket{dst_addr = DstAddr, dst_port = DstPort}) ->
    {ok, {DstAddr, DstPort}}.

%% @doc Socket peername
-spec(peername(sock()) -> {ok, {inet:ip_address(), inet:port_number()}} | {error, inet:posix()}).
peername(Sock) when is_port(Sock) ->
    inet:peername(Sock);
peername(#ssl_socket{ssl = SslSock}) ->
    ssl:peername(SslSock);
peername(#proxy_socket{src_addr = SrcAddr, src_port = SrcPort}) ->
    {ok, {SrcAddr, SrcPort}}.

%% @doc Socket peercert
-spec(peercert(sock()) -> nossl | binary() | list(pp2_additional_ssl_field()) |
                          {error, term()}).
peercert(Sock) when is_port(Sock) ->
    nossl;
peercert(#ssl_socket{ssl = SslSock}) ->
    case ssl:peercert(SslSock) of
        {ok, Cert} -> Cert;
        Error -> Error
    end;
peercert(#proxy_socket{pp2_additional_info = AdditionalInfo}) ->
    proplists:get_value(pp2_ssl, AdditionalInfo, []).

%% @doc Peercert subject
-spec(peer_cert_subject(sock()) -> undefined | binary()).
peer_cert_subject(Sock) when is_port(Sock) ->
    undefined;
peer_cert_subject(#ssl_socket{ssl = SslSock}) ->
    case ssl:peercert(SslSock) of
        {ok, Cert} ->
            esockd_ssl:peer_cert_subject(Cert);
        _Error -> undefined
    end;
peer_cert_subject(Sock = #proxy_socket{}) ->
    %% Common Name? Haproxy PP2 will not pass subject.
    peer_cert_common_name(Sock).

%% @doc Peercert common name
-spec(peer_cert_common_name(sock()) -> undefined | binary()).
peer_cert_common_name(Sock) when is_port(Sock) ->
    undefined;
peer_cert_common_name(#ssl_socket{ssl = SslSock}) ->
    case ssl:peercert(SslSock) of
        {ok, Cert} ->
            esockd_ssl:peer_cert_common_name(Cert);
        _Error -> undefined
    end;
peer_cert_common_name(#proxy_socket{pp2_additional_info = AdditionalInfo}) ->
    proplists:get_value(pp2_ssl_cn,
                        proplists:get_value(pp2_ssl, AdditionalInfo, [])).

%% @doc Shutdown socket
-spec(shutdown(sock(), How) -> ok | {error, inet:posix()} when
    How :: read | write | read_write).
shutdown(Sock, How) when is_port(Sock) ->
    gen_tcp:shutdown(Sock, How);
shutdown(#ssl_socket{ssl = SslSock}, How) ->
    ssl:shutdown(SslSock, How);
shutdown(#proxy_socket{socket = Sock}, How) ->
    shutdown(Sock, How).

%% @doc Function that upgrade socket to sslsocket
ssl_upgrade_fun(undefined) ->
    fun(Sock) when is_port(Sock) -> {ok, Sock} end;

ssl_upgrade_fun(SslOpts) ->
    Timeout = proplists:get_value(handshake_timeout, SslOpts, ?SSL_HANDSHAKE_TIMEOUT),
    SslOpts1 = proplists:delete(handshake_timeout, SslOpts),
    fun(Sock) when is_port(Sock) ->
        case catch ssl:ssl_accept(Sock, SslOpts1, Timeout) of
            {ok, SslSock} ->
                {ok, #ssl_socket{tcp = Sock, ssl = SslSock}};
            {error, Reason} when Reason == closed; Reason == timeout ->
                fast_close(Sock),
                {error, Reason};
            %%FIXME: ignore tls_alert?
            {error, {tls_alert, _}} ->
                fast_close(Sock),
                {error, tls_alert};
            {error, Reason} ->
                fast_close(Sock),
                {error, {ssl_error, Reason}};
            {'EXIT', Reason} -> 
                fast_close(Sock),
                {error, {ssl_failure, Reason}}
        end
    end.

gc(Sock) when is_port(Sock) ->
    ok;
%% Defined in ssl/src/ssl_api.hrl:
%% -record(sslsocket, {fd = nil, pid = nil}).
gc(#ssl_socket{ssl = {sslsocket, _, Pid}}) when is_pid(Pid) ->
    erlang:garbage_collect(Pid);
gc(#proxy_socket{socket = Sock}) ->
    gc(Sock);
gc(_Sock) ->
    ok.

