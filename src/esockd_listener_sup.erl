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

-module(esockd_listener_sup).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(supervisor).

-include("esockd.hrl").

-export([start_link/4, listener/1, acceptor_sup/1, connection_sup/1]).

%% callback
-export([init/1]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Start listener supervisor
-spec(start_link(atom(), esockd:listen_on(), [esockd:option()], esockd:mfargs())
      -> {ok, pid()}).
start_link(Proto, ListenOn, Options, MFArgs) ->
    {ok, Sup} = supervisor:start_link(?MODULE, []),
    %% Start connection sup
    ConnSupSpec = #{id       => connection_sup,
                    start    => {esockd_connection_sup, start_link, [Options, MFArgs]},
                    restart  => transient,
                    shutdown => brutal_kill,
                    type     => supervisor,
                    modules  => [esockd_connection_sup]},
    {ok, ConnSup} = supervisor:start_child(Sup, ConnSupSpec),
    %% Start acceptor sup
    TuneFun = buffer_tune_fun(Options),
    UpgradeFuns = upgrade_funs(Options),
    StatsFun = esockd_server:stats_fun({Proto, ListenOn}, accepted),
    AcceptorSupSpec =  #{id       => acceptor_sup,
                         start    => {esockd_acceptor_sup, start_link,
                                      [ConnSup, TuneFun, UpgradeFuns, StatsFun]},
                         restart  => transient,
                         shutdown => infinity,
                         type     => supervisor,
                         modules  => [esockd_acceptor_sup]},
    {ok, AcceptorSup} = supervisor:start_child(Sup, AcceptorSupSpec),
    %% Start listener
    ListenerSpec = #{id       => listener,
                     start    => {esockd_listener, start_link,
                                  [Proto, ListenOn, Options, AcceptorSup]},
                     restart  => transient,
                     shutdown => 16#ffffffff,
                     type     => worker,
                     modules  => [esockd_listener]},
    {ok, _Listener} = supervisor:start_child(Sup, ListenerSpec),
    {ok, Sup}.

%% @doc Get listener.
-spec(listener(pid()) -> pid()).
listener(Sup) -> child_pid(Sup, listener).

%% @doc Get connection supervisor.
-spec(connection_sup(pid()) -> pid()).
connection_sup(Sup) -> child_pid(Sup, connection_sup).

%% @doc Get acceptor supervisor.
-spec(acceptor_sup(pid()) -> pid()).
acceptor_sup(Sup) -> child_pid(Sup, acceptor_sup).

%% @doc Get child pid with id.
child_pid(Sup, ChildId) ->
    hd([Pid || {Id, Pid, _, _}
               <- supervisor:which_children(Sup), Id =:= ChildId]).

%%--------------------------------------------------------------------
%% Supervisor callbacks
%%--------------------------------------------------------------------

init([]) ->
    {ok, {{rest_for_one, 10, 3600}, []}}.

%%--------------------------------------------------------------------
%% Tune and upgrade functions
%%--------------------------------------------------------------------

buffer_tune_fun(Options) ->
    buffer_tune_fun(proplists:get_value(buffer, Options),
                    proplists:get_bool(tune_buffer, Options)).

%% when 'buffer' is undefined, and 'tune_buffer' is true...
buffer_tune_fun(undefined, true) ->
    fun(Sock) ->
        case inet:getopts(Sock, [sndbuf, recbuf, buffer]) of
            {ok, BufSizes} ->
                BufSz = lists:max([Sz || {_Opt, Sz} <- BufSizes]),
                inet:setopts(Sock, [{buffer, BufSz}]),
                {ok, Sock};
            Error -> Error
        end
    end;
buffer_tune_fun(_, _) ->
    fun(Sock) -> {ok, Sock} end.

upgrade_funs(Options) ->
    lists:append([ssl_upgrade_fun(Options), proxy_upgrade_fun(Options)]).

ssl_upgrade_fun(Options) ->
    case proplists:get_value(ssl_options, Options) of
        undefined -> [];
        SslOpts   -> [esockd_transport:ssl_upgrade_fun(SslOpts)]
    end.

proxy_upgrade_fun(Options) ->
    case proplists:get_bool(proxy_protocol, Options) of
        false -> [];
        true  -> [esockd_transport:proxy_upgrade_fun(Options)]
    end.

