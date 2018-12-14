
-module(recv_eprof).

-export([start/3]).

-define(TCP_OPTS, [
    binary,
    {packet, raw},
    {nodelay,true},
    {active, false},
    {reuseaddr, true},
    {keepalive,true},
    {backlog,500}
]).

-spec(start(inet:port_number(), active_n|async_recv, pos_integer()) -> any()).
start(Port, How, N) ->
    eprof:start(),
    P = server(How, Port),
    eprof:start_profiling([P]),
    send(Port, N),
    eprof:stop_profiling(),
    eprof:analyze(procs, [{sort,time}]).

send(Port, N) ->
    {ok, Sock} = gen_tcp:connect("localhost", Port, [binary, {packet, raw}]),
    lists:foreach(fun(_) ->
                      ok = gen_tcp:send(Sock, <<"hello">>)
                  end, lists:seq(1, N)),
    ok = gen_tcp:close(Sock).

server(How, Port) ->
    spawn_link(fun() -> listen(How, Port) end).

listen(How, Port) ->
    {ok, L} = gen_tcp:listen(Port, ?TCP_OPTS),
    accept(How, L).

accept(How, L) ->
    {ok, Sock} = gen_tcp:accept(L),
    case How of
        active_n ->
            inet:setopts(Sock, [{active, 100}]);
        async_recv -> ok
    end,
    _ = recv_loop(How, Sock),
    accept(How, L).

recv_loop(How = active_n, Sock) ->
    receive
        {tcp, Sock, _Data} ->
            recv_loop(How, Sock);
        {tcp_passive, Sock} ->
            inet:setopts(Sock, [{active, 100}]);
        {tcp_closed, Sock}-> ok;
        {tcp_error, Sock, Reason} ->
            {error, Reason}
    end;

recv_loop(How = async_recv, Sock) ->
    {ok, Ref} = prim_inet:async_recv(Sock, 0, -1),
    receive
        {inet_async, Sock, Ref, {ok, _Data}} ->
            recv_loop(How, Sock);
        {inet_async, Sock, Ref, {error, Reason}} ->
            {error, Reason}
    end.

