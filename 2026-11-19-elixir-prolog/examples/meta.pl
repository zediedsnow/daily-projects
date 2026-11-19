% A meta-interpreter (Prolog in Prolog) that builds proof trees using
% clause/2, plus a depth-bounded variant that turns an infinite loop into
% a reported failure.
:- dynamic parent/2, ancestor/2, loop/1.

parent(tom, bob). parent(bob, ann). parent(ann, joe). parent(bob, pat).
ancestor(X, Y) :- parent(X, Y).
ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).
loop(X) :- loop(X).

builtin(G) :- predicate_property_(G), !.
predicate_property_(_ = _). predicate_property_(_ is _). predicate_property_(true).

prove(true, true) :- !.
prove((A, B), (PA, PB)) :- !, prove(A, PA), prove(B, PB).
prove(G, G-builtin) :- builtin(G), !, call(G).
prove(G, G-Sub) :- clause(G, Body), prove(Body, Sub).

% depth-bounded: fails with a note instead of looping forever
dprove(_, D) :- D < 0, !, throw(depth_exceeded).
dprove(true, _) :- !.
dprove((A, B), D) :- !, dprove(A, D), dprove(B, D).
dprove(G, D) :- clause(G, Body), D1 is D - 1, dprove(Body, D1).

show(T) :- show(T, 0).
show((A, B), I) :- !, show(A, I), show(B, I).
show(G-builtin, I) :- !, tab(I), format("~w  (builtin)~n", [G]).
show(G-true, I) :- !, tab(I), format("~w  (fact)~n", [G]).
show(G-Sub, I) :- tab(I), format("~w~n", [G]), I2 is I + 2, show(Sub, I2).

main :-
    format("Why is tom an ancestor of joe?~n"),
    prove(ancestor(tom, joe), P), show(P), nl,
    findall(Y, prove(ancestor(bob, Y), _), Ys),
    format("bob's descendants via the meta-interpreter: ~w~n", [Ys]),
    catch(dprove(loop(1), 50), E, (format("loop(1): ~w after 50 levels~n", [E]))).

:- initialization(main, main).
