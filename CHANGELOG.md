
ChangeLog
==================

0.2.0-beta (2015/03/03)
------------------------

esockd.erl: add get_max_clients/1, set_max_clients/2, get_current_clients/1

esockd_connection.erl: 'erlang:apply(M, F, [SockArgs|Args])'

esockd_acceptor.erl: log protocol name

0.1.1-beta (2015/03/01)
------------------------

Doc: update README.md

0.1.0-beta (2015/03/01)
------------------------

Add more exmaples

Add esockd_server.erl

Redesign esockd_manager.erl, esockd_connection_sup.erl

0.1.0-alpha (2015/02/28)
------------------------

First public release

TCP/SSL Socket Server

0.0.2 (2014/12/07)
------------------------

acceptor suspend 100ms when accept 'emfile' error

esockd_client_sup to control max connections

esockd_client_sup: 'M:go(Client, Sock)' to tell gen_server the socket is ready

esockd_acceptor: add 'tune_buffer_size'

0.0.1 (2014/11/30)
------------------------

redesign listener api

first release...

