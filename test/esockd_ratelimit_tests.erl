
-module(esockd_ratelimit_tests).

-export([run/1]).

run(Bytes) ->
    Rl = esockd_rate_limit:new(10, 1),
    timer:tc(fun run/2, [Rl, Bytes]).

run(Rl, Bytes) ->
    lists:foldl(fun(_I, Rl0) ->
                    case esockd_rate_limit:check(Bytes, Rl0) of
                        {0, Rl1} ->
                            io:format("~p~n", [Rl1]),
                            timer:sleep(1000), Rl1;
                        {Pause, Rl1} ->
                            io:format("Pause: ~p~n", [{Pause, Rl1}]),
                            timer:sleep(Pause), Rl1
                    end
                end, Rl, lists:seq(1, 10)).
