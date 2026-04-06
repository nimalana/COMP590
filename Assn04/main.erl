% team aditya mehta, nimalan arulvelan
-module(main).
-export([start/0, serv1/1, serv2/1, serv3/0, serv3_loop/1]).

start() ->
    Serv3 = spawn(?MODULE, serv3, []),
    Serv2 = spawn(?MODULE, serv2, [Serv3]),
    Serv1 = spawn(?MODULE, serv1, [Serv2]),
    input_loop(Serv1).

input_loop(Serv1) ->
    io:format("Enter message (end with period). Type all_done. to quit.~n"),
    case io:read(">> ") of
        {ok, all_done} ->
            Serv1 ! halt,
            io:format("Main exiting.~n");
        {ok, Msg} ->
            Serv1 ! Msg,
            input_loop(Serv1);
        _ ->
            input_loop(Serv1)
    end.

serv1(Next) ->
    receive
        halt ->
            Next ! halt,
            io:format("(serv1) Halting.~n");
        {add, A, B} when is_number(A), is_number(B) ->
            io:format("(serv1) add: ~p + ~p = ~p~n", [A, B, A + B]),
            serv1(Next);
        {sub, A, B} when is_number(A), is_number(B) ->
            io:format("(serv1) sub: ~p - ~p = ~p~n", [A, B, A - B]),
            serv1(Next);
        {mult, A, B} when is_number(A), is_number(B) ->
            io:format("(serv1) mult: ~p * ~p = ~p~n", [A, B, A * B]),
            serv1(Next);
        {'div', A, B} when is_number(A), is_number(B), B =/= 0 ->
            io:format("(serv1) div: ~p / ~p = ~p~n", [A, B, A / B]),
            serv1(Next);
        {neg, A} when is_number(A) ->
            io:format("(serv1) neg: -~p = ~p~n", [A, -A]),
            serv1(Next);
        {sqrt, A} when is_number(A), A >= 0 ->
            io:format("(serv1) sqrt: sqrt(~p) = ~p~n", [A, math:sqrt(A)]),
            serv1(Next);
        Msg ->
            Next ! Msg,
            serv1(Next)
    end.

serv2(Next) ->
    receive
        halt ->
            Next ! halt,
            io:format("(serv2) Halting.~n");
        List when is_list(List), List =/= [], is_integer(hd(List)) ->
            Numbers = [X || X <- List, is_number(X)],
            io:format("(serv2) sum of integer list: ~p~n", [lists:sum(Numbers)]),
            serv2(Next);
        List when is_list(List), List =/= [], is_float(hd(List)) ->
            Numbers = [X || X <- List, is_number(X)],
            Product = lists:foldl(fun(X, Acc) -> X * Acc end, 1, Numbers),
            io:format("(serv2) product of float list: ~p~n", [Product]),
            serv2(Next);
        Msg ->
            Next ! Msg,
            serv2(Next)
    end.

serv3() ->
    serv3_loop(0).

serv3_loop(Count) ->
    receive
        halt ->
            io:format("(serv3) Unprocessed message count = ~p~n", [Count]),
            io:format("(serv3) Halting.~n");
        {error, Reason} ->
            io:format("(serv3) Error: ~p~n", [Reason]),
            serv3_loop(Count);
        Msg ->
            io:format("(serv3) Not handled: ~p~n", [Msg]),
            serv3_loop(Count + 1)
    end.