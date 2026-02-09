%%--------------------------------------------------------------------
%% Integration tests using HAProxy + Docker Compose.
%%--------------------------------------------------------------------

-module(esockd_proxy_protocol_haproxy_compose_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(COMPOSE_PROJECT, "esockd_ppv2_it").

all() ->
    [t_ppv2_partial_signature_timeout_returns_reason_to_app,
     t_ppv2_partial_signature_close_returns_reason_to_app,
     t_ppv2_pass_mode_echo_roundtrip_through_haproxy,
     t_ppv2_partial_signature_timeout_returns_reason_to_app_tcpsocket,
     t_ppv2_partial_signature_close_returns_reason_to_app_tcpsocket,
     t_ppv2_pass_mode_echo_roundtrip_through_haproxy_tcpsocket].

init_per_suite(Config) ->
    case docker_available() of
        true ->
            {ok, _} = application:ensure_all_started(esockd),
            Config;
        false ->
            {skip, "docker or docker compose is not available"}
    end.

end_per_suite(_Config) ->
    _ = compose_down(),
    application:stop(esockd).

init_per_testcase(Case, Config) ->
    _ = compose_down(),
    maybe_reset_results_table(),
    _ = ets:delete(ppv2_it_results, Case),
    EsockdPort = choose_esockd_port(Case),
    HaproxyPort = choose_haproxy_port(Case),
    Mode = choose_mode(Case),

    Listener = listener_name(Case),
    Opts = [
        {proxy_protocol, auto},
        {proxy_protocol_timeout, 200},
        {tcp_options, [binary, {packet, raw}, {reuseaddr, true}]},
        {connection_mfargs, {ppv2_upgrade_reason_echo_server, start_link, [Case]}}
    ],
    {ok, _} = open_listener(Case, Listener, EsockdPort, Opts),

    ok = compose_up(Mode, HaproxyPort, EsockdPort),
    ok = wait_haproxy_ready(HaproxyPort, 30),

    [{listener, Listener},
     {esockd_port, EsockdPort},
     {haproxy_port, HaproxyPort},
     {case_tag, Case}
     | Config].

end_per_testcase(_Case, Config) ->
    Listener = ?config(listener, Config),
    EsockdPort = ?config(esockd_port, Config),
    _ = catch esockd:close(Listener, EsockdPort),
    _ = compose_down(),
    Config.

t_ppv2_partial_signature_timeout_returns_reason_to_app(Config) ->
    HaproxyPort = ?config(haproxy_port, Config),
    CaseTag = ?config(case_tag, Config),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", HaproxyPort, [binary, {active, false}], 3000),
    ok = gen_tcp:send(Sock, <<"client-data">>),
    ok = gen_tcp:close(Sock),

    {error, proxy_proto_timeout, Msg} = wait_result(CaseTag, 5000),
    ?assertMatch(<<"proxy protocol upgrade timed out", _/binary>>, Msg),
    ok.

t_ppv2_partial_signature_close_returns_reason_to_app(Config) ->
    HaproxyPort = ?config(haproxy_port, Config),
    CaseTag = ?config(case_tag, Config),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", HaproxyPort, [binary, {active, false}], 3000),
    ok = gen_tcp:send(Sock, <<"client-data">>),
    ok = gen_tcp:close(Sock),

    {error, proxy_proto_close, Msg} = wait_result(CaseTag, 5000),
    ?assertMatch(<<"peer closed connection", _/binary>>, Msg),
    ok.

t_ppv2_pass_mode_echo_roundtrip_through_haproxy(Config) ->
    HaproxyPort = ?config(haproxy_port, Config),
    CaseTag = ?config(case_tag, Config),
    Payload = <<"hello-through-haproxy">>,
    {ok, Sock} = gen_tcp:connect("127.0.0.1", HaproxyPort, [binary, {active, false}], 3000),
    ok = gen_tcp:send(Sock, Payload),
    {ok, Payload} = gen_tcp:recv(Sock, 0, 3000),
    ok = gen_tcp:close(Sock),
    case wait_result(CaseTag, 5000) of
        {ok, _Msg} ->
            ok;
        {ok_prefetched, Prefetched} ->
            ?assertEqual(Payload, Prefetched),
            ok
    end,
    ok.

t_ppv2_partial_signature_timeout_returns_reason_to_app_tcpsocket(Config) ->
    HaproxyPort = ?config(haproxy_port, Config),
    CaseTag = ?config(case_tag, Config),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", HaproxyPort, [binary, {active, false}], 3000),
    ok = gen_tcp:send(Sock, <<"client-data">>),
    ok = gen_tcp:close(Sock),

    {error, proxy_proto_timeout, Msg} = wait_result(CaseTag, 5000),
    ?assertMatch(<<"proxy protocol upgrade timed out", _/binary>>, Msg),
    ok.

t_ppv2_partial_signature_close_returns_reason_to_app_tcpsocket(Config) ->
    HaproxyPort = ?config(haproxy_port, Config),
    CaseTag = ?config(case_tag, Config),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", HaproxyPort, [binary, {active, false}], 3000),
    ok = gen_tcp:send(Sock, <<"client-data">>),
    ok = gen_tcp:close(Sock),

    {error, proxy_proto_close, Msg} = wait_result(CaseTag, 5000),
    ?assertMatch(<<"peer closed connection", _/binary>>, Msg),
    ok.

t_ppv2_pass_mode_echo_roundtrip_through_haproxy_tcpsocket(Config) ->
    HaproxyPort = ?config(haproxy_port, Config),
    CaseTag = ?config(case_tag, Config),
    Payload = <<"hello-through-haproxy-tcpsocket">>,
    {ok, Sock} = gen_tcp:connect("127.0.0.1", HaproxyPort, [binary, {active, false}], 3000),
    ok = gen_tcp:send(Sock, Payload),
    {ok, Payload} = gen_tcp:recv(Sock, 0, 3000),
    ok = gen_tcp:close(Sock),
    case wait_result(CaseTag, 5000) of
        {ok, _Msg} ->
            ok;
        {ok_prefetched, Prefetched} ->
            ?assertEqual(Payload, Prefetched),
            ok
    end,
    ok.

listener_name(t_ppv2_partial_signature_timeout_returns_reason_to_app) -> ppv2_it_timeout;
listener_name(t_ppv2_partial_signature_close_returns_reason_to_app) -> ppv2_it_close;
listener_name(t_ppv2_pass_mode_echo_roundtrip_through_haproxy) -> ppv2_it_pass;
listener_name(t_ppv2_partial_signature_timeout_returns_reason_to_app_tcpsocket) -> ppv2_it_timeout_sock;
listener_name(t_ppv2_partial_signature_close_returns_reason_to_app_tcpsocket) -> ppv2_it_close_sock;
listener_name(t_ppv2_pass_mode_echo_roundtrip_through_haproxy_tcpsocket) -> ppv2_it_pass_sock.

choose_mode(t_ppv2_partial_signature_timeout_returns_reason_to_app) -> "timeout";
choose_mode(t_ppv2_partial_signature_close_returns_reason_to_app) -> "close";
choose_mode(t_ppv2_pass_mode_echo_roundtrip_through_haproxy) -> "pass";
choose_mode(t_ppv2_partial_signature_timeout_returns_reason_to_app_tcpsocket) -> "timeout";
choose_mode(t_ppv2_partial_signature_close_returns_reason_to_app_tcpsocket) -> "close";
choose_mode(t_ppv2_pass_mode_echo_roundtrip_through_haproxy_tcpsocket) -> "pass".

choose_esockd_port(t_ppv2_partial_signature_timeout_returns_reason_to_app) -> 27070;
choose_esockd_port(t_ppv2_partial_signature_close_returns_reason_to_app) -> 27071;
choose_esockd_port(t_ppv2_pass_mode_echo_roundtrip_through_haproxy) -> 27072;
choose_esockd_port(t_ppv2_partial_signature_timeout_returns_reason_to_app_tcpsocket) -> 27073;
choose_esockd_port(t_ppv2_partial_signature_close_returns_reason_to_app_tcpsocket) -> 27074;
choose_esockd_port(t_ppv2_pass_mode_echo_roundtrip_through_haproxy_tcpsocket) -> 27075.

choose_haproxy_port(t_ppv2_partial_signature_timeout_returns_reason_to_app) -> 28080;
choose_haproxy_port(t_ppv2_partial_signature_close_returns_reason_to_app) -> 28080;
choose_haproxy_port(t_ppv2_pass_mode_echo_roundtrip_through_haproxy) -> 28080;
choose_haproxy_port(t_ppv2_partial_signature_timeout_returns_reason_to_app_tcpsocket) -> 28080;
choose_haproxy_port(t_ppv2_partial_signature_close_returns_reason_to_app_tcpsocket) -> 28080;
choose_haproxy_port(t_ppv2_pass_mode_echo_roundtrip_through_haproxy_tcpsocket) -> 28080.

wait_haproxy_ready(_Port, 0) ->
    {error, timeout};
wait_haproxy_ready(Port, Retries) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 300) of
        {ok, Sock} ->
            ok = gen_tcp:close(Sock),
            ok;
        {error, _} ->
            timer:sleep(100),
            wait_haproxy_ready(Port, Retries - 1)
    end.

