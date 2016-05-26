
==================================
Welcome to eSockd's Documentation!
==================================

eSockd - Erlang General Non-blocking TCP/SSL Socket Server.

--------
Features
--------

* General Non-blocking TCP/SSL Socket Server
* Acceptor Pool and Asynchronous TCP Accept
* Parameterized Connection Module
* Max connections management
* Allow/Deny by peer address
* Keepalive Support
* Rate Limit
* IPv6 Support

-----
Usage
-----

A Simple Echo Server:

.. code:: erlang

    -module(echo_server).

    -export([start_link/1]).

    start_link(Conn) ->
       {ok, spawn_link(?MODULE, init, [Conn])}.
          
    init(Conn) ->
        {ok, NewConn} = Conn:wait(), loop(NewConn).

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

Setup Echo Server:

.. code:: erlang

    %% Start eSockd application
    ok = esockd:start().

    Options = [{acceptors, 10},
               {max_clients, 1024},
               {sockopts, [binary,
                           {reuseaddr, true},
                           {nodelay, false}]}].

    MFArgs = {echo_server, start_link, []},

    esockd:open(echo, 5000, Options, MFArgs).

--------
Examples
--------

+---------------------+----------------------------+
| Example             | Description                |
+---------------------+----------------------------+
| examples/async_recv | prim_net async recv/send   |
+---------------------+----------------------------+
| examples/gen_server | gen_server behaviour       |
+---------------------+----------------------------+
| examples/simple     | simple echo server         |
+---------------------+----------------------------+
| examples/ssl        | ssl echo server            |
+---------------------+----------------------------+

---
API
---

Start
-----

.. code:: erlang

    esockd:start().

Open a Listener
---------------

.. code:: erlang

    esockd:open(echo, 5000, [{sockopts, [binary, {reuseaddr, true}]}], {echo_server, start_link, []}).

    esockd:open(echo, {"127.0.0.1", 6000}, [{sockopts, [binary, {reuseaddr, true}]}], {echo_server, start_link, []}).

Spec:

.. code:: erlang

    -spec(open(Protocol, ListenOn, Options, MFArgs) -> {ok, pid()} | {error, any()} when
               Protocol  :: atom(),
               ListenOn  :: inet:port_number() | {inet:ip_address() | string(), inet:port_number()}),
               Options	  :: [option()],
               MFArgs    :: esockd:mfargs()).

Options:

.. code:: erlang

    -type(option() :: {acceptors, pos_integer()}
                    | {max_clients, pos_integer()}
                    | {tune_buffer, false | true}
                    | {access, [esockd_access:rule()]}
                    | {logger, atom() | {atom(), atom()}}
                    | {ssl, [ssl:ssloption()]}
                    | {connopts, [{rate_limit, string()}]}
                    | {sockopts, [gen_tcp:listen_option()]}).

MFArgs:

.. code:: erlang

    -type(mfargs() :: atom() | {atom(), atom()} | {module(), atom(), [term()]}).


Get Setting and Stats
---------------------

Get stats::

    esockd:get_stats({echo, 5000}).

Get acceptors::

    esockd:get_acceptors({echo, {"127.0.0.1", 6000}}).

Get/Set max clients::

    esockd:get_max_clients({echo, 5000}).
    esockd:set_max_clients({echo, 5000}, 100000).

Allow/Deny
----------

Same to Allow/Deny Syntax of nginx::

    allow address | CIDR | all;

    deny address | CIDR | all;

allow/deny by options::

    esockd:open(echo, 5000, [
        {access, [{deny, "192.168.1.1"},
                  {allow, "192.168.1.0/24"},
                  {deny, all}]}], MFArgs).

allow/deny by API::

    esockd:allow({echo, 5000}, all).
    esockd:allow({echo, 5000}, "192.168.0.1/24").
    esockd:deny({echo, 5000}, all).
    esockd:deny({echo, 5000}, "10.10.0.0/16").

Close
-----

.. code:: erlang

    esockd:close(echo, 5000).
    esockd:close(echo, {"127.0.0.1", 6000}).

Spec::

    -spec(close(Protocol, ListenOn) -> ok when
                Protocol :: atom(),
                ListenOn :: inet:port_number() | {inet:ip_address() | string(), inet:port_number()}).

---
SSL
---

Connecting to ssl_echo_server::

    openssl s_client -connect 127.0.0.1:5000 -ssl3

    openssl s_client -connect 127.0.0.1:5000 -tls1

------
Logger
------

eSockd depends [gen_logger](https://github.com/emqtt/gen_logger).

Logger environment::

     {esockd, [
        {logger, {lager, info}}
     ]},

Logger option::

    esockd:open(echo, 5000, [{logger, {error_logger, info}}], {echo_server, start_link, []}).

.. _design:

------
Design
------

Supervisor Tree
---------------

.. code::

    esockd_sup 
        -> esockd_listener_sup 
            -> esockd_listener
            -> esockd_acceptor_sup 
                -> esockd_acceptor
                -> esockd_acceptor
                -> ......
            -> esockd_connection_sup
                -> esockd_connection
                -> esockd_connection
                -> ......

Listener
--------


Acceptor
--------

1. Acceptor Pool

2. Sleep for a while when e{n, m}file errors happened

Connection Sup
--------------

1. Create a connection, and let it run...

2. Control max connections

3. Count active connections

4. Count shutdown reasons

Server
------


----
CIDR
----

`CIDR`_ Wiki

.. _CIDR: https://en.wikipedia.org/wiki/Classless_Inter-Domain_Routing

---------
Benchmark
---------

Benchmark 2.1.0-alpha release on one 8 cores, 32G memory ubuntu/14.04 server from qingcloud.com::

    250K concurrent connections, 50K messages/sec, 40Mbps In/Out consumed 5G memory, 20% CPU/core

