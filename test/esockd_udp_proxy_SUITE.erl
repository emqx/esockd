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

-module(esockd_udp_proxy_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include("include/esockd_proxy.hrl").
-include_lib("eunit/include/eunit.hrl").

all() -> esockd_ct:all(?MODULE).

%%--------------------------------------------------------------------
%% Test cases for UDP proxy
%%--------------------------------------------------------------------

t_reroute_when_connection_id_changes(_) ->
    process_flag(trap_exit, true),
    ensure_proxy_db(),
    Port = pick_udp_port(),
    ProxyOpts = #{
        test_parent => self(),
        esockd_proxy_opts => #{connection_mod => ?MODULE}
    },
    {ok, Srv} = esockd_udp:server(
        test_udp_proxy,
        {{127, 0, 0, 1}, Port},
        [
            {connection_mfargs, {esockd_udp_proxy, start_link, [ProxyOpts]}}
        ]
    ),
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    try
        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-a">>),
        PidA = receive_find_or_create(<<"client-a">>),
        receive_dispatch(PidA, <<"client-a">>),

        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-a">>),
        receive_dispatch(PidA, <<"client-a">>),
        ?assertNot(received_find_or_create()),

        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-b">>),
        PidB = receive_find_or_create(<<"client-b">>),
        receive_dispatch(PidB, <<"client-b">>),

        ?assertNotEqual(PidA, PidB),
        ?assert(is_process_alive(PidA)),
        ?assertNot(received_close(PidA))
    after
        gen_udp:close(Sock),
        erlang:is_process_alive(Srv) andalso esockd_udp:stop(Srv)
    end.

t_reroute_detaches_old_connection_without_closing(_) ->
    process_flag(trap_exit, true),
    ensure_proxy_db(),
    Port = pick_udp_port(),
    ProxyOpts = #{
        test_parent => self(),
        esockd_proxy_opts => #{connection_mod => ?MODULE}
    },
    {ok, Srv} = esockd_udp:server(
        test_udp_proxy_detach_on_reroute,
        {{127, 0, 0, 1}, Port},
        [
            {connection_mfargs, {esockd_udp_proxy, start_link, [ProxyOpts]}}
        ]
    ),
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    try
        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-a">>),
        PidA = receive_find_or_create(<<"client-a">>),
        receive_dispatch(PidA, <<"client-a">>),
        ProxyPid = proxy_pid(Srv),

        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-b">>),
        PidB = receive_find_or_create(<<"client-b">>),
        receive_dispatch(PidB, <<"client-b">>),

        ?assertNotEqual(PidA, PidB),
        ?assert(received_detach(PidA, ProxyPid)),
        ?assertNot(received_close(PidA))
    after
        gen_udp:close(Sock),
        erlang:is_process_alive(Srv) andalso esockd_udp:stop(Srv)
    end.

t_close_remote_connection(_) ->
    case start_remote_node() of
        {skip, _} = Skip ->
            Skip;
        {ok, Peer, RemoteNode} ->
            process_flag(trap_exit, true),
            ensure_proxy_db(),
            Port = pick_udp_port(),
            RemotePid = rpc:call(RemoteNode, erlang, spawn, [timer, sleep, [infinity]]),
            ProxyOpts = #{
                test_parent => self(),
                remote_connection_pid => RemotePid,
                esockd_proxy_opts => #{connection_mod => ?MODULE}
            },
            {ok, Srv} = esockd_udp:server(
                test_udp_proxy_remote_connection,
                {{127, 0, 0, 1}, Port},
                [
                    {connection_mfargs, {esockd_udp_proxy, start_link, [ProxyOpts]}}
                ]
            ),
            {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
            try
                ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"remote-client">>),
                ?assertEqual(RemotePid, receive_find_or_create(<<"remote-client">>)),
                receive_dispatch(RemotePid, <<"remote-client">>),
                ProxyPid = proxy_pid(Srv),

                ok = esockd_udp_proxy:close(ProxyPid),
                ?assert(received_close(RemotePid, ProxyPid))
            after
                gen_udp:close(Sock),
                erlang:is_process_alive(Srv) andalso esockd_udp:stop(Srv),
                ok = peer:stop(Peer)
            end
    end.

