
# eSockd

Erlang General Non-blocking TCP/SSL Server.


## build

```
	make
```

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

## Author

feng@slimchat.io
