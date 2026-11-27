%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% @doc The `ip_check' listener callback.
%%
%% Without proxy protocol, the acceptor calls `check/3' with the TCP peer
%% address right after accept.
%%
%% With proxy protocol, the client address is known only after the PROXY
%% header is read, in the connection process. `upgrade/5' runs there, right
%% after the proxy upgrade and before TLS. A denied socket is handed over to
%% the tarpit, or closed when the tarpit is off or full.
-module(esockd_ip_check).

-include("esockd.hrl").

-export([check/3, upgrade_fun/4, upgrade/5]).

-export_type([ip_check/0]).

%% Called as M:F(IP, Args...). Returns allow or deny.
-type ip_check() :: {module(), atom(), [term()]}.

%% @doc Call the callback. A callback that raises an exception or returns
%% another value allows the peer: a bug in the callback must not refuse
%% every client.
-spec check(ip_check(), inet:ip_address(), esockd:listener_ref()) -> allow | deny.
check({M, F, A}, IP, ListenerRef) ->
    try apply(M, F, [IP | A]) of
        allow ->
            allow;
        deny ->
            deny;
        Other ->
            log_error(ListenerRef, IP, {bad_return, Other}),
            allow
    catch
        Class:Reason:Stacktrace ->
            log_error(ListenerRef, IP, {Class, Reason, Stacktrace}),
            allow
    end.

%% @doc The upgrade step that runs after the proxy upgrade.
-spec upgrade_fun(atom(), esockd:listener_ref(), ip_check(),
                  undefined | esockd_tarpit:handle()) -> esockd:sock_fun().
upgrade_fun(Type, ListenerRef, IpCheck, Tarpit) ->
    {fun ?MODULE:upgrade/5, [accept_mod(Type), ListenerRef, IpCheck, Tarpit]}.

%% Returns {error, src_ip_banned_tarpit} when the socket is handed over to
%% the tarpit; the caller must then not close it.
upgrade(Sock, AcceptMod, ListenerRef, IpCheck, Tarpit) ->
    case client_ip(Sock) of
        undefined ->
            %% No client address in the header (LOCAL or UNKNOWN).
            {ok, Sock};
        IP ->
            case check(IpCheck, IP, ListenerRef) of
                allow ->
                    {ok, Sock};
                deny ->
                    refuse(Sock, AcceptMod, ListenerRef, Tarpit)
            end
    end.

refuse(_Sock, _AcceptMod, ListenerRef, undefined) ->
    inc_stats(ListenerRef, ?ARG_CLOSED_SRC_IP_BANNED),
    {error, src_ip_banned};
refuse(Sock, AcceptMod, ListenerRef, Tarpit) ->
    case esockd_tarpit:hand_over(Tarpit, AcceptMod, raw_socket(Sock)) of
        ok ->
            inc_stats(ListenerRef, ?ARG_CLOSED_SRC_IP_BANNED_TARPIT),
            {error, src_ip_banned_tarpit};
        _FullOrError ->
            inc_stats(ListenerRef, ?ARG_CLOSED_SRC_IP_BANNED),
            {error, src_ip_banned}
    end.

accept_mod(tcpsocket) -> esockd_accept_socket;
accept_mod(_TcpOrSsl) -> esockd_accept_inet.

client_ip(#proxy_socket{src_addr = IP}) ->
    IP;
client_ip(Sock) when is_port(Sock) ->
    undefined;
client_ip(Sock) ->
    case socket:getopt(Sock, {otp, meta}) of
        {ok, #{proxy_src_addr := IP}} -> IP;
        _ -> undefined
    end.

raw_socket(#proxy_socket{socket = Sock}) -> Sock;
raw_socket(Sock) -> Sock.

inc_stats(ListenerRef, Name) ->
    _ = esockd_server:inc_stats(ListenerRef, Name, 1),
    ok.

log_error(ListenerRef, IP, Error) ->
    logger:log(error, #{msg => "esockd_ip_check_failed",
                        listener => ListenerRef,
                        peer_ip => IP,
                        error => Error}).
