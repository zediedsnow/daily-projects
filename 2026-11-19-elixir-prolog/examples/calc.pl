% A calculator: tokenizer and recursive-descent parser written as DCGs,
% with left-associative operators, unary minus, variables and error reporting.
:- set_prolog_flag(double_quotes, codes).

tokens([T|Ts]) --> blanks, token(T), !, tokens(Ts).
tokens([]) --> blanks.

blanks --> [C], { code_type(C, space) }, !, blanks.
blanks --> [].

token(num(N)) --> digits(Ds), { Ds = [_|_], number_codes(N, Ds) }.
token(id(A)) --> [C], { code_type(C, alpha), \+ code_type(C, digit) }, idrest(Cs), { atom_codes(A, [C|Cs]) }.
token(op(Op)) --> [C], { member(C, "+-*/^()=,"), atom_codes(Op, [C]) }.

digits([D|Ds]) --> [D], { code_type(D, digit) }, !, digits(Ds).
digits([]) --> [].
idrest([C|Cs]) --> [C], { code_type(C, csym) }, !, idrest(Cs).
idrest([]) --> [].

% grammar: stmt := id '=' expr | expr
stmt(assign(V, E)) --> [id(V), op(=)], !, expr(E).
stmt(E) --> expr(E).

expr(E) --> term(T), expr_rest(T, E).
expr_rest(Acc, E) --> [op(Op)], { member(Op, [+, -]) }, !, term(T),
    { A1 =.. [Op, Acc, T] }, expr_rest(A1, E).
expr_rest(E, E) --> [].

term(E) --> unary(F), term_rest(F, E).
term_rest(Acc, E) --> [op(Op)], { member(Op, [*, /]) }, !, unary(F),
    { A1 =.. [Op, Acc, F] }, term_rest(A1, E).
term_rest(E, E) --> [].

unary(-(E)) --> [op(-)], !, unary(E).          % so -2^2 = -(2^2)
unary(E) --> power(E).
power(E) --> primary(B), ( [op(^)] -> unary(X), { E = B^X } ; { E = B } ).   % right assoc

primary(N) --> [num(N)], !.
primary(call(F, Args)) --> [id(F), op('(')], !, args(Args), [op(')')].
primary(var(V)) --> [id(V)], !.
primary(E) --> [op('(')], expr(E), [op(')')].

args([A|As]) --> expr(A), ( [op(',')] -> args(As) ; { As = [] } ).

% evaluation, environment kept in a global variable
eval(N, _, N) :- number(N), !.
eval(var(V), Env, X) :- ( memberchk(V-X, Env) -> true ; throw(unbound(V)) ).
eval(call(F, As), Env, X) :- !, maplist([A, V]>>eval(A, Env, V), As, Vs), apply_fn(F, Vs, X).
eval(E, Env, X) :- E =.. [Op|As], maplist(eval_in(Env), As, Vs), E2 =.. [Op|Vs], X is E2.
eval_in(Env, A, V) :- eval(A, Env, V).

apply_fn(max, [A, B], X) :- !, X is max(A, B).
apply_fn(sqrt, [A], X) :- !, X is sqrt(A).
apply_fn(fact, [N], X) :- !, numlist(1, N, L), foldl([A, B, C]>>(C is A*B), L, 1, X).
apply_fn(F, Vs, _) :- length(Vs, N), throw(unknown_function(F/N)).

run(Line, Env0, Env) :-
    atom_codes(Line, Cs),
    (   phrase(tokens(Ts), Cs), phrase(stmt(S), Ts)
    ->  catch(exec(S, Env0, Env), Err, (report(Err), Env = Env0))
    ;   format("  syntax error~n"), Env = Env0
    ).

report(error(Formal, _)) :- !, format("  error: ~w~n", [Formal]).
report(Ball) :- format("  error: ~w~n", [Ball]).

exec(assign(V, E), Env0, [V-X|Env0]) :- !, eval(E, Env0, X), format("  ~w = ~w~n", [V, X]).
exec(E, Env, Env) :- eval(E, Env, X), format("  ~w~n", [X]).

main :-
    Lines = ['1 + 2 * 3', '(1 + 2) * 3', '2 ^ 3 ^ 2', '-2 ^ 2', 'x = 7 / 2', 'y = x * 4 - -1',
             'max(x, y) + sqrt(16)', 'fact(25)', '10 / 0', 'z + 1', 'nope(1)', '3 + * 4'],
    foldl([L, E0, E]>>(format("> ~w~n", [L]), run(L, E0, E)), Lines, [], _).

:- initialization(main, main).