t_close_remote_proxy(_) ->
    case start_remote_node() of
        {skip, _} = Skip ->
            Skip;
        {ok, Peer, RemoteNode} ->
            process_flag(trap_exit, true),
            ensure_proxy_db(),
            Port = pick_udp_port(),
            ProxyOpts = #{
                test_parent => self(),
                esockd_proxy_opts => #{connection_mod => ?MODULE}
            },
            {ok, Srv} = esockd_udp:server(
                test_remote_udp_proxy_close,
                {{127, 0, 0, 1}, Port},
                [
                    {connection_mfargs, {esockd_udp_proxy, start_link, [ProxyOpts]}}
                ]
            ),
            {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
            try
                ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-a">>),
                Pid = receive_find_or_create(<<"client-a">>),
                receive_dispatch(Pid, <<"client-a">>),
                ProxyPid = proxy_pid(Srv),
                ok = load_udp_proxy_module(RemoteNode),

                ?assertEqual(ok, rpc:call(RemoteNode, esockd_udp_proxy, close, [ProxyPid])),
                ?assert(received_close(Pid, ProxyPid))
            after
                gen_udp:close(Sock),
                erlang:is_process_alive(Srv) andalso esockd_udp:stop(Srv),
                ok = peer:stop(Peer)
            end
    end.

t_close_unavailable_remote_proxy(_) ->
    case start_remote_node() of
        {skip, _} = Skip ->
            Skip;
        {ok, Peer, RemoteNode} ->
            try
                DeadPid = rpc:call(RemoteNode, erlang, spawn, [timer, sleep, [0]]),
                Ref = erlang:monitor(process, DeadPid),
                receive
                    {'DOWN', Ref, process, DeadPid, _Reason} ->
                        ok
                after 1000 ->
                    error({process_still_alive, DeadPid})
                end,
                ?assertEqual(ok, esockd_udp_proxy:close(DeadPid)),

                DisconnectedPid = rpc:call(
                    RemoteNode, erlang, spawn, [timer, sleep, [infinity]]
                ),
                ok = peer:stop(Peer),
                ?assertEqual(ok, esockd_udp_proxy:close(DisconnectedPid))
            after
                erlang:is_process_alive(Peer) andalso peer:stop(Peer)
            end
    end.

t_close_stopping_proxy(_) ->
    lists:foreach(
        fun(Reason) ->
            ProxyPid = spawn(fun() -> stopping_proxy_loop(Reason) end),
            ?assertEqual(ok, esockd_udp_proxy:close(ProxyPid))
        end,
        [normal, shutdown, {shutdown, restarting}, kill]
    ).

t_close_preserves_unexpected_failures(_) ->
    CrashingProxy = spawn(fun() -> stopping_proxy_loop(unexpected_failure) end),
    ?assertMatch(
        {'EXIT', {unexpected_failure, {gen_server, call, _}}},
        catch esockd_udp_proxy:close(CrashingProxy)
    ),
    UnexpectedReplyProxy = spawn(fun unexpected_reply_proxy_loop/0),
    ?assertMatch(
        {'EXIT', {{try_clause, unexpected_reply}, _}},
        catch esockd_udp_proxy:close(UnexpectedReplyProxy)
    ).

t_close_unresponsive_proxy(_) ->
    ProxyPid = spawn(fun unresponsive_proxy_loop/0),
    Ref = erlang:monitor(process, ProxyPid),
    ok = esockd_udp_proxy:close(ProxyPid),
    receive
        {'DOWN', Ref, process, ProxyPid, killed} ->
            ok
    after 1000 ->
        error({proxy_not_killed, ProxyPid})
    end.

t_lookup_failure_preserves_old_binding(_) ->
    process_flag(trap_exit, true),
    ensure_proxy_db(),
    Port = pick_udp_port(),
    ProxyOpts = #{
        test_parent => self(),
        esockd_proxy_opts => #{connection_mod => ?MODULE}
    },
    {ok, Srv} = esockd_udp:server(
        test_udp_proxy_lookup_failure,
        {{127, 0, 0, 1}, Port},
        [
            {connection_mfargs, {esockd_udp_proxy, start_link, [ProxyOpts]}}
        ]
    ),
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    try
        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-a">>),
        PidA = receive_find_or_create(<<"client-a">>),
        receive_dispatch(PidA, <<"client-a">>),
        ProxyPid = proxy_pid(Srv),

        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"ignore">>),
        receive_find_or_create_ignored(<<"ignore">>),

        ok = esockd_udp_proxy:close(ProxyPid),
        ?assert(received_close(PidA, ProxyPid))
    after
        gen_udp:close(Sock),
        erlang:is_process_alive(Srv) andalso esockd_udp:stop(Srv)
    end.

