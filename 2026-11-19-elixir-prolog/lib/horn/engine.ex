defmodule Horn.Engine do
  @moduledoc """
  The resolution engine: an iterative goal-stack / choicepoint-stack machine.

  * `goals`  - continuation: a list of frames still to run
      - `{:call, goal, cut_barrier}`   run `goal`; `!` inside cuts back to `cut_barrier`
      - `{:cut_to, depth}`             discard choicepoints above `depth` (if-then-else)
      - `{:soft, ref}`                 condition of `*->` succeeded: disable its else-branch
      - `{:exit_catch, id}`            the goal of `catch/3` exited: deactivate the catcher
  * `cps`    - choicepoint stack (a list, newest first) and its length `d`
      - `{:alt, goals, s, catches}`                     resume an alternative branch
      - `{:alt_soft, ref, goals, s, catches}`           `*->` else-branch (may be disabled)
      - `{:clauses, args, clauses, key, goals, s, catches}`  try the remaining clauses
      - `{:gen, next_fun, goals, catches}`              nondeterministic builtin
      - `{:catch, id, catcher, recovery, goals, s, catches}`
  * `s`      - persistent substitution map (so backtracking needs no trail)
  * `cat`    - ids of catch/3 frames whose goal is currently executing

  All dispatch functions are mutually tail-recursive, so deterministic
  recursion in Prolog runs in constant Elixir stack.
  """
  alias Horn.{Term, Builtins, Parser}
  import Term, only: [deref: 2]

  # =============================================================================
  # Database
  # =============================================================================

  def init do
    Process.put(:pl_vc, 0)
    Process.put(:pl_db, %{})
    Process.put(:pl_lib, MapSet.new())
    Process.put(:pl_inf, 0)
    Process.put(:pl_soft, MapSet.new())
    Process.put(:pl_globals, %{})
    Process.put(:pl_occurs, false)
    Process.put(:pl_unknown, "error")
    Parser.init_ops()
    consult_string(Horn.Prelude.source(), library: true)
    Process.put(:pl_lib, Map.keys(db()) |> MapSet.new())
    :ok
  end

  def db, do: Process.get(:pl_db)
  defp put_db(db), do: Process.put(:pl_db, db)

  def compile_clause(term, s \\ %{}) do
    t = Term.resolve(term, s)

    {head, body} =
      case t do
        {:c, ":-", [h, b]} -> {h, b}
        h -> {h, "true"}
      end

    {name, args} =
      case head do
        {:v, _} -> throw({:pl_error, Term.inst_error()})
        n when is_binary(n) -> {n, []}
        {:c, n, as} -> {n, as}
        other -> throw({:pl_error, Term.type_error("callable", other)})
      end

    body = wrap_vars(body)
    {{:c, "h", nargs}, map} = number_vars({:c, "h", args}, %{})
    {nbody, map} = number_vars(body, map)

    key =
      case nargs do
        [] -> nil
        [a | _] -> key_of(a)
      end

    {{name, length(args)}, {make_ref(), Enum.map(nargs, &tag_ground/1), tag_ground(nbody), map_size(map), key}}
  end

  defp number_vars({:v, _} = v, m) do
    case m do
      %{^v => n} -> {n, m}
      _ ->
        n = {:v, map_size(m)}
        {n, Map.put(m, v, n)}
    end
  end

  defp number_vars({:c, f, args}, m) do
    {args, m} = Enum.map_reduce(args, m, &number_vars/2)
    {{:c, f, args}, m}
  end

  defp number_vars(x, m), do: {x, m}

  @doc "Turn variables in goal positions into call/1 so cut inside them stays local."
  def wrap_vars({:v, _} = v), do: {:c, "call", [v]}
  def wrap_vars({:c, f, [a, b]}) when f in [",", ";", "->", "*->"], do: {:c, f, [wrap_vars(a), wrap_vars(b)]}
  def wrap_vars(t), do: t

  defp key_of({:v, _}), do: nil
  defp key_of({:c, f, as}), do: {f, length(as)}
  defp key_of(x), do: x

  def add_clause(term, s \\ %{}, where \\ :z) do
    {key, clause} = compile_clause(term, s)

    if Builtins.builtin?(key) or key in [{",", 2}, {";", 2}, {"->", 2}, {"!", 0}] do
      {name, ar} = key
      throw({:pl_error, Term.err({:c, "permission_error", ["modify", "static_procedure", Term.pi(name, ar)]})})
    end

    db = db()
    cls = Map.get(db, key, [])
    cls = if where == :a, do: [clause | cls], else: cls ++ [clause]
    put_db(Map.put(db, key, cls))
    :ok
  end

  def declare_dynamic(key), do: put_db(Map.update(db(), key, [], & &1))

  def remove_clause(key, ref) do
    put_db(Map.update(db(), key, [], fn cls -> Enum.reject(cls, &(elem(&1, 0) == ref)) end))
  end

  def clauses(key), do: Map.get(db(), key)

  def rename_clause({_ref, args, body, n, _key}) do
    base = Term.reserve(n)
    {off_list(args, base), off(body, base)}
  end

  # Renaming is the hottest path of the engine: plain recursion (no closures),
  # and ground subterms (tagged {:g, t} at compile time) are shared as-is.
  defp off({:v, i}, base), do: {:v, i + base}
  defp off({:c, f, args}, base), do: {:c, f, off_list(args, base)}
  defp off({:g, t}, _), do: t
  defp off(x, _), do: x

  defp off_list([], _), do: []
  defp off_list([a | as], base), do: [off(a, base) | off_list(as, base)]

  defp tag_ground({:c, f, args} = t) do
    args2 = Enum.map(args, &tag_ground/1)

    if Enum.all?(args2, &ground_tagged?/1) do
      {:g, t}
    else
      {:c, f, args2}
    end
  end

  defp tag_ground(t), do: t

  defp ground_tagged?({:g, _}), do: true
  defp ground_tagged?({:v, _}), do: false
  defp ground_tagged?({:c, _, _}), do: false
  defp ground_tagged?(_), do: true

  # =============================================================================
  # Consulting
  # =============================================================================

  def consult_string(text, opts \\ []) do
    lib = Keyword.get(opts, :library, false)
    Process.put(:pl_seen, MapSet.new())
    Process.put(:pl_init_goals, [])

    for item <- Parser.read_all(text) do
      case item do
        {:ok, t, _names} -> load_term(t, lib)
        {:error, msg} -> warn("syntax error: #{msg}")
      end
    end

    goals = Enum.reverse(Process.get(:pl_init_goals))
    Process.put(:pl_init_goals, [])
    Enum.each(goals, fn {g, mode} -> run_directive(g, mode) end)
    :ok
  end

  defp load_term({:c, ":-", [d]}, _lib) do
    case d do
      {:c, "initialization", [g]} -> Process.put(:pl_init_goals, [{g, :once} | Process.get(:pl_init_goals)])
      {:c, "initialization", [g, "main"]} -> Process.put(:pl_init_goals, [{g, :main} | Process.get(:pl_init_goals)])
      _ -> run_directive(d, :once)
    end
  end

  defp load_term({:c, "-->", [_, _]} = rule, lib) do
    case once({:c, "dcg_translate_rule", [rule, {:v, -1}]}, %{}) do
      {:ok, s} -> load_term(Term.resolve({:v, -1}, s), lib)
      _ -> warn("could not translate DCG rule")
    end
  end

  defp load_term(t, lib) do
    try do
      {key, _} = compile_clause(t)

      if not lib do
        seen = Process.get(:pl_seen)

        if MapSet.member?(Process.get(:pl_lib), key) and not MapSet.member?(seen, key) do
          put_db(Map.delete(db(), key))
          Process.put(:pl_lib, MapSet.delete(Process.get(:pl_lib), key))
        end

        Process.put(:pl_seen, MapSet.put(seen, key))
      end

      add_clause(t)
    catch
      {:pl_error, e} -> warn("cannot add clause: " <> Horn.Writer.to_string(e, %{}, quoted: true))
    end
  end

  defp run_directive(g, mode) do
    try do
      case once(g, %{}) do
        {:ok, _} -> :ok
        :fail -> warn("goal (directive) failed: " <> Horn.Writer.to_string(g, %{}, quoted: true))
      end

      if mode == :main, do: throw({:pl_halt, 0})
    catch
      {:pl_uncaught, b} ->
        warn("uncaught exception in directive: " <> Horn.Writer.to_string(b, %{}, quoted: true))
        if mode == :main, do: throw({:pl_halt, 1})
    end
  end

  def warn(msg), do: IO.puts(:stderr, "Warning: " <> msg)

  # =============================================================================
  # Solving API
  # =============================================================================

  @doc "First solution: {:ok, subst, resume} | :fail.  Raises {:pl_uncaught, ball}."
  def solve(goal, s \\ %{}) do
    run([{:call, wrap_vars(goal), 0}], s, [], 0, [])
  end

  def next({cps, d}), do: backtrack(cps, d)

  def once(goal, s) do
    case solve(goal, s) do
      {:ok, s, _} -> {:ok, s}
      :fail -> :fail
    end
  end

  @doc "All solutions as a list of substitutions (used by findall/bagof/forall)."
  def all(goal, s, fun) do
    collect(solve(goal, s), fun, [])
  end

  defp collect(:fail, _fun, acc), do: Enum.reverse(acc)
  defp collect({:ok, s, k}, fun, acc), do: collect(next(k), fun, [fun.(s) | acc])

  # =============================================================================
  # The machine
  # =============================================================================

  defp run([], s, cps, d, _cat), do: {:ok, s, {cps, d}}

  defp run([{:call, g, cb} | rest], s, cps, d, cat), do: step(deref(g, s), cb, rest, s, cps, d, cat)

  defp run([{:cut_to, h} | rest], s, cps, d, cat) do
    {cps, d} = cut(cps, d, h)
    run(rest, s, cps, d, cat)
  end

  defp run([{:soft, ref} | rest], s, cps, d, cat) do
    Process.put(:pl_soft, MapSet.put(Process.get(:pl_soft), ref))
    run(rest, s, cps, d, cat)
  end

  defp run([{:exit_catch, id} | rest], s, cps, d, cat), do: run(rest, s, cps, d, List.delete(cat, id))

  defp cut(cps, d, h) when d > h, do: cut(tl(cps), d - 1, h)
  defp cut(cps, d, _h), do: {cps, d}

  defp backtrack([], _d), do: :fail

  defp backtrack([cp | cps], d) do
    d = d - 1

    case cp do
      {:alt, goals, s, cat} ->
        run(goals, s, cps, d, cat)

      {:alt_soft, ref, goals, s, cat} ->
        soft = Process.get(:pl_soft)

        if MapSet.member?(soft, ref) do
          Process.put(:pl_soft, MapSet.delete(soft, ref))
          backtrack(cps, d)
        else
          run(goals, s, cps, d, cat)
        end

      {:clauses, args, clauses, key, goals, s, cat} ->
        try_clauses(args, clauses, key, goals, s, cps, d, cat)

      {:gen, nextf, goals, cat} ->
        case guard(fn -> nextf.() end) do
          {:throw, ball, now} -> handle_throw(Term.copy(ball, %{}), now, cps, d, cat)
          nil -> backtrack(cps, d)
          {s2, nil} -> run(goals, s2, cps, d, cat)
          {s2, nf} -> run(goals, s2, [{:gen, nf, goals, cat} | cps], d + 1, cat)
        end

      {:catch, _, _, _, _, _, _} ->
        backtrack(cps, d)
    end
  end

  # --- control constructs --------------------------------------------------------

  defp step({:v, _}, _cb, _rest, s, cps, d, cat), do: handle_throw(Term.inst_error(), s, cps, d, cat)
  defp step("true", _cb, rest, s, cps, d, cat), do: run(rest, s, cps, d, cat)
  defp step("fail", _cb, _rest, _s, cps, d, _cat), do: backtrack(cps, d)
  defp step("false", _cb, _rest, _s, cps, d, _cat), do: backtrack(cps, d)

  defp step("!", cb, rest, s, cps, d, cat) do
    {cps, d} = cut(cps, d, cb)
    run(rest, s, cps, d, cat)
  end

  defp step({:c, ",", [a, b]}, cb, rest, s, cps, d, cat),
    do: run([{:call, a, cb}, {:call, b, cb} | rest], s, cps, d, cat)

  defp step({:c, ";", [l, e]}, cb, rest, s, cps, d, cat) do
    case deref(l, s) do
      {:c, "->", [c, t]} ->
        cp = {:alt, [{:call, e, cb} | rest], s, cat}
        run([{:call, c, d + 1}, {:cut_to, d}, {:call, t, cb} | rest], s, [cp | cps], d + 1, cat)

      {:c, "*->", [c, t]} ->
        ref = make_ref()
        cp = {:alt_soft, ref, [{:call, e, cb} | rest], s, cat}
        run([{:call, c, d + 1}, {:soft, ref}, {:call, t, cb} | rest], s, [cp | cps], d + 1, cat)

      l ->
        cp = {:alt, [{:call, e, cb} | rest], s, cat}
        run([{:call, l, cb} | rest], s, [cp | cps], d + 1, cat)
    end
  end

  defp step({:c, "->", [c, t]}, cb, rest, s, cps, d, cat) do
    cp = {:alt, [{:call, "fail", cb}], s, cat}
    run([{:call, c, d + 1}, {:cut_to, d}, {:call, t, cb} | rest], s, [cp | cps], d + 1, cat)
  end

  defp step({:c, "*->", [c, t]}, cb, rest, s, cps, d, cat),
    do: run([{:call, c, d}, {:call, t, cb} | rest], s, cps, d, cat)

  defp step({:c, neg, [g]}, _cb, rest, s, cps, d, cat) when neg in ["\\+", "not"] do
    cp = {:alt, rest, s, cat}
    run([{:call, g, d + 1}, {:cut_to, d}, {:call, "fail", 0}], s, [cp | cps], d + 1, cat)
  end

  defp step({:c, "call", [g | extra]}, _cb, rest, s, cps, d, cat) do
    case guard(fn -> callable!(Term.add_args(deref(g, s), extra), s) end) do
      {:throw, ball, now} -> handle_throw(Term.copy(ball, s), now || s, cps, d, cat)
      g2 -> run([{:call, g2, d} | rest], s, cps, d, cat)
    end
  end

  defp step({:c, "findall", [t, g, l]}, _cb, rest, s, cps, d, cat) do
    case guard(fn -> all(callable!(g, s), s, &Term.copy(t, &1)) end) do
      {:throw, ball, now} -> handle_throw(Term.copy(ball, s), now || s, cps, d, cat)
      results -> unify_then(l, Term.list(results), rest, s, cps, d, cat)
    end
  end

  defp step({:c, "findall", [t, g, l, tail]}, _cb, rest, s, cps, d, cat) do
    case guard(fn -> all(g, s, &Term.copy(t, &1)) end) do
      {:throw, ball, now} -> handle_throw(Term.copy(ball, s), now || s, cps, d, cat)
      results -> unify_then(l, Term.list(results, tail), rest, s, cps, d, cat)
    end
  end

  defp step({:c, "forall", [c, a]}, cb, rest, s, cps, d, cat) do
    g = {:c, "\\+", [{:c, ",", [c, {:c, "\\+", [a]}]}]}
    step(g, cb, rest, s, cps, d, cat)
  end

  defp step({:c, "catch", [g, catcher, recovery]}, _cb, rest, s, cps, d, cat) do
    id = make_ref()
    cp = {:catch, id, catcher, recovery, rest, s, cat}
    run([{:call, g, d + 1}, {:exit_catch, id} | rest], s, [cp | cps], d + 1, [id | cat])
  end

  defp step({:c, "throw", [ball]}, _cb, _rest, s, cps, d, cat) do
    case deref(ball, s) do
      {:v, _} -> handle_throw(Term.inst_error(), s, cps, d, cat)
      _ -> handle_throw(Term.copy(ball, s), s, cps, d, cat)
    end
  end

  defp step(n, _cb, _rest, s, cps, d, cat) when is_number(n) or n == [],
    do: handle_throw(Term.type_error("callable", n), s, cps, d, cat)

  defp step(g, _cb, rest, s, cps, d, cat) do
    {name, args} =
      case g do
        {:c, n, a} -> {n, a}
        n -> {n, []}
      end

    key = {name, length(args)}

    case Builtins.get(key) do
      nil -> call_user(key, args, g, rest, s, cps, d, cat)
      {:det, f} -> det(f, args, rest, s, cps, d, cat)
      {:nondet, f} -> nondet(f, args, rest, s, cps, d, cat)
    end
  end

  defp det(f, args, rest, s, cps, d, cat) do
    case guard(fn -> f.(args, s) end) do
      {:ok, s2} -> run(rest, s2, cps, d, cat)
      true -> run(rest, s, cps, d, cat)
      {:throw, ball, now} -> handle_throw(Term.copy(ball, s), now || s, cps, d, cat)
      _ -> backtrack(cps, d)
    end
  end

  defp nondet(f, args, rest, s, cps, d, cat) do
    case guard(fn -> f.(args, s) end) do
      {:throw, ball, now} -> handle_throw(Term.copy(ball, s), now || s, cps, d, cat)
      nil -> backtrack(cps, d)
      {s2, nil} -> run(rest, s2, cps, d, cat)
      {s2, nf} -> run(rest, s2, [{:gen, nf, rest, cat} | cps], d + 1, cat)
    end
  end

  defp guard(fun) do
    try do
      fun.()
    rescue
      ArithmeticError -> {:throw, Term.err({:c, "evaluation_error", ["float_overflow"]}), nil}
    catch
      {:pl_error, ball} -> {:throw, ball, nil}
      # escaped from a nested engine (findall/3 etc.): also carry the bindings
      # that were current at the throw, for SWI-style catcher selection
      {:pl_uncaught, ball} -> {:throw, ball, Process.delete(:pl_throw_now)}
    end
  end

  defp callable!(g, s) do
    case deref(g, s) do
      {:v, _} -> throw({:pl_error, Term.inst_error()})
      n when is_number(n) -> throw({:pl_error, Term.type_error("callable", n)})
      g ->
        # like SWI, a meta-called control structure is checked as a whole
        if bad_body?(g, s), do: throw({:pl_error, Term.type_error("callable", Term.resolve(g, s))})
        g
    end
  end

  defp bad_body?(g, s) do
    case deref(g, s) do
      n when is_number(n) -> true
      {:c, f, [a, b]} when f in [",", ";", "->", "*->"] -> bad_body?(a, s) or bad_body?(b, s)
      {:c, "\\+", [a]} -> bad_body?(a, s)
      _ -> false
    end
  end

  defp unify_then(a, b, rest, s, cps, d, cat) do
    case Term.unify(a, b, s) do
      {:ok, s} -> run(rest, s, cps, d, cat)
      :fail -> backtrack(cps, d)
    end
  end

  # --- user predicates ---------------------------------------------------------------

  defp call_user(key, args, g, rest, s, cps, d, cat) do
    case Map.fetch(db(), key) do
      {:ok, clauses} ->
        k = case args do
          [] -> nil
          [a | _] -> key_of(deref(a, s))
        end

        try_clauses(args, match(clauses, k), k, rest, s, cps, d, cat)

      :error ->
        if Process.get(:pl_unknown) == "fail" do
          backtrack(cps, d)
        else
          {name, ar} = key
          _ = g
          handle_throw(Term.err({:c, "existence_error", ["procedure", Term.pi(name, ar)]}), s, cps, d, cat)
        end
    end
  end

  # "inferences" = head unification attempts; also enforces
  # call_with_inference_limit/3 budgets
  defp tick do
    inf = Process.get(:pl_inf) + 1
    Process.put(:pl_inf, inf)

    case Process.get(:pl_inf_limit) do
      nil -> :ok
      lim when inf > lim -> throw({:pl_limit, lim})
      _ -> :ok
    end
  end

  defp match(cls, nil), do: cls
  defp match([], _k), do: []
  defp match([c | cs] = all, k) do
    ck = elem(c, 4)
    if ck == nil or ck === k, do: all, else: match(cs, k)
  end

  defp try_clauses(_args, [], _k, _rest, _s, cps, d, _cat), do: backtrack(cps, d)

  defp try_clauses(args, [c | more], k, rest, s, cps, d, cat) do
    tick()
    more = match(more, k)
    {hargs, body} = rename_clause(c)

    case unify_list(hargs, args, s) do
      {:ok, s2} ->
        goals = if body == "true", do: rest, else: [{:call, body, d} | rest]

        if more == [] do
          run(goals, s2, cps, d, cat)
        else
          run(goals, s2, [{:clauses, args, more, k, rest, s, cat} | cps], d + 1, cat)
        end

      :fail ->
        try_clauses(args, more, k, rest, s, cps, d, cat)
    end
  end

  defp unify_list([], [], s), do: {:ok, s}

  defp unify_list([a | as], [b | bs], s) do
    case Term.unify(a, b, s) do
      {:ok, s} -> unify_list(as, bs, s)
      :fail -> :fail
    end
  end

  # --- exceptions ----------------------------------------------------------------------

  # SWI-Prolog selects the catch/3 frame by unifying the catcher with the ball
  # *before* undoing the bindings made since the catch (so a catcher that only
  # matches after backtracking is skipped), then unifies again after undoing.
  defp handle_throw(ball, now, [], _d, _cat) do
    Process.put(:pl_throw_now, now)
    throw({:pl_uncaught, ball})
  end

  defp handle_throw(ball, now, [{:catch, id, catcher, recovery, goals, s0, cat0} | cps], d, cat) do
    matches_now = now == nil or Term.unify(catcher, ball, now) != :fail

    if id in cat and matches_now do
      case Term.unify(catcher, ball, s0) do
        {:ok, s1} -> run([{:call, recovery, d - 1} | goals], s1, cps, d - 1, cat0)
        :fail -> handle_throw(ball, now, cps, d - 1, cat)
      end
    else
      handle_throw(ball, now, cps, d - 1, cat)
    end
  end

  defp handle_throw(ball, now, [_ | cps], d, cat), do: handle_throw(ball, now, cps, d - 1, cat)
end
