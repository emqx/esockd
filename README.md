
# eSockd [![Build Status](https://travis-ci.org/emqtt/esockd.svg?branch=master)](https://travis-ci.org/emqtt/esockd)

Erlang General Non-blocking TCP/SSL Socket Server.

## Features

* General Non-blocking TCP/SSL Socket Server
* Acceptor Pool and Asynchronous TCP Accept
* Parameterized Connection Module
* Max connections management
* Allow/Deny by peer address
* Keepalive Support
* Rate Limit

## Usage

A Simple Echo Server:

```erlang
-module(echo_server).

-export([start_link/1]).

start_link(Conn) ->
   {ok, spawn_link(?MODULE, init, [Conn])}.
      
init(Conn) ->
    {ok, NewConn} = Conn:wait(),
	loop(NewConn).

loop(Conn) ->
	case Conn:recv(0) of
		{ok, Data} ->
			{ok, PeerName} = Conn:peername(),
			io:format("~s - ~s~n", [esockd_net:format(peername, PeerName), Data]),
			Conn:send(Data),
			loop(Conn);
		{error, Reason} ->
			io:format("tcp ~s~n", [Reason]),
			{stop, Reason}
	end.
```

Startup Echo Server:

```
%% start eSockd application
ok = esockd:start().

Options = [{acceptors, 10},
           {max_clients, 1024},
           {sockopts, [binary,
                       {reuseaddr, true},
                       {nodelay, false}]}].

MFArgs = {echo_server, start_link, []},

esockd:open(echo, 5000, Options, MFArgs).
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
async_recv| prim_net async recv/send
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
esockd:open(echo, 5000, [{sockopts, [binary, {reuseaddr, true}]}], {echo_server, start_link, []}).
```

Spec:

```
-spec open(Protocol, Port, Options, MFArgs) -> {ok, pid()} | {error, any()} when
    Protocol     :: atom(),
    Port         :: inet:port_number(),
    Options		 :: [option()], 
    MFArgs       :: esockd:mfargs().
```

Options:

```
-type option() :: 
		{acceptors, pos_integer()} |
		{max_clients, pos_integer()} | 
		{tune_buffer, false | true} |
        {access, [esockd_access:rule()]} |
        {logger, atom() | {atom(), atom()}} |
        {ssl, [ssl:ssloption()]} |
        {connopts, [{ratelimit, string()}]} |
        {sockopts, [gen_tcp:listen_option()]}.
```

MFArgs:

```
-type mfargs() :: atom() | {atom(), atom()} | {module(), atom(), [term()]}.

```

### Get Setting and Stats

Get stats:

```
esockd:get_stats({echo, 5000}).
```

Get acceptors:

```
esockd:get_acceptors({echo, 5000}).
```

Get/Set max clients:

```
esockd:get_max_clients({echo, 5000}).
esockd:set_max_clients({echo, 5000}, 100000).
```

### Allow/Deny

Same to Allow/Deny Syntax of nginx:

```
allow address | CIDR | all;

deny address | CIDR | all;
```

allow/deny by options:

```
esockd:open(echo, 5000, [
    {access, [{deny, "192.168.1.1"},
              {allow, "192.168.1.0/24"},
              {deny, all}]}
]).
```

allow/deny by API:

```
esockd:allow({echo, 5000}, all).
esockd:allow({echo, 5000}, "192.168.0.1/24").
esockd:deny({echo, 5000}, all).
esockd:deny({echo, 5000}, "10.10.0.0/16").
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
esockd:open(echo, 5000, [{logger, {error_logger, info}}], {echo_server, start_link, []}).
```

## Benchmark

Benchmark 2.1.0-alpha release on one 8 cores, 32G memory ubuntu/14.04 server from qingcloud.com:

```
250K concurrent connections, 50K messages/sec, 40Mbps In/Out consumed 5G memory, 20% CPU/core
```

## License

The MIT License (MIT)

## Author

Feng Lee <feng@emqtt.io>