t_stale_down_after_reroute_is_ignored(_) ->
    process_flag(trap_exit, true),
    ensure_proxy_db(),
    Port = pick_udp_port(),
    ProxyOpts = #{
        test_parent => self(),
        esockd_proxy_opts => #{connection_mod => ?MODULE}
    },
    {ok, Srv} = esockd_udp:server(
        test_udp_proxy_stale_down,
        {{127, 0, 0, 1}, Port},
        [
            {connection_mfargs, {esockd_udp_proxy, start_link, [ProxyOpts]}}
        ]
    ),
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    try
        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-a">>),
        PidA = receive_find_or_create(<<"client-a">>),
        receive_dispatch(PidA, <<"client-a">>),
        ProxyPid = proxy_pid(Srv),
        #{connection_ref := RefA} = sys:get_state(ProxyPid),

        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-b">>),
        PidB = receive_find_or_create(<<"client-b">>),
        receive_dispatch(PidB, <<"client-b">>),

        ProxyPid ! {'DOWN', RefA, process, PidA, normal},
        timer:sleep(100),
        ?assert(is_process_alive(ProxyPid)),

        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-b">>),
        receive_dispatch(PidB, <<"client-b">>)
    after
        gen_udp:close(Sock),
        erlang:is_process_alive(Srv) andalso esockd_udp:stop(Srv)
    end.

t_legacy_find_or_create_callback_still_works(_) ->
    process_flag(trap_exit, true),
    ensure_proxy_db(),
    Port = pick_udp_port(),
    persistent_term:put({esockd_udp_proxy_legacy_conn, test_parent}, self()),
    ProxyOpts = #{
        test_parent => self(),
        esockd_proxy_opts => #{connection_mod => esockd_udp_proxy_legacy_conn}
    },
    {ok, Srv} = esockd_udp:server(
        test_udp_proxy_legacy,
        {{127, 0, 0, 1}, Port},
        [
            {connection_mfargs, {esockd_udp_proxy, start_link, [ProxyOpts]}}
        ]
    ),
    {ok, Sock} = gen_udp:open(0, [binary, {active, false}]),
    try
        ok = gen_udp:send(Sock, {127, 0, 0, 1}, Port, <<"client-a">>),
        PidA = receive_find_or_create(<<"client-a">>),
        receive_dispatch(PidA, <<"client-a">>)
    after
        gen_udp:close(Sock),
        erlang:is_process_alive(Srv) andalso esockd_udp:stop(Srv),
        persistent_term:erase({esockd_udp_proxy_legacy_conn, test_parent})
    end.

t_legacy_find_or_create_wrapper_still_works(_) ->
    persistent_term:put({esockd_udp_proxy_legacy_conn, test_parent}, self()),
    try
        {ok, Pid} = esockd_udp_proxy_connection:find_or_create(
            esockd_udp_proxy_legacy_conn,
            <<"client-a">>,
            {?PROXY_TRANSPORT, self(), self()},
            {127, 0, 0, 1},
            #{}
        ),
        ?assertEqual(Pid, receive_find_or_create(<<"client-a">>)),
        Pid ! close
    after
        persistent_term:erase({esockd_udp_proxy_legacy_conn, test_parent})
    end.

t_legacy_detach_wrapper_still_works(_) ->
    Pid = spawn(fun connection_loop/0),
    State = #{parent => self()},
    ok = esockd_udp_proxy_connection:detach(?MODULE, Pid, State),
    ?assert(received_legacy_detach(Pid)).

t_legacy_close_wrapper_still_works(_) ->
    Pid = spawn(fun connection_loop/0),
    State = #{parent => self()},
    ok = esockd_udp_proxy_connection:close(?MODULE, Pid, State),
    ?assert(received_legacy_close(Pid)).

%%--------------------------------------------------------------------
%% esockd_udp_proxy_connection callbacks
%%--------------------------------------------------------------------

initialize(Opts) ->
    #{
        parent => maps:get(test_parent, Opts),
        remote_connection_pid => maps:get(remote_connection_pid, Opts, undefined)
    }.

