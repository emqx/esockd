# DTLS Echo Server

## listen

listen on port 5000.

## build

```
make
```

## run

```
➜  ./run
Erlang/OTP 21 [erts-10.1] [source] [64-bit] [smp:4:4] [ds:4:4:10] [async-threads:1] [hipe] [dtrace]

Eshell V10.1  (abort with ^G)
1> echo/dtls opened on dtls 5000

1> Client = dtls_psk_client:connect().
ServerHint:undefined, Userstate: <<"shared_secret">>
ClientPSKID: <<"Client_identity">>, Userstate: <<"shared_secret">>
{sslsocket,{gen_udp,#Port<0.6>,dtls_connection},[<0.114.0>]}
2>
2> dtls_psk_client:send(Client, <<"hi">>).
ok
3> 127.0.0.1:53576 - <<"hi">>

3>
```
