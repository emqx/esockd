-module(dtls_psk_client).
-export([connect/0, connect/1, send/2, user_lookup/3]).

connect() -> connect(5000).
connect(Port) ->
    {ok, Client} = ssl:connect({127, 0, 0, 1}, Port, opts()),
    Client.

send(Client, Msg) ->
    ssl:send(Client, Msg).


user_lookup(psk, ServerHint, UserState) ->
    io:format("ServerHint:~p, Userstate: ~p~n", [ServerHint, UserState]),
    {ok, UserState}.

opts() ->
    [
     {ssl_imp, new},
     {active, true},
     {verify, verify_none},
     {versions, [dtlsv1]},
     {protocol, dtls},
     {ciphers, [{psk, aes_128_cbc, sha}]},
     {psk_identity, "Client_identity"},
     {user_lookup_fun,
      {fun user_lookup/3, <<"shared_secret">>}},
     {cb_info, {gen_udp, udp, udp_close, udp_error}}
    ].
