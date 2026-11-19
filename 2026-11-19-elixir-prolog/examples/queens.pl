% N-queens: count all solutions and draw the first one.
queens(N, Qs) :- numlist(1, N, Ns), permutation_safe(Ns, [], Qs).

permutation_safe([], Qs, Qs).
permutation_safe(Ns, Placed, Qs) :-
    select(Q, Ns, Rest),
    safe(Q, Placed, 1),
    permutation_safe(Rest, [Q|Placed], Qs).

safe(_, [], _).
safe(Q, [Q1|Qs], D) :-
    Q =\= Q1 + D, Q =\= Q1 - D,
    D1 is D + 1,
    safe(Q, Qs, D1).

draw(Qs) :-
    length(Qs, N),
    forall(member(Q, Qs),
           ( forall(between(1, N, C), (C =:= Q -> write(' Q') ; write(' .'))), nl )).

main :-
    forall(between(4, 9, N),
           ( aggregate_all(count, queens(N, _), C),
             format("~d queens: ~t~d~20| solutions~n", [N, C]) )),
    once(queens(8, Qs)), nl, draw(Qs).

:- initialization(main, main).
