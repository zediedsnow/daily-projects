defmodule Horn.Prelude do
  @moduledoc "The part of the standard library written in Prolog itself."

  def source do
    ~S"""
    once(G) :- call(G), !.
    ignore(G) :- (call(G) -> true ; true).

    append([], L, L).
    append([H|T], L, [H|R]) :- append(T, L, R).
    append(Ls, L) :- foldl_app_(Ls, L).
    foldl_app_([], []).
    foldl_app_([L|Ls], As) :- append(L, Ws, As), foldl_app_(Ls, Ws).

    member(X, [Y|Ys]) :- member_(Ys, X, Y).
    member_(_, X, X).
    member_([Y|Ys], X, _) :- member_(Ys, X, Y).
    memberchk(X, L) :- member(X, L), !.

    select(X, [X|T], T).
    select(X, [H|T], [H|R]) :- select(X, T, R).
    selectchk(X, L, R) :- select(X, L, R), !.
    select(X, Xs, Y, Ys) :- select4_(Xs, X, Y, Ys).
    select4_([X|T], X, Y, [Y|T]).
    select4_([H|T], X, Y, [H|T2]) :- select4_(T, X, Y, T2).

    nth0(I, L, E) :- nth_(L, 0, I, E).
    nth1(I, L, E) :- nth_(L, 1, I, E).
    nth_(L, B, I, E) :- integer(I), !, Skip is I - B, Skip >= 0, nth_fixed_(Skip, L, E).
    nth_([H|T], B, I, E) :- nth_var_(T, H, B, I, E).
    nth_fixed_(0, [E|_], E) :- !.
    nth_fixed_(N, [_|T], E) :- N1 is N - 1, nth_fixed_(N1, T, E).
    nth_var_(_, H, B, B, H).
    nth_var_([H|T], _, B, I, E) :- B1 is B + 1, nth_var_(T, H, B1, I, E).

    last([X], X) :- !.
    last([_|T], X) :- last(T, X).
    delete([], _, []).
    delete([H|T], X, R) :- ( H \= X -> R = [H|R1] ; R = R1 ), delete(T, X, R1).
    exclude(_, [], []).
    exclude(P, [H|T], R) :- ( call(P, H) -> R = R1 ; R = [H|R1] ), exclude(P, T, R1).
    include(_, [], []).
    include(P, [H|T], R) :- ( call(P, H) -> R = [H|R1] ; R = R1 ), include(P, T, R1).
    partition(_, [], [], []).
    partition(P, [H|T], I, E) :-
        ( call(P, H) -> I = [H|I1], E = E1 ; I = I1, E = [H|E1] ), partition(P, T, I1, E1).
    subtract([], _, []).
    subtract([H|T], L, R) :- ( memberchk(H, L) -> R = R1 ; R = [H|R1] ), subtract(T, L, R1).
    intersection([], _, []).
    intersection([H|T], L, R) :- ( memberchk(H, L) -> R = [H|R1] ; R = R1 ), intersection(T, L, R1).
    union([], L, L).
    union([H|T], L, R) :- ( memberchk(H, L) -> R = R1 ; R = [H|R1] ), union(T, L, R1).
    permutation([], []).
    permutation(L, [H|T]) :- select(H, L, R), permutation(R, T).
    flatten(L, F) :- flatten_(L, [], F0), !, F = F0.
    flatten_(V, T, [V|T]) :- var(V), !.
    flatten_([], T, T) :- !.
    flatten_([H|Rest], T, F) :- !, flatten_(H, F1, F), flatten_(Rest, T, F1).
    flatten_(A, T, [A|T]).
    max_list([H|T], M) :- foldl(max_l_, T, H, M).
    min_list([H|T], M) :- foldl(min_l_, T, H, M).
    max_l_(X, A, M) :- M is max(X, A).
    min_l_(X, A, M) :- M is min(X, A).
    max_member(M, L) :- max_mem_(L, M).
    max_mem_([H|T], M) :- max_mem_(T, H, M).
    max_mem_([], M, M).
    max_mem_([H|T], M0, M) :- ( H @> M0 -> max_mem_(T, H, M) ; max_mem_(T, M0, M) ).
    min_member(M, L) :- min_mem_(L, M).
    min_mem_([H|T], M) :- min_mem_(T, H, M).
    min_mem_([], M, M).
    min_mem_([H|T], M0, M) :- ( H @< M0 -> min_mem_(T, H, M) ; min_mem_(T, M0, M) ).
    pairs_keys_values([], [], []).
    pairs_keys_values([K-V|T], [K|Ks], [V|Vs]) :- pairs_keys_values(T, Ks, Vs).
    pairs_keys([], []).
    pairs_keys([K-_|T], [K|Ks]) :- pairs_keys(T, Ks).
    pairs_values([], []).
    pairs_values([_-V|T], [V|Vs]) :- pairs_values(T, Vs).

    maplist(_, []).
    maplist(G, [A|As]) :- call(G, A), maplist(G, As).
    maplist(_, [], []).
    maplist(G, [A|As], [B|Bs]) :- call(G, A, B), maplist(G, As, Bs).
    maplist(_, [], [], []).
    maplist(G, [A|As], [B|Bs], [C|Cs]) :- call(G, A, B, C), maplist(G, As, Bs, Cs).
    maplist(_, [], [], [], []).
    maplist(G, [A|As], [B|Bs], [C|Cs], [D|Ds]) :- call(G, A, B, C, D), maplist(G, As, Bs, Cs, Ds).
    foldl(G, L, A0, A) :- foldl_(L, G, A0, A).
    foldl_([], _, A, A).
    foldl_([X|Xs], G, A0, A) :- call(G, X, A0, A1), foldl_(Xs, G, A1, A).
    foldl(G, L1, L2, A0, A) :- foldl_(L1, L2, G, A0, A).
    foldl_([], [], _, A, A).
    foldl_([X|Xs], [Y|Ys], G, A0, A) :- call(G, X, Y, A0, A1), foldl_(Xs, Ys, G, A1, A).
    predsort(P, L, Sorted) :-
        length(L, N),
        ( N < 2 -> Sorted = L
        ; H is N // 2, length(Front, H), append(Front, Back, L),
          predsort(P, Front, S1), predsort(P, Back, S2), predmerge_(P, S1, S2, Sorted) ).
    predmerge_(_, [], L, L) :- !.
    predmerge_(_, L, [], L) :- !.
    predmerge_(P, [H1|T1], [H2|T2], R) :-
        call(P, O, H1, H2),
        predmerge__(O, P, H1, H2, T1, T2, R).
    predmerge__(<, P, H1, H2, T1, T2, [H1|R]) :- predmerge_(P, T1, [H2|T2], R).
    predmerge__(>, P, H1, H2, T1, T2, [H2|R]) :- predmerge_(P, [H1|T1], T2, R).
    predmerge__(=, P, H1, _, T1, T2, [H1|R]) :- predmerge_(P, T1, T2, R).

    concat_atom(L, R) :- atomic_list_concat(L, R).
    concat_atom(L, Sep, R) :- atomic_list_concat(L, Sep, R).

    % --- yall lambdas: [X,Y]>>Goal and Free/[X]>>Goal ---------------------
    '>>'(Ps, B) :- yall_(Ps, B, []).
    '>>'(Ps, B, A1) :- yall_(Ps, B, [A1]).
    '>>'(Ps, B, A1, A2) :- yall_(Ps, B, [A1, A2]).
    '>>'(Ps, B, A1, A2, A3) :- yall_(Ps, B, [A1, A2, A3]).
    '>>'(Ps, B, A1, A2, A3, A4) :- yall_(Ps, B, [A1, A2, A3, A4]).
    '>>'(Ps, B, A1, A2, A3, A4, A5) :- yall_(Ps, B, [A1, A2, A3, A4, A5]).
    '>>'(Ps, B, A1, A2, A3, A4, A5, A6) :- yall_(Ps, B, [A1, A2, A3, A4, A5, A6]).
    yall_(Free/Ps, B, Args) :- !,
        copy_term(Free/Ps>>B, Free2/Ps2>>B2), Free2 = Free,
        yall_bind_(Ps2, Args, Rest), yall_call_(B2, Rest).
    yall_(Ps, B, Args) :-
        copy_term(Ps>>B, Ps2>>B2),
        yall_bind_(Ps2, Args, Rest), yall_call_(B2, Rest).
    yall_bind_([], Rest, Rest) :- !.
    yall_bind_([P|Ps], [A|As], Rest) :- !, P = A, yall_bind_(Ps, As, Rest).
    yall_bind_(_, [], []).
    yall_call_(G, []) :- !, call(G).
    yall_call_(G, Extra) :- G1 =.. [call, G|Extra], call(G1).

    % --- DCG translation (Definite Clause Grammars) -------------------------
    dcg_translate_rule((H, PB --> B), (H1 :- Body)) :- !,
        dcg_nonterminal_(H, S0, S, H1),
        dcg_body_(B, S0, S1, B1),
        dcg_terminals_(PB, S, S1, PBG),
        Body = (B1, PBG).
    dcg_translate_rule((H --> B), (H1 :- B1)) :-
        dcg_nonterminal_(H, S0, S, H1),
        dcg_body_(B, S0, S, B1).

    dcg_nonterminal_(H, S0, S, G) :- H =.. L, append(L, [S0, S], L1), G =.. L1.
    dcg_terminals_(List, S0, S, S0 = Full) :- append(List, S, Full).

    dcg_body_(V, S0, S, phrase(V, S0, S)) :- var(V), !.
    dcg_body_((A, B), S0, S, (GA, GB)) :- !, dcg_body_(A, S0, S1, GA), dcg_body_(B, S1, S, GB).
    dcg_body_((A ; B), S0, S, (GA ; GB)) :- !, dcg_body_(A, S0, S, GA), dcg_body_(B, S0, S, GB).
    dcg_body_((A | B), S0, S, (GA ; GB)) :- !, dcg_body_(A, S0, S, GA), dcg_body_(B, S0, S, GB).
    dcg_body_((A -> B), S0, S, (GA -> GB)) :- !, dcg_body_(A, S0, S1, GA), dcg_body_(B, S1, S, GB).
    dcg_body_(\+ A, S0, S, (\+ GA, S0 = S)) :- !, dcg_body_(A, S0, _, GA).
    dcg_body_({G}, S0, S, (G, S0 = S)) :- !.
    dcg_body_(!, S0, S, (!, S0 = S)) :- !.
    dcg_body_([], S0, S, S0 = S) :- !.
    dcg_body_(L, S0, S, S0 = Full) :- L = [_|_], !, append(L, S, Full).
    dcg_body_(call(G0), S0, S, call(G0, S0, S)) :- !.
    dcg_body_(G0, S0, S, G) :- G0 =.. [call|Args], !, append(Args, [S0, S], A1), G =.. [call|A1].
    dcg_body_(NT, S0, S, G) :- dcg_nonterminal_(NT, S0, S, G).

    phrase(G, L) :- phrase(G, L, []).
    phrase(G, L, R) :- dcg_body_(G, S0, S, Goal), S0 = L, S = R, call(Goal).
    """
  end
end
