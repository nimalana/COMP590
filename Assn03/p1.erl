% team aditya mehta, nimalan arulvelan
-module(p1).
-export([main/0]).

-import(math, [pow/2]).


factorial(0, Acc) ->
    Acc;
factorial(N, Acc) when N > 0 ->
    factorial(N - 1, N * Acc).


main() ->
    case io:read("Enter a number: ") of
        {error, _} ->
            io:format("not an integer~n");

        {ok, Num} when is_integer(Num) ->
            compute(Num);

        {ok, _} ->
            io:format("not an integer~n")
    end.


compute(Num) when Num < 0 ->
    Result = pow(abs(Num), 7),
    io:format("~p~n", [Result]);

compute(0) ->
    io:format("0~n");

compute(Num) when Num > 0 ->
    if
        Num rem 7 == 0 ->
            Root = pow(Num, 1/5),
            io:format("~p~n", [Root]);
        true ->
            Result = factorial(Num, 1),
            io:format("~p~n", [Result])
    end.
