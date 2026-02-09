%%--------------------------------------------------------------------
%% Integration test echo server that reports wait/1 outcome via ETS.
%%--------------------------------------------------------------------

-module(ppv2_upgrade_reason_echo_server).

-export([start_link/3]).

start_link(Transport, RawSock, CaseTag) ->
    {ok, spawn_link(fun() -> init(Transport, RawSock, CaseTag) end)}.

init(Transport, RawSock, CaseTag) ->
    case Transport:wait(RawSock) of
        {ok, Sock} ->
            store_once(CaseTag, ok, <<>>),
            loop(Transport, Sock);
        {ok, Sock, Prefetched} ->
            store_once(CaseTag, ok_prefetched, Prefetched),
            _ = maybe_echo_prefetched(Transport, Sock, Prefetched),
            loop(Transport, Sock);
        {error, Reason} ->
            store_once(CaseTag, {error, Reason}, explain_reason(Reason))
    end.

loop(Transport, Sock) ->
    case recv_data(Transport, Sock) of
        {ok, Data} ->
            ok = send_data(Transport, Sock, Data),
            loop(Transport, Sock);
        {error, _Reason} ->
            ok;
        {shutdown, _Reason} ->
            ok
    end.

maybe_echo_prefetched(_Transport, _Sock, none) ->
    ok;
maybe_echo_prefetched(_Transport, _Sock, <<>>) ->
    ok;
maybe_echo_prefetched(Transport, Sock, Data) ->
    send_data(Transport, Sock, Data).

explain_reason(proxy_proto_timeout) ->
    <<"proxy protocol upgrade timed out while waiting for complete PPv2 signature">>;
explain_reason(proxy_proto_close) ->
    <<"peer closed connection while proxy protocol upgrade was waiting for complete PPv2 signature">>;
explain_reason(Reason) ->
    iolist_to_binary(io_lib:format("unexpected wait error reason: ~p", [Reason])).

store_once(CaseTag, Status, Msg) ->
    _ = ets:insert_new(ppv2_it_results, {CaseTag, Status, Msg, erlang:system_time(millisecond)}),
    ok.

recv_data(esockd_socket, Sock) ->
    socket:recv(Sock, 0, [], 3000);
recv_data(Transport, Sock) ->
    Transport:recv(Sock, 0).

send_data(esockd_socket, Sock, Data) ->
    socket:send(Sock, Data);
send_data(Transport, Sock, Data) ->
    Transport:send(Sock, Data).
