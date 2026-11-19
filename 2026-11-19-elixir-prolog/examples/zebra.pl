% The Zebra puzzle (Einstein's riddle) solved by pure unification.
right_of(X, Y, [Y, X|_]).
right_of(X, Y, [_|T]) :- right_of(X, Y, T).
next_to(X, Y, L) :- right_of(X, Y, L) ; right_of(Y, X, L).

zebra(Houses) :-
    Houses = [h(_,norwegian,_,_,_), _, h(_,_,_,milk,_), _, _],
    member(h(red,english,_,_,_), Houses),
    member(h(_,spanish,dog,_,_), Houses),
    member(h(green,_,_,coffee,_), Houses),
    member(h(_,ukrainian,_,tea,_), Houses),
    right_of(h(green,_,_,_,_), h(ivory,_,_,_,_), Houses),
    member(h(_,_,snails,_,oldgold), Houses),
    member(h(yellow,_,_,_,kools), Houses),
    next_to(h(_,_,_,_,chesterfield), h(_,_,fox,_,_), Houses),
    next_to(h(_,_,_,_,kools), h(_,_,horse,_,_), Houses),
    member(h(_,_,_,orange_juice,lucky_strike), Houses),
    member(h(_,japanese,_,_,parliament), Houses),
    next_to(h(_,norwegian,_,_,_), h(blue,_,_,_,_), Houses),
    member(h(_,_,zebra,_,_), Houses),
    member(h(_,_,_,water,_), Houses).

main :-
    statistics(inferences, I0), statistics(runtime, [T0|_]),
    zebra(Hs),
    statistics(inferences, I1), statistics(runtime, [T1|_]),
    format("~w~t~10|~w~t~22|~w~t~32|~w~t~46|~w~n", [color, nation, pet, drink, smokes]),
    forall(member(h(C,N,P,D,S), Hs),
           format("~w~t~10|~w~t~22|~w~t~32|~w~t~46|~w~n", [C, N, P, D, S])),
    member(h(_,Z,zebra,_,_), Hs), member(h(_,W,_,water,_), Hs),
    format("~nThe ~w owns the zebra; the ~w drinks water.~n", [Z, W]),
    I is I1 - I0, T is T1 - T0,
    format("(~D inferences, ~d ms)~n", [I, T]).

:- initialization(main, main).
