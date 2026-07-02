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
    #{parent => maps:get(test_parent, Opts)}.

get_connection_id(_Transport, _Peer, State, Data) ->
    {ok, Data, Data, State#{last_cid => Data}}.

find_or_create(CId, _Transport, _Peer, _Opts, State) ->
    Parent = maps:get(parent, State),
    case CId of
        <<"ignore">> ->
            Parent ! {find_or_create_ignored, CId},
            ignore;
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
