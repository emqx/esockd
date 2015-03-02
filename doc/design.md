## Erlang TCP Server??

## Why?

1. TCP/SSL Socket Server
2. async accept and receive

## Issues?

1. how to handle??

{accept_failed, e{n, m}file}

sleep for a while?

crash and wait restart??

2. acceptor_sup: 

3. how to manage max connections?

THIS IS VERY IMPORTANT, emfile error could crash the whole vm

4. how to get current connections?

5. {error,already_present}

6. esockd_client_sup should be monitor child, and calculate max connections limit?

ERL_MAX_PORTS 

MAX Connections...

listener->acceptor_sup->manager->connection_sup



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


8. connection sup??

simple_one_for_one + max connections limit + statistics


## usage

test/esockd_test.erl:

```erlang
    esockd:start(),
    esockd:listen(5000, ?TCP_OPTIONS, {echo_server, start_link, []}).
```

## how to handle e{n,m}file errors when accept?

### error description

enfile: The system limit on the total number of open files has been reached.

emfile: The per-process limit of open file descriptors has been reached. "ulimit -n XXX"

### solution

acceptor sleep for a while.

## tune

ERL_MAX_PORTS: Erlang Ports Limit

ERTS_MAX_PORTS: 

+P: Maximum Number of Erlang Processes

+K true: Kernel Polling

The kernel polling option requires that you have support for it in your kernel. By default, Erlang currently supports kernel polling under FreeBSD, Mac OS X, and Solaris. If you use Linux, check this newspost. Additionaly, you need to enable this feature while compiling Erlang.

ERL_MAX_ETS_TABLES

## client error

When client received '{error,econnreset}', it means client connects too much in short time.

Server socket option '{backlog, XXX}' could increase max pending connections


## client_sup

esockd_client_sup respond for:

1. start client, and let it run...

2. control max connections

3. count active socks...