get_connection_id(_Transport, _Peer, State, Data) ->
    {ok, Data, Data, State#{last_cid => Data}}.

find_or_create(CId, _Transport, _Peer, _Opts, State) ->
    Parent = maps:get(parent, State),
    case CId of
        <<"ignore">> ->
            Parent ! {find_or_create_ignored, CId},
            ignore;
        <<"remote-client">> ->
            Pid = maps:get(remote_connection_pid, State),
            Parent ! {find_or_create, CId, maps:get(last_cid, State), Pid},
            {ok, Pid};
        _ ->
            Pid = spawn(fun connection_loop/0),
            Parent ! {find_or_create, CId, maps:get(last_cid, State), Pid},
            {ok, Pid}
    end.

dispatch(Pid, State, {_Transport, _Data, Packet}) ->
    maps:get(parent, State) ! {dispatch, Pid, Packet},
    Pid ! {packet, Packet},
    ok.

close(Pid, State) ->
    maps:get(parent, State) ! {legacy_close, Pid},
    Pid ! close,
    ok.

close(Pid, ProxyPid, State) ->
    maps:get(parent, State) ! {close, Pid, ProxyPid},
    Pid ! close,
    ok.

detach(Pid, State) ->
    maps:get(parent, State) ! {legacy_detach, Pid},
    Pid ! detach,
    ok.

detach(Pid, ProxyPid, State) ->
    maps:get(parent, State) ! {detach, Pid, ProxyPid},
    Pid ! detach,
    ok.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

ensure_proxy_db() ->
    case whereis(esockd_udp_proxy_db) of
        undefined ->
            {ok, _Pid} = esockd_udp_proxy_db:start_link(),
            ok;
        _Pid ->
            ok
    end.

start_remote_node() ->
    case erlang:function_exported(peer, start_link, 1) of
        false ->
            {skip, peer_module_unavailable};
        true ->
            ensure_distribution(),
            {ok, Peer, RemoteNode} = peer:start_link(#{name => esockd_udp_proxy_peer}),
            {ok, Peer, RemoteNode}
    end.

ensure_distribution() ->
    case node() of
        nonode@nohost ->
            _ = os:cmd("epmd -daemon"),
            {ok, _} = net_kernel:start([esockd_udp_proxy_test, shortnames]),
            ok;
        _ ->
            ok
    end.

load_udp_proxy_module(RemoteNode) ->
    {esockd_udp_proxy, Beam, BeamFile} = code:get_object_code(esockd_udp_proxy),
    {module, esockd_udp_proxy} =
        rpc:call(RemoteNode, code, load_binary, [esockd_udp_proxy, BeamFile, Beam]),
    ok.

pick_udp_port() ->
    {ok, Sock} = gen_udp:open(0, [binary]),
    {ok, Port} = inet:port(Sock),
    gen_udp:close(Sock),
    Port.

proxy_pid(Srv) ->
    [{undefined, Pid, worker, [esockd_udp_proxy]}] = gen_server:call(Srv, which_children),
    Pid.

connection_loop() ->
    receive
        close ->
            ok;
        _Msg ->
            connection_loop()
    end.

unresponsive_proxy_loop() ->
    receive
        _Msg ->
            unresponsive_proxy_loop()
    end.

stopping_proxy_loop(Reason) ->
    receive
        {'$gen_call', _From, close} when Reason =:= kill ->
            ProxyPid = self(),
            spawn(fun() -> exit(ProxyPid, kill) end),
            receive
            after infinity ->
                ok
            end;
        {'$gen_call', _From, close} ->
            exit(Reason)
    end.

unexpected_reply_proxy_loop() ->
    receive
        {'$gen_call', From, close} ->
            gen_server:reply(From, unexpected_reply)
    end.

receive_find_or_create(CId) ->
    receive
        {find_or_create, CId, CId, Pid} ->
            Pid
    after 1000 ->
        error({missing_find_or_create, CId})
    end.

receive_dispatch(Pid, Packet) ->
    receive
        {dispatch, Pid, Packet} ->
            ok
    after 1000 ->
        error({missing_dispatch, Pid, Packet})
    end.

received_find_or_create() ->
    receive
        {find_or_create, _CId, _LastCId, _Pid} ->
            true
    after 100 ->
        false
    end.

receive_find_or_create_ignored(CId) ->
    receive
        {find_or_create_ignored, CId} ->
            ok
    after 1000 ->
        error({missing_find_or_create_ignored, CId})
    end.

received_close(Pid) ->
    receive
        {close, Pid} ->
            true
    after 100 ->
        false
    end.

received_close(Pid, ProxyPid) ->
    receive
        {close, Pid, ProxyPid} ->
            true
    after 100 ->
        false
    end.

received_legacy_close(Pid) ->
    receive
        {legacy_close, Pid} ->
            true
    after 100 ->
        false
    end.

received_detach(Pid) ->
    receive
        {detach, Pid} ->
            true
    after 100 ->
        false
    end.

received_detach(Pid, ProxyPid) ->
    receive
        {detach, Pid, ProxyPid} ->
            true
    after 100 ->
        false
    end.

received_legacy_detach(Pid) ->
    receive
        {legacy_detach, Pid} ->
            true
    after 100 ->
        false
    end.
