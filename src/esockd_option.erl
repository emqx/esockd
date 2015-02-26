
-module(esockd_option).

-export([sockopts/1,
	     getopt/2, getopt/3]).

sockopts(Opts) ->
	sockopts(Opts, []).

sockopts([], Acc) ->
	Acc;
sockopts([{max_connections, _}|Opts], Acc) ->
	sockopts(Opts, Acc);
sockopts([{acceptor_pool, _}|Opts], Acc) ->
	sockopts(Opts, Acc);
sockopts([H|Opts], Acc) ->
	sockopts(Opts, [H|Acc]).

getopt(K, Opts) ->
	proplists:get_value(K, Opts).

getopt(K, Opts, Def) ->
	proplists:get_value(K, Opts, Def).