compose_up(Mode, HaproxyPort, EsockdPort) ->
    case HaproxyPort of
        28080 -> ok;
        _ -> ct:fail({unsupported_haproxy_port, HaproxyPort})
    end,
    Env = [
        {"MODE", Mode},
        {"HOLD_MS", hold_ms(Mode)},
        {"UPSTREAM_HOST", "127.0.0.1"},
        {"UPSTREAM_PORT", integer_to_list(EsockdPort)}
    ],
    Cmd = compose_cmd(Env, "up -d --build --force-recreate"),
    case run_sh(Cmd) of
        {0, _Out} -> ok;
        {Code, Out} -> ct:fail({compose_up_failed, Code, Out})
    end.

compose_down() ->
    Cmd = compose_cmd([], "down -v --remove-orphans"),
    _ = run_sh(Cmd),
    ok.

hold_ms("timeout") -> "900";
hold_ms("close") -> "0";
hold_ms("pass") -> "0".

compose_cmd(Env, Action) ->
    ComposeFile = compose_file(),
    EnvStr = string:join([K ++ "='" ++ V ++ "'" || {K, V} <- Env], " "),
    Prefix = case EnvStr of
                 [] -> "";
                 _ -> EnvStr ++ " "
             end,
    Prefix ++
    "docker compose -f " ++ ComposeFile ++
    " -p " ++ ?COMPOSE_PROJECT ++
    " " ++ Action.

