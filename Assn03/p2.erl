% team aditya mehta, nimalan arulvelan
-module(p2).
-export([main/0]).

-import(math, [pow/2]).


factorial(0, Acc) ->
    Acc;
factorial(N, Acc) when N > 0 ->
    factorial(N - 1, N * Acc).


main() ->
    loop().


loop() ->
    case io:read("Enter a number (0 to quit): ") of
        {error, _} ->
            io:format("not an integer~n"),
            loop();

        {ok, 0} ->
            io:format("Goodbye!~n"),
            ok;

        {ok, Num} when is_integer(Num) ->
            compute(Num),
            loop();

        {ok, _} ->
            io:format("not an integer~n"),
            loop()
    end.


compute(Num) when Num < 0 ->
    Result = pow(abs(Num), 7),
    io:format("~p~n", [Result]);

compute(Num) when Num > 0 ->
    if
        Num rem 7 == 0 ->
            Root = pow(Num, 1/5),
            io:format("~p~n", [Root]);
        true ->
            Result = factorial(Num, 1),
            io:format("~p~n", [Result])
    end.