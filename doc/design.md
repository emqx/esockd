## Erlang TCP Server??

## Why?

1. TCP/SSL Socket Server
2. async accept and receive

### Referrence

1. http://20bits.com/article/erlang-a-generalized-tcp-server

Network servers come in two parts: connection handling and business logic. As I described above the connection handling is basically the same for every network server. Ideally we'd be able to do something like

2. http://erlangcentral.org/wiki/index.php/Building_a_Non-blocking_TCP_server_using_OTP_principles


3. http://www.erlang-factory.com/static/upload/media/1394461730695138benoitchesneau.pdf

How to handle massive http connections?

4. how to handle e{n, m}file error?

 [EMFILE]           The per-process descriptor table is full.
 [ENFILE]           The system file table is full.

5. http://erlang.2086793.n4.nabble.com/Q-prim-inet-async-accept-and-gen-tcp-send-td2097350.html

6. https://github.com/kevsmith/gen_nb_server

https://github.com/oscarh/gen_tcpd

7. how to handle em



