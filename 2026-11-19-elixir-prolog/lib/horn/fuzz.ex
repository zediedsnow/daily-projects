defmodule Horn.Fuzz do
  @moduledoc """
  Differential fuzzer: generates random (terminating) Prolog programs and
  queries, runs them on both Horn and SWI-Prolog, and diffs the answers.

  Programs exercise cut (in clause bodies, if-then-else conditions, \\+,
  call/N, findall), soft-cut `*->`, catch/throw with error terms from
  builtins, arithmetic errors, assert/retract under the logical update view,
  first-argument indexing, and list library predicates.

  Termination is guaranteed by construction: predicate `p_k` only calls
  `p_j` with `j < k`, recursive library predicates are only called with
  proper-list arguments, and the occurs check is switched on in both
  systems so cyclic terms cannot arise.
  """

  @harness ~S"""
  :- set_prolog_flag(occurs_check, true).
  :- set_prolog_flag(double_quotes, codes).
  :- discontiguous fz_query/3.

  fz_main :- forall(fz_query(Id, V, G), fz_run(Id, V, G)).

  fz_run(Id, V, G) :-
      write(Id), write(': '),
      catch(( call_with_inference_limit(findall(V, G, L), 300000, R),
              ( R == inference_limit_exceeded -> write('LIMIT')
              ; fz_number(L), fz_show_list(L, 0) ) ),
            E,
            ( write('EXC '), fz_exc(E) )),
      nl.

  fz_exc(error(F, _)) :- !, fz_number(F), fz_show(F).
  fz_exc(B) :- fz_number(B), fz_show(B).

  fz_number(T) :- term_variables(T, Vs), fz_bind(Vs, 0).
  fz_bind([], _).
  fz_bind(['$V'(N)|Vs], N) :- N1 is N + 1, fz_bind(Vs, N1).

  fz_show_list([], _) :- write('.').
  fz_show_list([_|_], 40) :- !, write('...').
  fz_show_list([X|Xs], N) :- fz_show(X), write(' '), N1 is N + 1, fz_show_list(Xs, N1).

  fz_show('$V'(N)) :- !, write('_'), write(N).
  fz_show(T) :- compound(T), !,
      T =.. [F|Args], write(F), write('('), fz_args(Args), write(')').
  fz_show(T) :- write(T).
  fz_args([A]) :- !, fz_show(A).
  fz_args([A|As]) :- fz_show(A), write(','), fz_args(As).
  """

  # =============================================================================
  # Driver
  # =============================================================================

  def run(n, seed, jobs) do
    batch = 100
    batches = div(n + batch - 1, batch)
    dir = Path.join(System.tmp_dir!(), "horn_fuzz_#{seed}")
    File.mkdir_p!(dir)
    t0 = System.monotonic_time(:millisecond)
    IO.puts("fuzzing #{n} programs (#{n * 3} queries) in #{batches} batches, seed #{seed}, #{jobs} jobs")

    results =
      1..batches
      |> Task.async_stream(fn b -> run_batch(dir, seed, b, batch) end, max_concurrency: jobs, timeout: :infinity, ordered: false)
      |> Enum.map(fn {:ok, r} -> r end)

    stats =
      Enum.reduce(results, %{queries: 0, diffs: [], exc: 0, sols: 0}, fn r, acc ->
        %{acc | queries: acc.queries + r.queries, diffs: acc.diffs ++ r.diffs, exc: acc.exc + r.exc, sols: acc.sols + r.sols}
      end)

    dt = System.monotonic_time(:millisecond) - t0

    IO.puts("""
    queries compared:      #{stats.queries}
    answers compared:      #{stats.sols}
    queries raising errors #{stats.exc}  (error terms compared too)
    mismatches:            #{length(stats.diffs)}
    time:                  #{Float.round(dt / 1000, 1)} s
    """)

    for {file, id, ours, theirs} <- Enum.take(stats.diffs, String.to_integer(System.get_env("SHOW", "5"))) do
      q = file |> File.read!() |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "fz_query('#{id}'"))
      IO.puts("MISMATCH #{file} query #{id}\n  #{q}\n  horn:  #{ours}\n  swipl: #{theirs}")
    end

    if stats.diffs != [], do: throw({:pl_halt, 1})
    :ok
  end

  defp run_batch(dir, seed, b, size) do
    :rand.seed(:exsss, {seed, b, 4242})
    progs = for i <- 1..size, do: program((b - 1) * size + i)
    text = @harness <> Enum.join(progs, "\n")
    file = Path.join(dir, "batch_#{b}.pl")
    File.write!(file, text)

    {swi, _} = System.cmd("sh", ["-c", "swipl -q -g fz_main -t halt \"$1\" 2>/dev/null", "sh", file])

    task =
      Task.async(fn ->
        Horn.Builtins.capture(fn ->
          Horn.Engine.init()
          Horn.Engine.consult_string(text)
          Horn.Engine.once("fz_main", %{})
        end)
        |> elem(1)
      end)

    ours =
      case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, out} -> out
        _ -> IO.puts(:stderr, "horn timed out on #{file}"); ""
      end

    a = parse_lines(ours)
    w = parse_lines(swi)

    # a query that hits the inference limit in either system (e.g. an
    # assert-driven infinite loop) is skipped, together with the later
    # queries of the same program, whose dynamic database may now differ
    limited =
      for {id, line} <- Map.merge(w, a), line == "LIMIT", into: MapSet.new(), do: prog(id)

    skip = fn id -> MapSet.member?(limited, prog(id)) end

    diffs =
      for {id, line} <- w, not skip.(id), Map.get(a, id) != line, do: {file, id, Map.get(a, id, "<missing>"), line}

    extra = for {id, line} <- a, not skip.(id), not Map.has_key?(w, id), do: {file, id, line, "<missing>"}
    w = Map.reject(w, fn {id, _} -> skip.(id) end)

    %{
      queries: map_size(w),
      diffs: diffs ++ extra,
      exc: Enum.count(w, fn {_, l} -> String.starts_with?(l, "EXC") end),
      sols: w |> Enum.map(fn {_, l} -> l |> String.split(" ") |> length() |> Kernel.-(1) end) |> Enum.sum()
    }
  end

  defp prog(id), do: id |> String.split(".") |> hd()

  defp parse_lines(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ": ", parts: 2) do
        [id, rest] -> [{id, rest}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  # =============================================================================
  # Program generator
  # =============================================================================

  defp r(n), do: :rand.uniform(n) - 1
  defp pick(list), do: Enum.at(list, r(length(list)))
  defp chance(p), do: :rand.uniform() < p

  def program(id) do
    np = 2 + r(4)
    arities = for _ <- 1..np, do: r(4)
    pfx = "t#{id}_"
    ctx = %{pfx: pfx, arities: arities}

    clauses =
      for {ar, k} <- Enum.with_index(arities) do
        for _ <- 1..(1 + r(4)) do
          vars = Enum.take(~w(A B C D E), 2 + r(4))
          head = call_text("#{pfx}p#{k}", for(_ <- 1..ar//1, do: term(2, vars)))
          body = for _ <- 1..r(4)//1, do: goal(2, %{ctx | arities: Enum.take(arities, k)}, vars)

          case body do
            [] -> head <> "."
            _ -> head <> " :- " <> Enum.join(body, ", ") <> "."
          end
        end
      end

    dyn = ":- dynamic #{pfx}d/1.\n#{pfx}d(a).\n#{pfx}d(f(b)).\n"

    queries =
      for q <- 1..3 do
        vars = ~w(X Y Z)
        g = Enum.map_join(1..(1 + r(3)), ", ", fn _ -> goal(3, ctx, vars) end)
        "fz_query('#{id}.#{q}', v(X,Y,Z), (#{g}))."
      end

    dyn <> Enum.join(List.flatten(clauses), "\n") <> "\n" <> Enum.join(queries, "\n") <> "\n"
  end

  defp call_text(name, []), do: name
  defp call_text(name, args), do: name <> "(" <> Enum.join(args, ", ") <> ")"

  defp term(d, []) do
    case r(if d <= 0, do: 2, else: 6) do
      0 -> pick(~w(a b c []))
      1 -> pick(~w(0 1 2 3 -1))
      2 -> "f(#{term(d - 1, [])})"
      3 -> "g(#{term(d - 1, [])}, #{term(d - 1, [])})"
      4 -> "[#{term(d - 1, [])}, #{term(d - 1, [])}]"
      5 -> pick(~w(a [] 0))
    end
  end

  defp term(d, vars) do
    case r(if d <= 0, do: 4, else: 9) do
      0 -> pick(vars)
      1 -> pick(vars)
      2 -> pick(~w(a b c []))
      3 -> pick(~w(0 1 2 3 -1))
      4 -> "f(#{term(d - 1, vars)})"
      5 -> "g(#{term(d - 1, vars)}, #{term(d - 1, vars)})"
      6 -> "[#{term(d - 1, vars)}, #{term(d - 1, vars)}]"
      7 -> "[#{term(d - 1, vars)}|#{term(d - 1, vars)}]"
      8 -> pick(vars)
    end
  end

  defp list_lit(vars) do
    "[" <> Enum.map_join(1..r(4)//1, ", ", fn _ -> term(1, vars) end) <> "]"
  end

  defp expr(d, vars) do
    case r(if d <= 0, do: 2, else: 8) do
      0 -> pick(vars)
      1 -> pick(["0", "1", "2", "3", "7", "(-2)"])
      2 -> "(#{expr(d - 1, vars)} + #{expr(d - 1, vars)})"
      3 -> "(#{expr(d - 1, vars)} - #{expr(d - 1, vars)})"
      4 -> "(#{expr(d - 1, vars)} * #{expr(d - 1, vars)})"
      5 -> "(#{expr(d - 1, vars)} #{pick(~w(// mod rem div))} #{expr(d - 1, vars)})"
      6 -> "#{pick(~w(min max))}(#{expr(d - 1, vars)}, #{expr(d - 1, vars)})"
      7 -> "abs(#{expr(d - 1, vars)})"
    end
  end

  defp goal(d, ctx, vars) do
    v = fn -> pick(vars) end
    t = fn -> term(2, vars) end
    sub = fn -> if d > 0, do: goal(d - 1, ctx, vars), else: simple(ctx, vars) end
    n = length(ctx.arities)

    case r(30) do
      k when k < 6 and n > 0 ->
        j = r(n)
        call_text("#{ctx.pfx}p#{j}", for(_ <- 1..Enum.at(ctx.arities, j)//1, do: t.()))

      6 -> "#{v.()} = #{t.()}"
      7 ->
        # ordering of two distinct unbound variables is implementation defined,
        # so standard-order comparisons only ever see ground terms
        if chance(0.6),
          do: "#{v.()} #{pick(~w(\\= == \\==))} #{t.()}",
          else: "#{term(2, [])} #{pick(~w(@< @>= @> @=<))} #{term(2, [])}"
      8 -> "!"
      9 -> "( #{sub.()} ; #{sub.()} )"
      10 -> "( #{sub.()} -> #{sub.()} ; #{sub.()} )"
      11 -> "( #{sub.()} -> #{sub.()} )"
      12 -> "\\+ #{sub.()}"
      13 -> "( #{sub.()} *-> #{sub.()} ; #{sub.()} )"
      14 -> "#{v.()} is #{expr(2, vars)}"
      15 -> "#{expr(1, vars)} #{pick(~w(< =:= >= =\\=))} #{expr(1, vars)}"
      16 -> "member(#{t.()}, #{list_lit(vars)})"
      17 -> if chance(0.5), do: "append(#{v.()}, #{v.()}, #{list_lit(vars)})", else: "append(#{list_lit(vars)}, #{t.()}, #{v.()})"
      18 -> "between(#{pick(~w(0 1 2))}, #{pick(~w(1 2 3))}, #{v.()})"
      19 -> if chance(0.5), do: "length(#{list_lit(vars)}, #{v.()})", else: "length(#{v.()}, #{pick(~w(0 1 2))})"
      20 -> "findall(#{t.()}, #{sub.()}, #{v.()})"
      21 -> "catch(#{sub.()}, #{pick(["ball(E)", "error(E, _)", "error(type_error(T, C), _)", "ball(#{v.()})", "_"])}, #{sub.()})"
      22 -> "throw(ball(#{t.()}))"
      23 -> "#{pick(~w(atom integer var nonvar compound is_list atomic callable))}(#{v.()})"
      24 ->
        case r(4) do
          0 -> "#{t.()} =.. #{v.()}"
          1 -> "functor(#{t.()}, #{v.()}, #{v.()})"
          2 -> "copy_term(#{t.()}, #{v.()})"
          3 -> "arg(#{pick(~w(1 2))}, #{t.()}, #{v.()})"
        end

      25 -> "#{pick(~w(msort sort))}(#{list_lit([])}, #{v.()})"
      26 -> "compare(#{v.()}, #{term(2, [])}, #{term(2, [])})"
      27 ->
        case r(4) do
          0 -> "assertz(#{ctx.pfx}d(#{t.()}))"
          1 -> "retract(#{ctx.pfx}d(#{t.()}))"
          2 -> "asserta(#{ctx.pfx}d(#{t.()}))"
          3 -> "#{ctx.pfx}d(#{t.()})"
        end

      28 -> "#{pick(~w(once ignore call))}(#{sub.()})"
      _ -> simple(ctx, vars)
    end
  end

  defp simple(ctx, vars) do
    n = length(ctx.arities)

    if n > 0 and chance(0.6) do
      j = r(n)
      call_text("#{ctx.pfx}p#{j}", for(_ <- 1..Enum.at(ctx.arities, j)//1, do: term(1, vars)))
    else
      pick(["true", "fail", "!", "#{pick(vars)} = #{term(1, vars)}"])
    end
  end
end