compose_file() ->
    filename:join([repo_root(), "test", "integration", "ppv2_compose", "compose.yaml"]).

repo_root() ->
    {ok, Cwd} = file:get_cwd(),
    find_repo_root(filename:absname(Cwd), 12).

find_repo_root(_Dir, 0) ->
    erlang:error(repo_root_not_found);
find_repo_root(Dir, N) ->
    Rebar = filename:join(Dir, "rebar.config"),
    case filelib:is_file(Rebar) of
        true ->
            Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent =:= Dir of
                true -> erlang:error(repo_root_not_found);
                false -> find_repo_root(Parent, N - 1)
            end
    end.

docker_available() ->
    case run_sh("docker --version") of
        {0, _} ->
            case run_sh("docker compose version") of
                {0, _} -> true;
                _ -> false
            end;
        _ -> false
    end.

run_sh(Cmd) ->
    Port = erlang:open_port(
             {spawn_executable, "/bin/sh"},
             [exit_status, use_stdio, stderr_to_stdout, binary, {args, ["-c", Cmd]}]
           ),
    gather_port_output(Port, <<>>).

gather_port_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            gather_port_output(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} ->
            {Status, binary_to_list(Acc)}
    end.

maybe_reset_results_table() ->
    case ets:info(ppv2_it_results) of
        undefined ->
            _ = ets:new(ppv2_it_results, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

wait_result(_CaseTag, Timeout) when Timeout =< 0 ->
    ct:fail(timeout_waiting_for_wait_error);
wait_result(CaseTag, Timeout) ->
    case ets:lookup(ppv2_it_results, CaseTag) of
        [{CaseTag, {error, Reason}, Msg, _Ts}] ->
            {error, Reason, Msg};
        [{CaseTag, ok, Msg, _Ts}] ->
            {ok, Msg};
        [{CaseTag, ok_prefetched, Msg, _Ts}] ->
            {ok_prefetched, Msg};
        [] ->
            timer:sleep(100),
            wait_result(CaseTag, Timeout - 100)
    end.

open_listener(Case, Listener, EsockdPort, Opts) ->
    case is_tcpsocket_case(Case) of
        true ->
            esockd:open_tcpsocket(Listener, EsockdPort, Opts);
        false ->
            esockd:open(Listener, EsockdPort, Opts)
    end.

is_tcpsocket_case(t_ppv2_partial_signature_timeout_returns_reason_to_app_tcpsocket) -> true;
is_tcpsocket_case(t_ppv2_partial_signature_close_returns_reason_to_app_tcpsocket) -> true;
is_tcpsocket_case(t_ppv2_pass_mode_echo_roundtrip_through_haproxy_tcpsocket) -> true;
is_tcpsocket_case(_) -> false.
