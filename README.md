
# eSockd

Erlang General Non-blocking TCP/SSL Socket Server.

## Features 

General Non-blocking TCP/SSL Socket Server.

Acceptor Pool and Asynchronous TCP Accept.

Max connections management.

## Usage

A Simple Echo Server:

```erlang
-module(echo_server).

-export([start_link/1]).

start_link(SockArgs) ->
   {ok, spawn_link(?MODULE, init, [SockArgs])}.
      
init(SockArgs = {Transport, _Sock, _SockFun}) ->
    {ok, NewSock} = esockd_connection:accept(SockArgs),
    loop(Transport, NewSock, state).

loop(Transport, Sock, State) ->
    case Transport:recv(Sock, 0) of
        {ok, Data} ->
            {ok, Name} = Transport:peername(Sock),
            io:format("~p: ~s~n", [Name, Data]),
            Transport:send(Sock, Data),
            loop(Transport, Sock, State);
        {error, Reason} ->
            io:format("tcp ~s~n", [Reason]),
            {stop, Reason}
    end.
```

Startup Echo Server:

```
%% start eSockd application
ok = esockd:start().

SockOpts = [binary, 
            {reuseaddr, true}, 
            {nodelay, false},
            {acceptors, 10},
            {max_clients, 1024}].

MFArgs = {echo_server, start_link, []},

esockd:open(echo, 5000, SockOpts, MFArgs).
```

## Examples

```
examples/
    async_recv/
    gen_server/
    simple/
    ssl/
```

Example   | Description
----------|------
async_recv| prim_net async recv
gen_server| gen_server behaviour
simple    | simple echo server
ssl       | ssl echo server

## API

### Start

```
esockd:start().
%% or
application:start(esockd).
```

### Open

```
esockd:open(echo, 5000, [binary, {reuseaddr, true}], {echo_server, start_link, []}).
```

Spec:

```
-spec open(Protocol, Port, Options, Callback) -> {ok, pid()} | {error, any()} when
    Protocol     :: atom(),
    Port         :: inet:port_number(),
    Options		 :: [option()], 
    Callback     :: callback().
```

Options:

```
-type option() :: 
		{acceptors, pos_integer()} |
		{max_clients, pos_integer()} | 
        {logger, atom() | {atom(), atom()}} |
        {ssl, [ssl:ssloption()]} |
        gen_tcp:listen_option().
```

Callback:

```
-type mfargs() :: {module(), atom(), [term()]}.

-type callback() :: mfargs() | {atom(), atom()} | atom().
```

### Close

```
esockd:close(echo, 5000).
```

```
-spec close(Protocol, Port) -> ok when 
    Protocol    :: atom(),
    Port        :: inet:port_number().
```

## Logger

eSockd depends [gen_logger](https://github.com/emqtt/gen_logger).

Logger environment:

```
 {esockd, [
    {logger, {lager, info}}
 ]},
```

Logger option:

```
esockd:open(echo, 5000, [{logger, {otp, info}}], {echo_server, start_link, []}).
```

## License

The MIT License (MIT)

## Author

feng@emqtt.io

