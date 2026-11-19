defmodule HornTest do
  use ExUnit.Case, async: true

  setup do
    Horn.start()
    :ok
  end

  defp q(text), do: Horn.query(text)
  defp one(text, var), do: q(text) |> hd() |> Map.fetch!(var)
  defp all(text, var), do: q(text) |> Enum.map(&Map.fetch!(&1, var))
  defp ok?(text), do: q(text) != []
  defp err(text), do: (try do q(text); :no_error catch {:pl_uncaught, b} -> Horn.show(b) end)

  describe "parser and writer" do
    test "operators, lists, quoting round-trip through writeq" do
      for src <- [
            "a:-b,c;d->e",
            "1-(-1)",
            "- 1",
            "-(-(1))",
            "f(a- -1,[1,2|T],'hello world','\\n')",
            "\\+a",
            "{x,y}",
            "[a|b]",
            "- (1)",
            "a=..b",
            "2**(3^4)",
            "(a,b)",
            "f((a:-b))",
            "'[]'"
          ] do
        ok =
          try do
            ok?("X = (#{src}), with_output_to(atom(A), writeq(X)), atom_to_term(A, Y, _), X =@= Y")
          rescue
            e -> {src, e}
          end

        assert ok == true, inspect({src, ok})
      end
    end

    test "writeq output matches standard spellings" do
      assert one("with_output_to(atom(A), writeq(f(-1, - 1, 1-2-3, 1-(2-3), [a,'B'|c], 'it''s', [])))", "A") ==
               "'f(-1,-(1),1-2-3,1-(2-3),[a,\\'B\\'|c],\\'it\\\\\\'s\\',[])'"

      assert one("with_output_to(atom(A), print((a:-b,c;d)))", "A") == "'a:-b,c;d'"
    end

    test "numbers in different notations" do
      assert one("X is 0'a + 0x10 + 0b101 + 0o7", "X") == "125"
      assert one("X = 1.5e3", "X") == "1500.0"
      assert all("member(X, [1.0e15, 0.00001, 123456789012345.6, -2.5e20, 0.1])", "X") ==
               ["1.0e+15", "1.0e-5", "123456789012345.6", "-2.5e+20", "0.1"]
      assert one("X is 2 ** 100", "X") == "1267650600228229401496703205376"
    end
  end

  describe "control" do
    setup do
      Horn.consult("""
      t(1). t(2). t(3).
      first(X) :- t(X), !.
      ite(X, R) :- ( X > 1 -> R = big ; R = small ).
      cut_in_cond(R) :- ( (t(X), !, X > 1) -> R = yes ; R = no ).
      nested(X) :- t(X), \\+ X = 2.
      soft(X, Y) :- ( t(X) *-> Y = found ; Y = none ).
      soft2(Y) :- ( fail *-> Y = found ; Y = none ).
      tail(0) :- !.
      tail(N) :- N1 is N - 1, tail(N1).
      """)
    end

    test "cut, if-then-else and negation" do
      assert all("first(X)", "X") == ["1"]
      assert all("ite(5, R)", "R") == ["big"]
      assert all("cut_in_cond(R)", "R") == ["no"]
      assert all("nested(X)", "X") == ["1", "3"]
      assert all("call((t(X), !))", "X") == ["1"]
      assert all("findall(X, (t(X), !), L)", "L") == ["[1]"]
      assert all("t(X), call(!)", "X") == ["1", "2", "3"]
    end

    test "soft cut keeps all condition solutions" do
      assert all("soft(X, Y)", "X") == ["1", "2", "3"]
      assert all("soft2(Y)", "Y") == ["none"]
    end

    test "deterministic recursion runs in constant stack" do
      assert ok?("tail(1000000)")
    end
  end

  describe "exceptions" do
    test "catch/throw with unification of the ball" do
      assert one("catch(throw(my(1)), my(X), true)", "X") == "1"
      assert one("catch(X is foo + 1, error(E, _), true)", "E") == "type_error(evaluable,foo/0)"
      assert one("catch(atom_length(X, _), error(E, _), true)", "E") == "instantiation_error"
      assert one("catch(undefined_pred_xyz, error(E, _), true)", "E") == "existence_error(procedure,undefined_pred_xyz/0)"
    end

    test "uncaught errors propagate" do
      assert err("X is 1 // 0") =~ "zero_divisor"
    end

    test "catch is not active after its goal exits" do
      assert err("catch(member(X, [1,2]), _, true), X > 1, throw(late)") == "late"
    end

    test "bindings are undone before the recovery runs" do
      [x] = all("catch((X = 1, throw(e)), e, true)", "X")
      assert String.starts_with?(x, "_G")
    end
  end

  describe "builtins" do
    test "arithmetic follows SWI conventions" do
      assert one("X is -7 // 2", "X") == "-3"
      assert one("X is -7 mod 2", "X") == "1"
      assert one("X is -7 rem 2", "X") == "-1"
      assert one("X is 7 / 2", "X") == "3.5"
      assert one("X is 6 / 2", "X") == "3"
      assert one("X is max(2, 3.0)", "X") == "3.0"
      assert one("X is truncate(-3.7)", "X") == "-3"
    end

    test "term inspection" do
      assert one("foo(a, B) =.. L", "L") =~ ~r/^\[foo,a,_G\d+\]$/
      assert one("functor(T, f, 3)", "T") =~ ~r/^f\(_G\d+,_G\d+,_G\d+\)$/
      assert all("arg(N, f(a, b), X)", "N") == ["1", "2"]
      assert one("copy_term(f(X, Y, X), C)", "C") =~ ~r/^f\((_G\d+),_G\d+,\1\)$/
    end

    test "atoms and strings" do
      assert all("atom_concat(X, Y, ab)", "X") == ["''", "a", "ab"]
      assert all("sub_atom(hello, B, 2, _, S)", "S") == ["he", "el", "ll", "lo"]
      assert one("atomic_list_concat(L, ',', 'a,b,c')", "L") == "[a,b,c]"
      assert one("atomic_list_concat([a, 1, b], '-', A)", "A") == "'a-1-b'"
      assert one("upcase_atom(hello, U)", "U") == "'HELLO'"
      assert one("format(atom(A), \"~a|~t~w~10||~d\", [x, 42, 7])", "A") == "'x|      42|7'"
    end

    test "sorting" do
      assert one("msort([b, 1, a, f(x), 2.0, Z], L)", "L") =~ ~r/^\[_G\d+,1,2\.0,a,b,f\(x\)\]$/
      assert one("sort([c, a, b, a], L)", "L") == "[a,b,c]"
      assert one("sort(0, @>=, [1, 3, 2, 3], L)", "L") == "[3,3,2,1]"
      assert one("keysort([b-1, a-2, b-0], L)", "L") == "[a-2,b-1,b-0]"
      assert one("predsort([O, A, B]>>compare(O, A, B), [3, 1, 2, 1], L)", "L") == "[1,2,3]"
    end

    test "all-solutions predicates" do
      Horn.consult("age(peter, 7). age(ann, 11). age(pat, 8). age(tom, 5). age(mike, 11).")
      assert one("findall(N, age(N, _), L)", "L") == "[peter,ann,pat,tom,mike]"
      assert all("bagof(N, age(N, A), L)", "A") == ["5", "7", "8", "11"]
      assert one("setof(A-N, age(N, A), L)", "L") == "[5-tom,7-peter,8-pat,11-ann,11-mike]"
      assert one("setof(N, A^age(N, A), L)", "L") == "[ann,mike,pat,peter,tom]"
      assert one("aggregate_all(max(A), age(_, A), M)", "M") == "11"
      assert one("aggregate_all(count, age(_, _), C)", "C") == "5"
      assert q("bagof(X, fail, L)") == []
    end

    test "length/2 enumerates" do
      assert all("length(L, N), N >= 2, !", "N") == ["2"]
      assert one("length([a, b|T], 4)", "T") =~ ~r/^\[_G\d+,_G\d+\]$/
    end

    test "between/3 and numlist/3" do
      assert all("between(1, 3, X)", "X") == ["1", "2", "3"]
      assert one("numlist(1, 5, L), sum_list(L, S)", "S") == "15"
    end
  end

  describe "database" do
    test "assert/retract with the logical update view" do
      Horn.consult(":- dynamic c/1.\nc(1). c(2).")
      # clauses added while iterating are not seen by the running call
      assert all("c(X), assertz(c(3))", "X") == ["1", "2"]
      assert all("retract(c(X))", "X") == ["1", "2", "3", "3"]
      assert q("c(_)") == []
    end

    test "clause/2 feeds a meta-interpreter" do
      Horn.consult("""
      app([], L, L).
      app([H|T], L, [H|R]) :- app(T, L, R).
      solve(true) :- !.
      solve((A, B)) :- !, solve(A), solve(B).
      solve(H) :- clause(H, B), solve(B).
      """)

      assert all("solve(app(X, Y, [1, 2]))", "X") == ["[]", "[1]", "[1,2]"]
    end
  end

  describe "DCG" do
    test "grammar rules with pushback-free bodies" do
      Horn.consult("""
      greeting --> [hello], name.
      name --> [world].
      name --> [prolog].
      digits([D|T]) --> digit(D), digits(T).
      digits([D]) --> digit(D).
      digit(D) --> [D], { code_type(D, digit) }.
      """)

      assert all("phrase(greeting, [hello, X])", "X") == ["world", "prolog"]
      assert one("phrase(digits(Ds), `123`, R), atom_codes(A, Ds)", "A") == "'123'"
    end
  end

  describe "lambdas and higher order" do
    test "maplist/foldl with yall lambdas" do
      assert one("maplist([X, Y]>>(Y is X * X), [1, 2, 3], L)", "L") == "[1,4,9]"
      assert one("foldl([X, A0, A]>>(A is A0 + X), [1, 2, 3], 0, S)", "S") == "6"
      assert one("N = 10, include([X]>>(X > N), [5, 15, 20], L)", "L") == "[15,20]"
      assert one("maplist([X, Y, Z]>>(Z is X + Y), [1, 2], [10, 20], L)", "L") == "[11,22]"
    end
  end

  describe "SWI compatibility details" do
    test "[] is not an atom (SWI-Prolog 7)" do
      refute ok?("atom([])")
      assert ok?("atomic([])")
      refute ok?("[] == '[]'")
    end

    test "occurs check flag" do
      assert ok?("\\+ \\+ X = f(X)")
      assert q("set_prolog_flag(occurs_check, true), X = f(X)") == []
    end
  end
end
