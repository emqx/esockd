-module(ssl_echo_server_app).

-behaviour(application).

-export([start/0]).

%% Application callbacks
-export([start/2, stop/1]).

start() ->
    application:start(ssl_echo_server).

%% ===================================================================
%% Application callbacks
%% ===================================================================
start(_StartType, _StartArgs) ->
    ok = esockd:start(),
    {ok, Sup} = ssl_echo_server_sup:start_link(),
    SslOpts = [{certfile, "./crt/demo.crt"}, {keyfile,  "./crt/demo.key"}], %{cacertfile, "./crt/cacert.pem"}, 
    SockOpts = [binary, {reuseaddr, true}, {acceptor_pool, 4}, {max_clients, 1000}, {ssl, SslOpts}],
    {ok, _} = esockd:open('echo/ssl', 5000, SockOpts, ssl_echo_server),
    {ok, Sup}.

stop(_State) ->
    ok.

