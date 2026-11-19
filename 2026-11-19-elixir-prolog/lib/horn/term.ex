defmodule Horn.Term do
  @moduledoc """
  Term representation and the core operations on it.

    * atoms      -> Elixir binaries (`"foo"`, `"[]"` is the *quoted* atom '[]')
    * `[]`       -> Elixir `[]`: like SWI-Prolog 7+, the empty list is a reserved
                    constant distinct from the atom '[]' (atom([]) fails)
    * integers   -> Elixir integers (arbitrary precision, like SWI's GMP ints)
    * floats     -> Elixir floats
    * variables  -> `{:v, id}`
    * compounds  -> `{:c, name, [arg1, ..., argN]}`; lists use `'[|]'/2`

  Bindings live in an immutable map `id => term` (the *substitution*).
  Because the map is persistent, backtracking is free: a choicepoint just
  remembers the map it started from - there is no trail to undo.
  """

  def var?({:v, _}), do: true
  def var?(_), do: false

  def fresh_var do
    n = Process.get(:pl_vc, 0)
    Process.put(:pl_vc, n + 1)
    {:v, n}
  end

  def reserve(k) do
    n = Process.get(:pl_vc, 0)
    Process.put(:pl_vc, n + k)
    n
  end

  def deref({:v, n} = t, s) do
    case s do
      %{^n => b} -> deref(b, s)
      _ -> t
    end
  end

  def deref(t, _s), do: t

  @doc "Fully apply the substitution (result contains only unbound variables)."
  def resolve(t, s) do
    case deref(t, s) do
      {:c, f, args} -> {:c, f, Enum.map(args, &resolve(&1, s))}
      x -> x
    end
  end

  # --- unification -----------------------------------------------------------

  def unify(a, b, s) do
    if Process.get(:pl_occurs, false), do: unify_oc(a, b, s), else: unify_(a, b, s)
  end

  defp unify_(a, b, s) do
    a = deref(a, s)
    b = deref(b, s)

    cond do
      a === b -> {:ok, s}
      match?({:v, _}, a) -> {:ok, Map.put(s, elem(a, 1), b)}
      match?({:v, _}, b) -> {:ok, Map.put(s, elem(b, 1), a)}
      true -> unify_nv(a, b, s, &unify_/3)
    end
  end

  defp unify_oc(a, b, s) do
    a = deref(a, s)
    b = deref(b, s)

    cond do
      a === b -> {:ok, s}
      match?({:v, _}, a) -> bind_oc(a, b, s)
      match?({:v, _}, b) -> bind_oc(b, a, s)
      true -> unify_nv(a, b, s, &unify_oc/3)
    end
  end

  defp bind_oc({:v, n} = v, t, s) do
    if occurs?(v, t, s), do: :fail, else: {:ok, Map.put(s, n, t)}
  end

  defp unify_nv({:c, f, xs}, {:c, f, ys}, s, k) when length(xs) == length(ys), do: unify_args(xs, ys, s, k)
  defp unify_nv(_, _, _s, _k), do: :fail

  defp unify_args([], [], s, _k), do: {:ok, s}

  defp unify_args([x | xs], [y | ys], s, k) do
    case k.(x, y, s) do
      {:ok, s} -> unify_args(xs, ys, s, k)
      :fail -> :fail
    end
  end

  def occurs?(v, t, s) do
    case deref(t, s) do
      ^v -> true
      {:c, _, args} -> Enum.any?(args, &occurs?(v, &1, s))
      _ -> false
    end
  end

  # --- standard order of terms ------------------------------------------------

  def compare(a, b, s) do
    a = deref(a, s)
    b = deref(b, s)
    ra = rank(a)
    rb = rank(b)

    cond do
      ra != rb -> sign(ra - rb)
      true -> cmp_same(a, b, s)
    end
  end

  defp rank({:v, _}), do: 0
  defp rank(x) when is_number(x), do: 1
  defp rank([]), do: 2
  defp rank(x) when is_binary(x), do: 3
  defp rank({:c, _, _}), do: 4

  defp cmp_same({:v, x}, {:v, y}, _), do: sign(x - y)
  defp cmp_same([], [], _), do: 0

  defp cmp_same(x, y, _) when is_number(x) do
    cond do
      x < y -> -1
      x > y -> 1
      is_float(x) and is_integer(y) -> -1
      is_integer(x) and is_float(y) -> 1
      true -> 0
    end
  end

  defp cmp_same(x, y, _) when is_binary(x) do
    cond do
      x < y -> -1
      x > y -> 1
      true -> 0
    end
  end

  defp cmp_same({:c, f, xs}, {:c, g, ys}, s) do
    cond do
      length(xs) != length(ys) -> sign(length(xs) - length(ys))
      f != g -> if f < g, do: -1, else: 1
      true -> cmp_args(xs, ys, s)
    end
  end

  defp cmp_args([], [], _), do: 0

  defp cmp_args([x | xs], [y | ys], s) do
    case compare(x, y, s) do
      0 -> cmp_args(xs, ys, s)
      r -> r
    end
  end

  defp sign(0), do: 0
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 1

  # --- lists -------------------------------------------------------------------

  def list(items, tail \\ []), do: List.foldr(items, tail, fn x, acc -> {:c, "[|]", [x, acc]} end)

  @doc "Proper list -> {:ok, items}; partial -> {:partial, items, var}; else :error"
  def to_list(t, s), do: to_list(t, s, [])

  defp to_list(t, s, acc) do
    case deref(t, s) do
      [] -> {:ok, Enum.reverse(acc)}
      {:c, "[|]", [h, tl]} -> to_list(tl, s, [h | acc])
      {:v, _} = v -> {:partial, Enum.reverse(acc), v}
      _ -> :error
    end
  end

  # --- variables & copying ------------------------------------------------------

  def term_vars(t, s), do: t |> tv(s, []) |> Enum.reverse() |> Enum.uniq()

  defp tv(t, s, acc) do
    case deref(t, s) do
      {:v, _} = v -> [v | acc]
      {:c, _, args} -> Enum.reduce(args, acc, &tv(&1, s, &2))
      _ -> acc
    end
  end

  @doc "copy a term, giving its unbound variables fresh identities"
  def copy(t, s) do
    r = resolve(t, s)
    {c, _} = rename(r, %{})
    c
  end

  defp rename({:v, _} = v, m) do
    case m do
      %{^v => n} -> {n, m}
      _ ->
        n = fresh_var()
        {n, Map.put(m, v, n)}
    end
  end

  defp rename({:c, f, args}, m) do
    {args2, m} = Enum.map_reduce(args, m, &rename/2)
    {{:c, f, args2}, m}
  end

  defp rename(x, m), do: {x, m}

  def callable?(t), do: is_binary(t) or match?({:c, _, _}, t)

  def add_args(g, []), do: g
  def add_args(name, extra) when is_binary(name), do: {:c, name, extra}
  def add_args({:c, f, args}, extra), do: {:c, f, args ++ extra}
  def add_args(other, _), do: throw({:pl_error, type_error("callable", other)})

  def err(formal), do: {:c, "error", [formal, fresh_var()]}
  def type_error(type, culprit), do: err({:c, "type_error", [type, culprit]})
  def inst_error, do: err("instantiation_error")
  def pi(name, arity), do: {:c, "/", [name, arity]}
end
