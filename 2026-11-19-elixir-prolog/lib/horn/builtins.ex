defmodule Horn.Builtins do
  @moduledoc """
  Builtin predicates implemented in Elixir.

  Each entry is `{:det, fun}` where `fun.(args, s)` returns `{:ok, s} | true | false | :fail`,
  or `{:nondet, fun}` where `fun.(args, s)` returns `nil | {s, next}` and `next`
  is either `nil` (no more solutions) or a zero-arity function producing the next one.
  Errors are raised with `throw({:pl_error, ball})`.
  """
  alias Horn.{Term, Engine, Arith, Writer, Parser}
  import Term, only: [deref: 2, unify: 3]

  def get(key), do: Map.get(table(), key)
  def builtin?(key), do: Map.has_key?(table(), key)

  defp table do
    case :persistent_term.get({__MODULE__, :table}, nil) do
      nil ->
        t = build()
        :persistent_term.put({__MODULE__, :table}, t)
        t

      t ->
        t
    end
  end

  # --- helpers -------------------------------------------------------------------

  defp err(t), do: throw({:pl_error, t})
  defp inst!, do: err(Term.inst_error())
  defp type!(t, c), do: err(Term.type_error(t, c))
  defp domain!(d, c), do: err(Term.err({:c, "domain_error", [d, c]}))

  defp u(a, b, s) do
    case unify(a, b, s) do
      {:ok, s} -> {:ok, s}
      :fail -> false
    end
  end

  def from_list([]), do: nil
  def from_list([s]), do: {s, nil}
  def from_list([s | r]), do: {s, fn -> from_list(r) end}

  # Lazily apply `f` (which returns a substitution or :fail) to each candidate.
  # Each element is visited exactly once, so side effects (retract/1) happen
  # only when the engine actually backtracks into the next alternative.
  defp gen_map(enum, f), do: gen_each(Enum.to_list(enum), f)

  defp gen_each([], _f), do: nil

  defp gen_each([x | xs], f) do
    case f.(x) do
      :fail -> gen_each(xs, f)
      s -> {s, if(xs == [], do: nil, else: fn -> gen_each(xs, f) end)}
    end
  end

  defp int_arg(t, s) do
    case deref(t, s) do
      {:v, _} -> inst!()
      i when is_integer(i) -> i
      x -> type!("integer", x)
    end
  end

  def text(t, s) do
    case deref(t, s) do
      {:v, _} -> inst!()
      a when is_binary(a) -> a
      n when is_integer(n) -> Integer.to_string(n)
      f when is_float(f) -> Writer.float(f)
      other ->
        case Term.to_list(other, s) do
          {:ok, items} ->
            items
            |> Enum.map(fn x ->
              case deref(x, s) do
                c when is_integer(c) -> <<c::utf8>>
                c when is_binary(c) -> c
                _ -> type!("text", other)
              end
            end)
            |> Enum.join()

          _ ->
            type!("atomic", other)
        end
    end
  end

  defp codes(bin), do: Term.list(String.to_charlist(bin))
  defp chars(bin), do: Term.list(String.graphemes(bin))

  def parse_number(text) do
    try do
      case Parser.read_term(String.trim(text)) do
        {:ok, n, _} when is_number(n) -> n
        {:ok, {:c, "-", [n]}, _} when is_number(n) -> -n
        {:ok, {:c, "+", [n]}, _} when is_number(n) -> n
        _ -> nil
      end
    catch
      _ -> nil
    end
  end

  defp list!(t, s) do
    case Term.to_list(t, s) do
      {:ok, items} -> items
      {:partial, _, _} -> inst!()
      :error -> type!("list", Term.resolve(t, s))
    end
  end

  # --- output --------------------------------------------------------------------

  def out(iodata) do
    case Process.get(:pl_capture, []) do
      [] -> IO.write(iodata)
      [buf | rest] -> Process.put(:pl_capture, [[buf, iodata] | rest])
    end
  end

  def capture(fun) do
    Process.put(:pl_capture, [[] | Process.get(:pl_capture, [])])

    try do
      r = fun.()
      [buf | rest] = Process.get(:pl_capture)
      Process.put(:pl_capture, rest)
      {r, IO.iodata_to_binary(buf)}
    catch
      kind, v ->
        [_ | rest] = Process.get(:pl_capture)
        Process.put(:pl_capture, rest)
        :erlang.raise(kind, v, __STACKTRACE__)
    end
  end

  defp column do
    case Process.get(:pl_capture, []) do
      [] -> Process.get(:pl_col, 0)
      [buf | _] ->
        b = IO.iodata_to_binary(buf)
        case :binary.matches(b, "\n") do
          [] -> String.length(b)
          ms -> {p, _} = List.last(ms); String.length(b) - p - 1
        end
    end
  end

  defp emit(text) do
    out(text)

    if Process.get(:pl_capture, []) == [] do
      case :binary.matches(text, "\n") do
        [] -> Process.put(:pl_col, Process.get(:pl_col, 0) + String.length(text))
        ms -> {p, _} = List.last(ms); Process.put(:pl_col, String.length(text) - p - 1)
      end
    end

    true
  end

  # --- comparison of terms -----------------------------------------------------------

  defp msort(items, s), do: Enum.sort(items, fn a, b -> Term.compare(a, b, s) <= 0 end)

  defp dedup([], _s), do: []
  defp dedup([x | rest], s), do: [x | dedup_(rest, x, s)]
  defp dedup_([], _p, _s), do: []
  defp dedup_([x | rest], p, s) do
    if Term.compare(x, p, s) == 0, do: dedup_(rest, p, s), else: [x | dedup_(rest, x, s)]
  end

  # =============================================================================
  # Table
  # =============================================================================

  defp build do
    det = fn name, ar, f -> {{name, ar}, {:det, f}} end
    nd = fn name, ar, f -> {{name, ar}, {:nondet, f}} end

    type_checks =
      for {name, pred} <- [
            {"var", &match?({:v, _}, &1)},
            {"nonvar", &(not match?({:v, _}, &1))},
            {"atom", &is_binary/1},
            {"number", &is_number/1},
            {"integer", &is_integer/1},
            {"float", &is_float/1},
            {"atomic", &(is_binary(&1) or is_number(&1) or &1 == [])},
            {"compound", &match?({:c, _, _}, &1)},
            {"callable", &(is_binary(&1) or match?({:c, _, _}, &1))},
            {"is_dict", fn _ -> false end},
            {"string", fn _ -> false end}
          ] do
        det.(name, 1, fn [x], s -> pred.(deref(x, s)) end)
      end

    order =
      for {op, ok} <- [{"@<", &(&1 < 0)}, {"@>", &(&1 > 0)}, {"@=<", &(&1 <= 0)}, {"@>=", &(&1 >= 0)}, {"==", &(&1 == 0)}, {"\\==", &(&1 != 0)}] do
        det.(op, 2, fn [a, b], s -> ok.(Term.compare(a, b, s)) end)
      end

    arith =
      for op <- ["=:=", "=\\=", "<", ">", "=<", ">="] do
        det.(op, 2, fn [a, b], s -> Arith.compare(op, a, b, s) end)
      end

    Map.new(
      type_checks ++
        order ++
        arith ++
        [
          det.("=", 2, fn [a, b], s -> u(a, b, s) end),
          det.("\\=", 2, fn [a, b], s -> unify(a, b, s) == :fail end),
          det.("unify_with_occurs_check", 2, fn [a, b], s ->
            old = Process.get(:pl_occurs)
            Process.put(:pl_occurs, true)
            r = u(a, b, s)
            Process.put(:pl_occurs, old)
            r
          end),
          det.("=@=", 2, fn [a, b], s -> variant?(Term.resolve(a, s), Term.resolve(b, s)) end),
          det.("\\=@=", 2, fn [a, b], s -> not variant?(Term.resolve(a, s), Term.resolve(b, s)) end),
          det.("is_list", 1, fn [x], s -> match?({:ok, _}, Term.to_list(x, s)) end),
          det.("ground", 1, fn [x], s -> Term.term_vars(x, s) == [] end),
          det.("compare", 3, fn [o, a, b], s ->
            case deref(o, s) do
              {:v, _} -> :ok
              x when x in ["<", "=", ">"] -> :ok
              x when is_binary(x) or x == [] -> domain!("order", x)
              x -> type!("atom", Term.resolve(x, s))
            end

            r = case Term.compare(a, b, s) do
              0 -> "="
              -1 -> "<"
              1 -> ">"
            end
            u(o, r, s)
          end),
          det.("is", 2, fn [x, e], s -> u(x, Arith.eval(e, s), s) end),
          det.("succ", 2, &succ/2),
          det.("plus", 3, fn [a, b, c], s ->
            case {deref(a, s), deref(b, s), deref(c, s)} do
              {x, y, _} when is_integer(x) and is_integer(y) -> u(c, x + y, s)
              {x, _, z} when is_integer(x) and is_integer(z) -> u(b, z - x, s)
              {_, y, z} when is_integer(y) and is_integer(z) -> u(a, z - y, s)
              _ -> inst!()
            end
          end),
          det.("functor", 3, &functor/2),
          nd.("arg", 3, &arg/2),
          det.("=..", 2, &univ/2),
          det.("copy_term", 2, fn [a, b], s -> u(b, Term.copy(a, s), s) end),
          det.("term_variables", 2, fn [t, l], s -> u(l, Term.list(Term.term_vars(t, s)), s) end),
          det.("setarg", 3, fn _, _ -> err(Term.err({:c, "permission_error", ["modify", "term", "setarg"]})) end),

          # atoms & text
          det.("atom_codes", 2, &text_conv(&1, &2, :codes)),
          det.("atom_chars", 2, &text_conv(&1, &2, :chars)),
          det.("number_codes", 2, &num_conv(&1, &2, :codes)),
          det.("number_chars", 2, &num_conv(&1, &2, :chars)),
          det.("char_code", 2, fn [a, c], s ->
            case deref(a, s) do
              x when is_binary(x) -> u(c, x |> String.to_charlist() |> hd(), s)
              _ -> u(a, <<int_arg(c, s)::utf8>>, s)
            end
          end),
          det.("atom_length", 2, fn [a, l], s -> u(l, String.length(text(a, s)), s) end),
          det.("atom_number", 2, fn [a, n], s ->
            case deref(a, s) do
              {:v, _} ->
                case deref(n, s) do
                  {:v, _} -> inst!()
                  x -> u(a, text(x, s), s)
                end

              x when is_binary(x) ->
                case parse_number(x) do
                  nil -> false
                  num -> u(n, num, s)
                end

              x -> type!("atom", x)
            end
          end),
          det.("atom_string", 2, fn [a, b], s ->
            case deref(a, s) do
              {:v, _} -> u(a, text(b, s), s)
              _ -> u(b, codes(text(a, s)), s)
            end
          end),
          det.("number_string", 2, fn [n, str], s -> u(n, parse_number(text(str, s)) || type!("number", str), s) end),
          det.("atom_to_term", 3, &atom_to_term/2),
          det.("term_to_atom", 2, fn [t, a], s ->
            case deref(a, s) do
              {:v, _} -> u(a, Writer.to_string(t, s, quoted: true), s)
              _ -> atom_to_term([a, t, {:v, -99}], s)
            end
          end),
          det.("upcase_atom", 2, fn [a, b], s -> u(b, String.upcase(text(a, s)), s) end),
          det.("downcase_atom", 2, fn [a, b], s -> u(b, String.downcase(text(a, s)), s) end),
          det.("string_upper", 2, fn [a, b], s -> u(b, codes(String.upcase(text(a, s))), s) end),
          det.("string_lower", 2, fn [a, b], s -> u(b, codes(String.downcase(text(a, s))), s) end),
          det.("atomic_list_concat", 2, fn [l, r], s -> u(r, list!(l, s) |> Enum.map(&text(&1, s)) |> Enum.join(), s) end),
          det.("atomic_list_concat", 3, &alc3/2),
          det.("split_string", 4, &split_string/2),
          det.("string_codes", 2, fn [a, b], s ->
            case deref(a, s) do
              {:v, _} -> u(a, b, s)
              _ -> u(b, codes(text(a, s)), s)
            end
          end),
          det.("string_chars", 2, fn [a, b], s -> u(b, chars(text(a, s)), s) end),
          det.("string_to_atom", 2, fn [a, b], s ->
            case deref(a, s) do
              {:v, _} -> u(a, codes(text(b, s)), s)
              _ -> u(b, text(a, s), s)
            end
          end),
          det.("string_length", 2, fn [a, l], s -> u(l, String.length(text(a, s)), s) end),
          det.("number_vars", 3, &numbervars/2),
          det.("numbervars", 3, &numbervars/2),
          det.("char_type", 2, &char_type(&1, &2, :char)),
          det.("code_type", 2, &char_type(&1, &2, :code)),
          nd.("atom_concat", 3, &atom_concat/2),
          nd.("sub_atom", 5, &sub_atom/2),
          nd.("between", 3, &between/2),
          nd.("length", 2, &length/2),
          det.("msort", 2, fn [l, r], s -> u(r, Term.list(msort(list!(l, s), s)), s) end),
          det.("sort", 2, fn [l, r], s -> u(r, Term.list(dedup(msort(list!(l, s), s), s)), s) end),
          det.("sort", 4, &sort4/2),
          det.("keysort", 2, &keysort/2),
          det.("reverse", 2, fn [l, r], s -> u(r, Term.list(Enum.reverse(list!(l, s))), s) end),
          det.("sum_list", 2, fn [l, r], s -> u(r, Enum.reduce(list!(l, s), 0, &(Arith.eval(&1, s) + &2)), s) end),
          det.("sumlist", 2, fn [l, r], s -> u(r, Enum.reduce(list!(l, s), 0, &(Arith.eval(&1, s) + &2)), s) end),
          det.("numlist", 3, fn [lo, hi, r], s -> numlist(int_arg(lo, s), int_arg(hi, s), r, s) end),
          det.("list_to_set", 2, &list_to_set/2),

          # database
          det.("assert", 1, fn [c], s -> Engine.add_clause(c, s, :z) && true end),
          det.("assertz", 1, fn [c], s -> Engine.add_clause(c, s, :z) && true end),
          det.("asserta", 1, fn [c], s -> Engine.add_clause(c, s, :a) && true end),
          nd.("retract", 1, &retract/2),
          nd.("clause", 2, &clause/2),
          det.("retractall", 1, &retractall/2),
          det.("abolish", 1, fn [pi], s ->
            {n, a} = pi_key(pi, s)
            Process.put(:pl_db, Map.delete(Engine.db(), {n, a}))
            true
          end),
          det.("dynamic", 1, &dynamic/2),
          det.("discontiguous", 1, fn _, _ -> true end),
          nd.("current_predicate", 1, &current_predicate/2),
          nd.("current_op", 3, &current_op/2),
          det.("op", 3, &op/2),
          det.("set_prolog_flag", 2, &set_flag/2),
          det.("current_prolog_flag", 2, fn [f, v], s ->
            case text(f, s) do
              "bounded" -> u(v, "false", s)
              "max_integer" -> u(v, 9_223_372_036_854_775_807, s)
              "min_integer" -> u(v, -9_223_372_036_854_775_808, s)
              "occurs_check" -> u(v, to_string(Process.get(:pl_occurs)), s)
              _ -> false
            end
          end),

          # all-solutions
          nd.("bagof", 3, &bagof(&1, &2, false)),
          nd.("setof", 3, &bagof(&1, &2, true)),
          det.("aggregate_all", 3, &aggregate_all/2),

          # globals
          det.("nb_setval", 2, &setval/2),
          det.("b_setval", 2, &setval/2),
          det.("nb_getval", 2, &getval/2),
          det.("b_getval", 2, &getval/2),

          # output
          det.("write", 1, fn [t], s -> emit(Writer.to_string(t, s)) end),
          det.("print", 1, fn [t], s -> emit(Writer.to_string(t, s, quoted: true)) end),
          det.("writeln", 1, fn [t], s -> emit(Writer.to_string(t, s) <> "\n") end),
          det.("writeq", 1, fn [t], s -> emit(Writer.to_string(t, s, quoted: true)) end),
          det.("write_canonical", 1, fn [t], s -> emit(Writer.to_string(t, s, quoted: true, ignore_ops: true, numbervars: false)) end),
          det.("write_term", 2, &write_term/2),
          det.("write", 2, fn [_, t], s -> emit(Writer.to_string(t, s)) end),
          det.("writeln", 2, fn [_, t], s -> emit(Writer.to_string(t, s) <> "\n") end),
          det.("writeq", 2, fn [_, t], s -> emit(Writer.to_string(t, s, quoted: true)) end),
          det.("nl", 0, fn [], _ -> emit("\n") end),
          det.("nl", 1, fn [_], _ -> emit("\n") end),
          det.("tab", 1, fn [n], s -> emit(String.duplicate(" ", Arith.eval(n, s))) end),
          det.("put_char", 1, fn [c], s -> emit(text(c, s)) end),
          det.("flush_output", 0, fn [], _ -> true end),
          det.("format", 1, fn [f], s -> emit(format(text(f, s), [], s)) end),
          det.("format", 2, fn [f, a], s -> emit(format(text(f, s), fmt_args(a, s), s)) end),
          det.("format", 3, &format3/2),
          det.("with_output_to", 2, &with_output_to/2),
          det.("call_with_inference_limit", 3, &inference_limit/2),
          det.("read_term", 2, fn [t, _], s -> read_stdin(t, s) end),
          det.("read", 1, fn [t], s -> read_stdin(t, s) end),

          # system
          det.("halt", 0, fn [], _ -> throw({:pl_halt, 0}) end),
          det.("halt", 1, fn [n], s -> throw({:pl_halt, int_arg(n, s)}) end),
          det.("statistics", 2, &statistics/2),
          det.("garbage_collect", 0, fn [], _ -> :erlang.garbage_collect() end),
          det.("consult", 1, &consult/2),
          det.("ensure_loaded", 1, fn _, _ -> true end),
          det.("use_module", 1, fn _, _ -> true end),
          det.("use_module", 2, fn _, _ -> true end),
          det.("set_random", 1, fn [{:c, "seed", [n]}], s -> :rand.seed(:exsss, {int_arg(n, s), 1, 2}) && true end),
          det.("random_between", 3, fn [l, h, x], s ->
            lo = int_arg(l, s)
            u(x, lo + :rand.uniform(int_arg(h, s) - lo + 1) - 1, s)
          end),
          det.("random", 1, fn [x], s -> u(x, :rand.uniform(), s) end),
          det.("tab", 2, fn [_, n], s -> emit(String.duplicate(" ", Arith.eval(n, s))) end),
          det.("true", 0, fn _, _ -> true end)
        ]
    )
  end

  # --- term construction --------------------------------------------------------------

  defp succ([a, b], s) do
    case {deref(a, s), deref(b, s)} do
      {x, _} when is_integer(x) ->
        if x < 0, do: type!("not_less_than_zero", x), else: u(b, x + 1, s)

      {{:v, _}, y} when is_integer(y) ->
        cond do
          y < 0 -> type!("not_less_than_zero", y)
          y == 0 -> false
          true -> u(a, y - 1, s)
        end

      {{:v, _}, {:v, _}} -> inst!()
      {x, _} when not is_tuple(x) -> type!("integer", x)
      {_, y} -> type!("integer", y)
    end
  end

  defp functor([t, n, a], s) do
    case deref(t, s) do
      {:v, _} ->
        name = deref(n, s)
        ar = deref(a, s)

        cond do
          match?({:c, _, _}, name) -> type!("atomic", Term.resolve(name, s))
          match?({:v, _}, name) or match?({:v, _}, ar) -> inst!()
          not is_integer(ar) -> type!("integer", Term.resolve(ar, s))
          ar < 0 -> domain!("not_less_than_zero", ar)
          ar == 0 -> u(t, name, s)
          not is_binary(name) -> type!("atom", name)
          true -> u(t, {:c, name, Enum.map(1..ar, fn _ -> Term.fresh_var() end)}, s)
        end

      {:c, f, args} ->
        with {:ok, s} <- unify(n, f, s), {:ok, s} <- unify(a, length(args), s), do: {:ok, s}, else: (_ -> false)

      x ->
        with {:ok, s} <- unify(n, x, s), {:ok, s} <- unify(a, 0, s), do: {:ok, s}, else: (_ -> false)
    end
  end

  defp arg([n, t, a], s) do
    case deref(t, s) do
      {:c, _, args} ->
        case deref(n, s) do
          i when is_integer(i) and i < 0 ->
            domain!("not_less_than_zero", i)

          i when is_integer(i) ->
            if i >= 1 and i <= length(args) do
              case unify(a, Enum.at(args, i - 1), s) do
                {:ok, s} -> {s, nil}
                :fail -> nil
              end
            end

          {:v, _} ->
            args
            |> Stream.with_index(1)
            |> gen_map(fn {x, i} ->
              with {:ok, s} <- unify(n, i, s), {:ok, s} <- unify(a, x, s), do: s, else: (_ -> :fail)
            end)

          x ->
            type!("integer", x)
        end

      {:v, _} -> inst!()
      x -> type!("compound", Term.resolve(x, s))
    end
  end

  defp univ([t, l], s) do
    case deref(t, s) do
      {:v, _} ->
        # SWI checks the functor position before the shape of the tail
        case deref(l, s) do
          {:v, _} -> inst!()
          [] -> domain!("non_empty_list", [])
          {:c, "[|]", [h, tl]} ->
            single = deref(tl, s) == []

            case deref(h, s) do
              {:v, _} -> inst!()
              {:c, _, _} = c when single -> type!("atomic", Term.resolve(c, s))
              x when single -> u(t, x, s)
              name when is_binary(name) or name == [] ->
                name = if name == [], do: "[]", else: name

                case Term.to_list(tl, s) do
                  {:ok, args} -> u(t, {:c, name, args}, s)
                  {:partial, _, _} -> inst!()
                  :error -> type!("list", Term.resolve(l, s))
                end

              x -> type!("atom", Term.resolve(x, s))
            end

          other -> type!("list", Term.resolve(other, s))
        end

      {:c, f, args} -> univ_walk([f | args], l, s)
      x -> univ_walk([x], l, s)
    end
  end

  # SWI unifies the list element by element and only complains about a
  # non-list tail when it actually reaches it.
  defp univ_walk(items, l, s) do
    case {items, deref(l, s)} do
      {_, {:v, _} = v} -> u(v, Term.list(items), s)
      {[], []} -> {:ok, s}
      {[], {:c, "[|]", [_, _]}} -> false
      {[_ | _], []} -> false
      {[x | xs], {:c, "[|]", [h, tl]}} ->
        case unify(x, h, s) do
          {:ok, s} -> univ_walk(xs, tl, s)
          :fail -> false
        end

      {_, other} -> type!("list", Term.resolve(other, s))
    end
  end

  defp text_conv([a, l], s, kind) do
    case deref(a, s) do
      {:v, _} ->
        case Term.to_list(l, s) do
          {:ok, _} -> u(a, text(l, s), s)
          _ -> inst!()
        end

      _ ->
        t = text(a, s)
        u(l, if(kind == :codes, do: codes(t), else: chars(t)), s)
    end
  end

  defp num_conv([n, l], s, kind) do
    case Term.to_list(l, s) do
      {:ok, _} ->
        case parse_number(text(l, s)) do
          nil -> err(Term.err({:c, "syntax_error", ["illegal_number"]}))
          x -> u(n, x, s)
        end

      _ ->
        t = text(n, s)
        u(l, if(kind == :codes, do: codes(t), else: chars(t)), s)
    end
  end

  defp atom_to_term([a, t, b], s) do
    case Parser.read_term(text(a, s) <> " .") do
      {:ok, term, names} ->
        bindings = Term.list(Enum.map(names, fn {n, v} -> {:c, "=", [n, v]} end))
        with {:ok, s} <- unify(t, term, s), {:ok, s} <- unify(b, bindings, s), do: {:ok, s}, else: (_ -> false)

      {:error, m} ->
        err(Term.err({:c, "syntax_error", [m]}))
    end
  end

  defp alc3([l, sep, r], s) do
    sep = text(sep, s)

    case Term.to_list(l, s) do
      {:ok, items} ->
        if Enum.all?(items, &(not match?({:v, _}, deref(&1, s)))) do
          u(r, items |> Enum.map(&text(&1, s)) |> Enum.join(sep), s)
        else
          split_into(l, sep, r, s)
        end

      _ ->
        split_into(l, sep, r, s)
    end
  end

  defp split_into(l, sep, r, s) do
    if sep == "", do: domain!("non_empty_atom", sep)
    parts = String.split(text(r, s), sep) |> Enum.map(&(parse_number(&1) |> then(fn _ -> &1 end)))
    u(l, Term.list(parts), s)
  end

  defp split_string([str, seps, pad, r], s) do
    str = text(str, s)
    seps = text(seps, s) |> String.graphemes()
    pad = text(pad, s)

    parts =
      if seps == [] do
        [str]
      else
        String.split(str, seps)
      end

    parts = Enum.map(parts, &String.trim(&1, pad))
    parts = if pad == "", do: parts, else: Enum.map(parts, fn p -> p |> String.graphemes() |> Enum.drop_while(&String.contains?(pad, &1)) |> Enum.reverse() |> Enum.drop_while(&String.contains?(pad, &1)) |> Enum.reverse() |> Enum.join() end)
    u(r, Term.list(Enum.map(parts, &codes/1)), s)
  end

  defp numbervars([t, start, e], s) do
    n0 = int_arg(start, s)
    vars = Term.term_vars(t, s)

    {s, n} =
      Enum.reduce(vars, {s, n0}, fn v, {s, n} ->
        {:ok, s} = unify(v, {:c, "$VAR", [n]}, s)
        {s, n + 1}
      end)

    u(e, n, s)
  end

  defp char_type([c, t], s, kind) do
    ch =
      case deref(c, s) do
        {:v, _} -> inst!()
        x when kind == :code and is_integer(x) -> x
        x when is_binary(x) -> x |> String.to_charlist() |> hd()
        x -> type!("character", x)
      end

    up = ch in ?A..?Z
    low = ch in ?a..?z
    dig = ch in ?0..?9
    mk = fn code -> if kind == :code, do: code, else: <<code::utf8>> end

    case deref(t, s) do
      "alpha" -> up or low or dig or ch == ?_
      "alnum" -> up or low or dig
      "csym" -> up or low or dig or ch == ?_
      "csymf" -> up or low or ch == ?_
      "digit" -> dig
      "space" -> ch in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v]
      "white" -> ch in [?\s, ?\t]
      "upper" -> up
      "lower" -> low
      "punct" -> ch in 33..126 and not (up or low or dig)
      "graph" -> ch in 33..126
      "end_of_line" -> ch in [?\n, ?\r]
      {:c, "digit", [w]} -> dig and u(w, ch - ?0, s)
      {:c, "upper", [l]} -> up and u(l, mk.(ch + 32), s)
      {:c, "lower", [l]} -> low and u(l, mk.(ch - 32), s)
      {:c, "to_lower", [l]} -> u(l, mk.(if up, do: ch + 32, else: ch), s)
      {:c, "to_upper", [l]} -> u(l, mk.(if low, do: ch - 32, else: ch), s)
      _ -> false
    end
  end

  defp atom_concat([a, b, c], s) do
    case {deref(a, s), deref(b, s)} do
      {x, y} when not is_tuple(x) and not is_tuple(y) ->
        case unify(c, text(x, s) <> text(y, s), s) do
          {:ok, s} -> {s, nil}
          :fail -> nil
        end

      _ ->
        whole = text(c, s)
        n = String.length(whole)

        0..n
        |> gen_map(fn i ->
          {p, q} = String.split_at(whole, i)
          with {:ok, s} <- unify(a, p, s), {:ok, s} <- unify(b, q, s), do: s, else: (_ -> :fail)
        end)
    end
  end

  defp sub_atom([atom, b, l, a, sub], s) do
    str = text(atom, s)
    n = String.length(str)

    case deref(sub, s) do
      x when is_binary(x) ->
        k = String.length(x)

        0..max(n - k, 0)
        |> Stream.filter(fn i -> k <= n and String.slice(str, i, k) == x end)
        |> gen_map(fn i ->
          with {:ok, s} <- unify(b, i, s), {:ok, s} <- unify(l, k, s), {:ok, s} <- unify(a, n - i - k, s), do: s, else: (_ -> :fail)
        end)

      _ ->
        bs = case deref(b, s) do
          i when is_integer(i) -> [i]
          _ -> 0..n
        end

        bs
        |> Stream.flat_map(fn i ->
          ls = case {deref(l, s), deref(a, s)} do
            {k, _} when is_integer(k) -> [k]
            {_, k} when is_integer(k) -> [n - i - k]
            _ -> 0..(n - i)
          end
          Stream.map(Enum.filter(ls, &(&1 >= 0 and &1 + i <= n)), fn k -> {i, k} end)
        end)
        |> gen_map(fn {i, k} ->
          with {:ok, s} <- unify(b, i, s),
               {:ok, s} <- unify(l, k, s),
               {:ok, s} <- unify(a, n - i - k, s),
               {:ok, s} <- unify(sub, String.slice(str, i, k), s),
               do: s,
               else: (_ -> :fail)
        end)
    end
  end

  defp between([lo, hi, x], s) do
    l = int_arg(lo, s)

    h =
      case deref(hi, s) do
        h when h in ["inf", "infinite"] -> :inf
        _ -> int_arg(hi, s)
      end

    case deref(x, s) do
      i when is_integer(i) -> if i >= l and (h == :inf or i <= h), do: {s, nil}, else: nil
      {:v, _} -> between_gen(x, l, h, s)
      other -> type!("integer", other)
    end
  end

  defp between_gen(x, i, h, s) do
    cond do
      h != :inf and i > h -> nil
      true ->
        {:ok, s2} = unify(x, i, s)
        if h != :inf and i == h, do: {s2, nil}, else: {s2, fn -> between_gen(x, i + 1, h, s) end}
    end
  end

  defp length([l, n], s) do
    case deref(n, s) do
      m when is_integer(m) and m < 0 -> domain!("not_less_than_zero", m)
      {:v, _} -> :ok
      m when is_integer(m) -> :ok
      m -> type!("integer", m)
    end

    case Term.to_list(l, s) do
      {:ok, items} ->
        case unify(n, length(items), s) do
          {:ok, s} -> {s, nil}
          :fail -> nil
        end

      {:partial, items, tailv} ->
        k = length(items)

        case deref(n, s) do
          m when is_integer(m) ->
            if m < k do
              nil
            else
              {:ok, s} = unify(tailv, Term.list(Enum.map(1..(m - k)//1, fn _ -> Term.fresh_var() end)), s)
              {s, nil}
            end

          {:v, _} ->
            if deref(n, s) == deref(tailv, s), do: nil, else: length_gen(tailv, n, k, 0, s)

          x ->
            type!("integer", x)
        end

      :error ->
        type!("list", Term.resolve(l, s))
    end
  end

  defp length_gen(tailv, n, k, extra, s) do
    vars = Enum.map(1..extra//1, fn _ -> Term.fresh_var() end)
    {:ok, s2} = unify(tailv, Term.list(vars), s)
    {:ok, s2} = unify(n, k + extra, s2)
    {s2, fn -> length_gen(tailv, n, k, extra + 1, s) end}
  end

  defp sort4([key, ord, l, r], s) do
    k = int_arg(key, s)
    o = text(ord, s)
    items = list!(l, s)

    keyf = fn t ->
      if k == 0 do
        t
      else
        case deref(t, s) do
          {:c, _, args} when length(args) >= k -> Enum.at(args, k - 1)
          x -> type!("compound", x)
        end
      end
    end

    cmp = fn a, b -> Term.compare(keyf.(a), keyf.(b), s) end

    sorted =
      case o do
        o when o in ["@<", "@=<"] -> Enum.sort(items, &(cmp.(&1, &2) <= 0))
        o when o in ["@>", "@>="] -> Enum.sort(items, &(cmp.(&1, &2) >= 0))
        _ -> domain!("order", o)
      end

    sorted =
      if o in ["@<", "@>"] do
        Enum.reduce(sorted, [], fn x, acc ->
          case acc do
            [p | _] -> if cmp.(x, p) == 0, do: acc, else: [x | acc]
            [] -> [x]
          end
        end)
        |> Enum.reverse()
      else
        sorted
      end

    u(r, Term.list(sorted), s)
  end

  defp keysort([l, r], s) do
    items = list!(l, s)

    pairs =
      Enum.map(items, fn t ->
        case deref(t, s) do
          {:c, "-", [k, _]} -> {k, t}
          {:v, _} -> inst!()
          x -> type!("pair", Term.resolve(x, s))
        end
      end)

    sorted = Enum.sort(pairs, fn {a, _}, {b, _} -> Term.compare(a, b, s) <= 0 end)
    u(r, Term.list(Enum.map(sorted, &elem(&1, 1))), s)
  end

  defp numlist(lo, hi, r, s) do
    if lo > hi, do: false, else: u(r, Term.list(Enum.to_list(lo..hi)), s)
  end

  defp list_to_set([l, r], s) do
    items = list!(l, s)

    {out, _} =
      Enum.reduce(items, {[], []}, fn x, {acc, seen} ->
        if Enum.any?(seen, &(Term.compare(&1, x, s) == 0)), do: {acc, seen}, else: {[x | acc], [x | seen]}
      end)

    u(r, Term.list(Enum.reverse(out)), s)
  end

  # --- database ---------------------------------------------------------------------------

  defp head_key(h, s) do
    case deref(h, s) do
      {:v, _} -> inst!()
      n when is_binary(n) -> {n, []}
      {:c, n, args} -> {n, args}
      x -> type!("callable", x)
    end
  end

  defp split_clause(c, s) do
    case deref(c, s) do
      {:c, ":-", [h, b]} -> {h, b}
      h -> {h, "true"}
    end
  end

  defp retract([c], s) do
    {h, b} = split_clause(c, s)
    {name, args} = head_key(h, s)
    key = {name, length(args)}

    (Engine.clauses(key) || [])
    |> gen_map(fn cl ->
      {hargs, body} = Engine.rename_clause(cl)

      with {:ok, s} <- unify(Term.list(hargs), Term.list(args), s),
           {:ok, s} <- unify(body, b, s) do
        Engine.remove_clause(key, elem(cl, 0))
        s
      else
        _ -> :fail
      end
    end)
  end

  defp clause([h, b], s) do
    {name, args} = head_key(h, s)
    key = {name, length(args)}

    if builtin?(key), do: err(Term.err({:c, "permission_error", ["access", "private_procedure", Term.pi(name, length(args))]}))

    (Engine.clauses(key) || [])
    |> gen_map(fn cl ->
      {hargs, body} = Engine.rename_clause(cl)

      with {:ok, s} <- unify(Term.list(hargs), Term.list(args), s),
           {:ok, s} <- unify(body, b, s) do
        s
      else
        _ -> :fail
      end
    end)
  end

  defp retractall([h], s) do
    {name, args} = head_key(h, s)
    key = {name, length(args)}

    case Engine.clauses(key) do
      nil ->
        Engine.declare_dynamic(key)

      cls ->
        Enum.each(cls, fn cl ->
          {hargs, _} = Engine.rename_clause(cl)
          if unify(Term.list(hargs), Term.list(args), s) != :fail, do: Engine.remove_clause(key, elem(cl, 0))
        end)
    end

    true
  end

  defp pi_key(pi, s) do
    case deref(pi, s) do
      {:c, "/", [n, a]} -> {text(n, s), int_arg(a, s)}
      {:v, _} -> inst!()
      x -> type!("predicate_indicator", x)
    end
  end

  defp dynamic([spec], s) do
    case deref(spec, s) do
      {:c, f, [a, b]} when f in [",", "/"] and f == "," -> dynamic([a], s) && dynamic([b], s)
      {:c, "[|]", _} = l -> Enum.all?(list!(l, s), &dynamic([&1], s))
      _ -> Engine.declare_dynamic(pi_key(spec, s)) && true
    end
  end

  defp current_predicate([spec], s) do
    {n, a} =
      case deref(spec, s) do
        {:c, "/", [n, a]} -> {n, a}
        {:v, _} -> {Term.fresh_var(), Term.fresh_var()}
        x -> type!("predicate_indicator", x)
      end

    lib = Process.get(:pl_lib)

    Engine.db()
    |> Enum.filter(fn {k, cls} -> cls != [] and not MapSet.member?(lib, k) end)
    |> Enum.map(fn {{name, ar}, _} ->
      with {:ok, s} <- unify(n, name, s), {:ok, s} <- unify(a, ar, s), do: s, else: (_ -> :fail)
    end)
    |> Enum.reject(&(&1 == :fail))
    |> from_list()
  end

  defp current_op([p, t, n], s) do
    Parser.ops()
    |> Enum.flat_map(fn {name, kinds} -> Enum.map(kinds, fn {_, {pri, type}} -> {pri, type, name} end) end)
    |> Enum.sort()
    |> Enum.map(fn {pri, type, name} ->
      with {:ok, s} <- unify(p, pri, s), {:ok, s} <- unify(t, Atom.to_string(type), s), {:ok, s} <- unify(n, name, s),
           do: s, else: (_ -> :fail)
    end)
    |> Enum.reject(&(&1 == :fail))
    |> from_list()
  end

  defp op([p, t, names], s) do
    pri = int_arg(p, s)
    type = String.to_existing_atom(text(t, s))

    names =
      case deref(names, s) do
        {:c, "[|]", _} -> list!(names, s)
        x -> [x]
      end

    Enum.each(names, &Parser.add_op(pri, type, text(&1, s)))
    true
  end

  defp set_flag([f, v], s) do
    val = text(v, s)

    case text(f, s) do
      "occurs_check" -> Process.put(:pl_occurs, val in ["true", "error"])
      "unknown" -> Process.put(:pl_unknown, val)
      "double_quotes" -> Process.put(:pl_flag_double_quotes, val)
      _ -> :ok
    end

    true
  end

  # --- all-solutions ---------------------------------------------------------------------

  defp strip_carets(g, s, acc) do
    case deref(g, s) do
      {:c, "^", [v, g2]} -> strip_carets(g2, s, Term.term_vars(v, s) ++ acc)
      g -> {g, acc}
    end
  end

  defp bagof([t, g, r], s, set?) do
    {goal, excluded} = strip_carets(g, s, [])
    witness = Term.term_vars(goal, s) -- (Term.term_vars(t, s) ++ excluded)
    wt = Term.list(witness)
    pairs = Engine.all(goal, s, &Term.copy({:c, "-", [wt, t]}, &1))
    finish = fn items -> if set?, do: dedup(msort(items, %{}), %{}), else: items end

    if pairs == [] do
      nil
    else
      groups =
        if witness == [] do
          [{wt, Enum.map(pairs, fn {:c, "-", [_, x]} -> x end)}]
        else
          pairs
          |> Enum.with_index()
          |> Enum.sort(fn {{:c, "-", [a, _]}, i}, {{:c, "-", [b, _]}, j} ->
            c = Term.compare(a, b, %{})
            c < 0 or (c == 0 and i <= j)
          end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.chunk_while(
            nil,
            fn {:c, "-", [w, x]}, acc ->
              case acc do
                nil -> {:cont, {w, [x]}}
                {w0, xs} -> if variant?(w0, w), do: {:cont, {w0, [x | xs]}}, else: {:cont, {w0, Enum.reverse(xs)}, {w, [x]}}
              end
            end,
            fn
              nil -> {:cont, nil}
              {w0, xs} -> {:cont, {w0, Enum.reverse(xs)}, nil}
            end
          )
        end

      groups
      |> Enum.map(fn {w, xs} ->
        with {:ok, s} <- unify(wt, w, s), {:ok, s} <- unify(r, Term.list(finish.(xs)), s), do: s, else: (_ -> :fail)
      end)
      |> Enum.reject(&(&1 == :fail))
      |> from_list()
    end
  end

  defp variant?(a, b), do: vshape(a, %{}) |> elem(0) == vshape(b, %{}) |> elem(0)

  defp vshape({:v, _} = v, m) do
    case m do
      %{^v => i} -> {{:var, i}, m}
      _ -> {{:var, map_size(m)}, Map.put(m, v, map_size(m))}
    end
  end

  defp vshape({:c, f, args}, m) do
    {args, m} = Enum.map_reduce(args, m, &vshape/2)
    {{:c, f, args}, m}
  end

  defp vshape(x, m), do: {x, m}

  defp aggregate_all([spec, g, r], s) do
    case deref(spec, s) do
      "count" -> u(r, length(Engine.all(g, s, fn _ -> 1 end)), s)
      {:c, "count", [_]} -> u(r, length(Engine.all(g, s, fn _ -> 1 end)), s)
      {:c, "sum", [e]} -> u(r, Engine.all(g, s, &Arith.eval(e, &1)) |> Enum.reduce(0, &+/2), s)
      {:c, "bag", [e]} -> u(r, Term.list(Engine.all(g, s, &Term.copy(e, &1))), s)
      {:c, "set", [e]} -> u(r, Term.list(dedup(msort(Engine.all(g, s, &Term.copy(e, &1)), %{}), %{})), s)
      {:c, "max", [e]} ->
        case Engine.all(g, s, &Arith.eval(e, &1)) do
          [] -> false
          xs -> u(r, Enum.max(xs), s)
        end

      {:c, "min", [e]} ->
        case Engine.all(g, s, &Arith.eval(e, &1)) do
          [] -> false
          xs -> u(r, Enum.min(xs), s)
        end

      {:c, mm, [e, w]} when mm in ["max", "min"] ->
        case Engine.all(g, s, &{Arith.eval(e, &1), Term.copy(w, &1)}) do
          [] -> false
          xs ->
            {v, wit} = if mm == "max", do: Enum.max_by(xs, &elem(&1, 0)), else: Enum.min_by(xs, &elem(&1, 0))
            u(r, {:c, mm, [v, wit]}, s)
        end

      x -> domain!("aggregate_spec", x)
    end
  end

  # --- globals -----------------------------------------------------------------------------

  defp setval([k, v], s) do
    Process.put(:pl_globals, Map.put(Process.get(:pl_globals), text(k, s), Term.resolve(v, s)))
    true
  end

  defp getval([k, v], s) do
    case Map.fetch(Process.get(:pl_globals), text(k, s)) do
      {:ok, val} -> u(v, val, s)
      :error -> err(Term.err({:c, "existence_error", ["variable", text(k, s)]}))
    end
  end

  # --- I/O -----------------------------------------------------------------------------------

  defp write_term([t, opts], s) do
    opts = list!(opts, s) |> Enum.map(&Term.resolve(&1, s))
    q = {:c, "quoted", ["true"]} in opts
    io = {:c, "ignore_ops", ["true"]} in opts
    emit(Writer.to_string(t, s, quoted: q, ignore_ops: io))
  end

  defp format3([sink, f, a], s) do
    case deref(sink, s) do
      {:c, kind, [r]} when kind in ["atom", "string", "codes", "chars"] ->
        text = format(text(f, s), fmt_args(a, s), s)
        val = case kind do
          "atom" -> text
          "chars" -> chars(text)
          _ -> codes(text)
        end
        u(r, val, s)

      _ ->
        emit(format(text(f, s), fmt_args(a, s), s))
    end
  end

  defp with_output_to([sink, g], s) do
    {r, text} = capture(fn -> Engine.once(g, s) end)

    case r do
      {:ok, s2} ->
        case deref(sink, s2) do
          {:c, "atom", [x]} -> u(x, text, s2)
          {:c, "string", [x]} -> u(x, codes(text), s2)
          {:c, "codes", [x]} -> u(x, codes(text), s2)
          {:c, "chars", [x]} -> u(x, chars(text), s2)
          x -> domain!("output_sink", x)
        end

      :fail ->
        false
    end
  end

  # Runs Goal once with a budget of user-predicate calls. Exceeding it unwinds
  # with an Elixir throw that Prolog-level catch/3 cannot intercept.
  defp inference_limit([g, limit, r], s) do
    budget = int_arg(limit, s)
    outer = Process.get(:pl_inf_limit)
    mine = Process.get(:pl_inf) + budget
    Process.put(:pl_inf_limit, if(outer, do: min(outer, mine), else: mine))

    try do
      case Engine.solve(g, s) do
        {:ok, s2, {cps, _}} -> u(r, if(cps == [], do: "!", else: "true"), s2)
        :fail -> false
      end
    catch
      {:pl_limit, ^mine} -> u(r, "inference_limit_exceeded", s)
    after
      Process.put(:pl_inf_limit, outer)
    end
  end

  defp read_stdin(t, s) do
    case read_clause_text("") do
      :eof -> u(t, "end_of_file", s)
      text ->
        case Parser.read_term(text) do
          {:ok, term, _} -> u(t, term, s)
          {:error, m} -> err(Term.err({:c, "syntax_error", [m]}))
        end
    end
  end

  defp read_clause_text(acc) do
    case IO.gets("") do
      :eof -> if String.trim(acc) == "", do: :eof, else: acc
      {:error, _} -> :eof
      line ->
        acc = acc <> line
        if String.trim_trailing(acc) |> String.ends_with?("."), do: acc, else: read_clause_text(acc)
    end
  end

  defp statistics([k, v], s) do
    case text(k, s) do
      key when key in ["runtime", "process_cputime", "cputime"] ->
        {t, since} = :erlang.statistics(:runtime)
        if key == "cputime", do: u(v, t / 1000, s), else: u(v, Term.list([t, since]), s)

      key when key in ["walltime", "real_time"] ->
        {t, since} = :erlang.statistics(:wall_clock)
        u(v, Term.list([t, since]), s)

      "inferences" -> u(v, Process.get(:pl_inf, 0), s)
      _ -> domain!("statistics_key", k)
    end
  end

  defp consult([f], s) do
    name = text(f, s)
    path = if File.exists?(name), do: name, else: name <> ".pl"

    case File.read(path) do
      {:ok, src} -> Engine.consult_string(src) && true
      _ -> err(Term.err({:c, "existence_error", ["source_sink", name]}))
    end
  end

  # --- format/2 ---------------------------------------------------------------------------------

  defp fmt_args(a, s) do
    case Term.to_list(a, s) do
      {:ok, items} -> items
      _ -> [a]
    end
  end

  @doc false
  def format(f, args, s) do
    {segments, _args} = fmt(String.to_charlist(f), args, s, [], [])
    layout(segments, column())
  end

  # The output is built as a list of segments separated by column stops so
  # that ~t (fill) and ~N| / ~N+ (column stop) can pad text.
  defp fmt([], args, _s, cur, acc), do: {Enum.reverse([{:text, Enum.reverse(cur)} | acc]), args}

  defp fmt([?~ | rest], args, s, cur, acc) do
    {numarg, rest, args} =
      case rest do
        [?* | r] -> [n | as] = args; {int_arg(n, s), r, as}
        [?` , c | r] -> {c, r, args}
        _ ->
          {ds, r} = Enum.split_while(rest, &(&1 in ?0..?9))
          {if(ds == [], do: nil, else: List.to_integer(ds)), r, args}
      end

    [d | rest] = rest
    take = fn -> case args do
      [x | xs] -> {x, xs}
      [] -> err(Term.err({:c, "format", ["not enough arguments"]}))
    end end

    case d do
      ?~ -> fmt(rest, args, s, [?~ | cur], acc)
      ?n -> fmt(rest, args, s, Enum.reverse(String.to_charlist(String.duplicate("\n", numarg || 1))) ++ cur, acc)
      ?t -> fmt(rest, args, s, [{:fill, numarg || ?\s} | cur], acc)
      ?| -> fmt(rest, args, s, [], [{:stop, :abs, numarg} , {:text, Enum.reverse(cur)} | acc])
      ?+ -> fmt(rest, args, s, [], [{:stop, :rel, numarg || 8}, {:text, Enum.reverse(cur)} | acc])
      ?i -> {_, as} = take.(); fmt(rest, as, s, cur, acc)
      _ ->
        {x, as} = take.()

        str =
          case d do
            ?w -> Writer.to_string(x, s)
            ?p -> Writer.to_string(x, s, quoted: true)
            ?q -> Writer.to_string(x, s, quoted: true)
            ?a -> text(x, s)
            ?d -> fmt_int(Arith.eval(x, s), numarg, false)
            ?D -> fmt_int(Arith.eval(x, s), numarg, true)
            ?s -> text(x, s)
            ?c -> String.duplicate(<<int_arg(x, s)::utf8>>, numarg || 1)
            ?e -> :io_lib.format(~c"~.#{numarg || 6}e", [Arith.eval(x, s) * 1.0]) |> IO.iodata_to_binary()
            ?f -> :erlang.float_to_binary(Arith.eval(x, s) * 1.0, decimals: numarg || 6)
            ?g -> Writer.float(Arith.eval(x, s) * 1.0)
            ?r -> Integer.to_string(Arith.eval(x, s), numarg || 8) |> String.downcase()
            ?R -> Integer.to_string(Arith.eval(x, s), numarg || 8)
            other -> err(Term.err({:c, "format", ["unknown directive ~" <> <<other>>]}))
          end

        fmt(rest, as, s, Enum.reverse(String.to_charlist(str)) ++ cur, acc)
    end
  end

  defp fmt([c | rest], args, s, cur, acc), do: fmt(rest, args, s, [c | cur], acc)

  defp fmt_int(n, nil, false), do: Integer.to_string(n)
  defp fmt_int(n, 0, false), do: Integer.to_string(n)
  defp fmt_int(n, nil, true), do: group(Integer.to_string(n))
  defp fmt_int(n, 0, true), do: group(Integer.to_string(n))

  defp fmt_int(n, k, grp) do
    sign = if n < 0, do: "-", else: ""
    digits = Integer.to_string(abs(n)) |> String.pad_leading(k + 1, "0")
    {ip, fp} = String.split_at(digits, String.length(digits) - k)
    sign <> if(grp, do: group(ip), else: ip) <> "." <> fp
  end

  defp group(str) do
    {sign, digits} = if String.starts_with?(str, "-"), do: {"-", String.slice(str, 1..-1)}, else: {"", str}
    sign <> (digits |> String.reverse() |> String.graphemes() |> Enum.chunk_every(3) |> Enum.map(&Enum.join/1) |> Enum.join(",") |> String.reverse())
  end

  defp layout(segments, col0) do
    {out, _col} =
      Enum.reduce(Enum.chunk_every(segments, 2, 2, [nil]), {[], col0}, fn
        [{:text, items}, stop], {out, col} ->
          {str, fills} = render_items(items)
          seg_start = col

          {padded, newcol} =
            case stop do
              nil -> {str, col + String.length(str)}
              {:stop, kind, n} ->
                target = if kind == :abs, do: n || col + String.length(str), else: seg_start + n
                width = target - seg_start
                {pad(str, fills, width), max(target, seg_start + String.length(str))}
            end

          last_nl = case :binary.matches(padded, "\n") do
            [] -> nil
            ms -> elem(List.last(ms), 0)
          end

          newcol = if last_nl, do: String.length(padded) - last_nl - 1, else: newcol
          {[out, padded], newcol}

        [{:stop, _, _} | _], acc -> acc
      end)

    IO.iodata_to_binary(out)
  end

  defp render_items(items) do
    Enum.reduce(items, {"", []}, fn
      {:fill, ch}, {str, fills} -> {str, fills ++ [{String.length(str), ch}]}
      c, {str, fills} -> {str <> <<c::utf8>>, fills}
    end)
  end

  defp pad(str, fills, width) do
    len = String.length(str)

    if len >= width do
      str
    else
      extra = width - len

      case fills do
        [] -> str <> String.duplicate(" ", extra)
        _ ->
          # distribute padding over fill points (all to the first, for simplicity)
          {pos, ch} = hd(fills)
          {a, b} = String.split_at(str, pos)
          a <> String.duplicate(<<ch::utf8>>, extra) <> b
      end
    end
  end
end
