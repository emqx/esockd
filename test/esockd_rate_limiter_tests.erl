
-module(esockd_rate_limiter_tests).

-export([run/1]).

run(Bytes) ->
    Rl = esockd_rate_limiter:new(10, 1),
    timer:tc(fun run/2, [Rl, Bytes]).

run(Rl, Bytes) ->
    lists:foldl(fun(_I, Rl0) ->
            case esockd_rate_limiter:check(Rl0, Bytes) of
                {0, Rl1} ->
                    io:format("~p~n", [Rl1]),
                    timer:sleep(1000), Rl1;
                {Pause, Rl1} ->
                    io:format("~p,~w~n", [Rl1, Pause]),
                    timer:sleep(Pause), Rl1
            end
        end, Rl, lists:seq(1, 10)).
