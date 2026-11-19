% Classic naive-reverse benchmark: reports logical inferences per second.
app([], L, L).
app([H|T], L, [H|R]) :- app(T, L, R).
nrev([], []).
nrev([H|T], R) :- nrev(T, RT), app(RT, [H], R).

range(N, N, [N]) :- !.
range(I, N, [I|T]) :- I1 is I + 1, range(I1, N, T).

bench(Reps) :-
    range(1, 30, L),
    statistics(runtime, [T0|_]),
    ( between(1, Reps, _), nrev(L, _), fail ; true ),
    statistics(runtime, [T1|_]),
    T is max(1, T1 - T0),
    LI is Reps * 496,                       % nrev of 30 elements = 496 LI
    LIPS is LI * 1000 // T,
    format("nrev30 x ~D: ~D ms, ~D LIPS~n", [Reps, T, LIPS]).

fib(0, 0). fib(1, 1).
fib(N, F) :- N > 1, A is N - 1, B is N - 2, fib(A, FA), fib(B, FB), F is FA + FB.

main :-
    bench(20000),
    statistics(runtime, [T0|_]), fib(21, F), statistics(runtime, [T1|_]),
    T is T1 - T0, format("fib(21) = ~d in ~d ms~n", [F, T]).

:- initialization(main, main).
