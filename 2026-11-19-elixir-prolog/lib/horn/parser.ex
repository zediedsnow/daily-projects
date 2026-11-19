defmodule Horn.Parser do
  @moduledoc """
  Operator-precedence parser producing `Horn.Term` terms.

  The operator table is dynamic (`op/3` changes it), so it lives in the
  process dictionary under `:pl_ops` as `name => %{prefix:, infix:, postfix:}`.
  """
  alias Horn.{Lexer, Term}

  @default_ops [
    {1200, :xfx, ~w(:- -->)},
    {1200, :fx, ~w(:- ?-)},
    {1100, :xfy, ~w(; |)},
    {1105, :xfy, ~w(|)},
    {1050, :xfy, ~w(-> *->)},
    {1000, :xfy, [","]},
    {990, :xfx, ~w(:=)},
    {900, :fy, ~w(\\+)},
    {700, :xfx, ~w(= \\= == \\== @< @> @=< @>= =.. is =:= =\\= < > =< >= >:< :< as =@= \\=@=)},
    {600, :xfy, ~w(:)},
    {500, :yfx, ~w(+ - /\\ \\/ xor)},
    {400, :yfx, ~w(* / // mod rem << >> div rdiv divmod)},
    {200, :xfx, ~w(**)},
    {200, :xfy, ~w(^)},
    {200, :fy, ~w(- + \\)},
    {100, :yfx, ~w(.)},
    {1, :fx, ~w($)},
    {1150, :fx, ~w(dynamic discontiguous initialization meta_predicate module_transparent multifile public thread_local table)}
  ]

  def init_ops do
    ops =
      Enum.reduce(@default_ops, %{}, fn {p, type, names}, acc ->
        Enum.reduce(names, acc, fn n, acc -> put_op(acc, n, p, type) end)
      end)

    Process.put(:pl_ops, ops)
  end

  def ops do
    case Process.get(:pl_ops) do
      nil ->
        init_ops()
        Process.get(:pl_ops)

      ops ->
        ops
    end
  end

  def add_op(p, type, name), do: Process.put(:pl_ops, put_op(ops(), name, p, type))

  defp put_op(acc, name, p, type) do
    kind =
      cond do
        type in [:xfx, :xfy, :yfx] -> :infix
        type in [:fy, :fx] -> :prefix
        true -> :postfix
      end

    entry = Map.get(acc, name, %{})
    entry = if p == 0, do: Map.delete(entry, kind), else: Map.put(entry, kind, {p, type})
    Map.put(acc, name, entry)
  end

  def op_info(name, kind), do: ops() |> Map.get(name, %{}) |> Map.get(kind)

  # --- public API ----------------------------------------------------------------

  @doc "Parse every clause in `text`. Returns a list of {:ok, term, varnames} | {:error, msg}."
  def read_all(text) do
    toks =
      try do
        Lexer.tokenize(text)
      catch
        {:syntax_error, msg} -> {:error, msg}
      end

    case toks do
      {:error, msg} -> [{:error, msg}]
      toks -> read_loop(toks, [])
    end
  end

  defp read_loop([], acc), do: Enum.reverse(acc)

  defp read_loop(toks, acc) do
    case read_clause(toks) do
      {:ok, t, names, rest} -> read_loop(rest, [{:ok, t, names} | acc])
      {:error, msg, rest} -> read_loop(rest, [{:error, msg} | acc])
    end
  end

  @doc "Parse a single clause terminated by '.' (the end token is optional at EOF)."
  def read_term(text) do
    case read_all(text) do
      [{:ok, t, names}] -> {:ok, t, names}
      [{:error, m} | _] -> {:error, m}
      [] -> {:error, "empty"}
      _ -> {:error, "more than one term"}
    end
  end

  defp read_clause(toks) do
    Process.put(:pl_pvars, %{})
    Process.put(:pl_pnames, [])

    try do
      {t, _p, rest} = parse(toks, 1200)

      case rest do
        [{:end, _, _} | rest2] -> {:ok, t, Enum.reverse(Process.get(:pl_pnames)), rest2}
        [] -> {:ok, t, Enum.reverse(Process.get(:pl_pnames)), []}
        [tok | _] -> throw({:syntax_error, "operator expected, got #{show_tok(tok)}"})
      end
    catch
      {:syntax_error, msg} -> {:error, msg, skip_to_end(toks)}
    end
  end

  defp skip_to_end([]), do: []
  defp skip_to_end([{:end, _, _} | r]), do: r
  defp skip_to_end([_ | r]), do: skip_to_end(r)

  defp show_tok({_, v, _}) when is_binary(v), do: v
  defp show_tok({_, v, _}), do: inspect(v)

  # --- core ---------------------------------------------------------------------

  defp parse(toks, max) do
    {left, lp, rest} = primary(toks, max)
    infix(left, lp, max, rest)
  end

  defp var(name) do
    if name == "_" do
      Term.fresh_var()
    else
      vars = Process.get(:pl_pvars)

      case vars do
        %{^name => v} ->
          v

        _ ->
          v = Term.fresh_var()
          Process.put(:pl_pvars, Map.put(vars, name, v))
          Process.put(:pl_pnames, [{name, v} | Process.get(:pl_pnames)])
          v
      end
    end
  end

  defp primary([], _), do: throw({:syntax_error, "unexpected end of clause"})

  defp primary([tok | rest], max) do
    case tok do
      {:int, n, _} -> {n, 0, rest}
      {:float, f, _} -> {f, 0, rest}
      {:var, name, _} -> {var(name), 0, rest}
      {:str, codes, _} -> {string_term(codes), 0, rest}
      {:bq, codes, _} -> {Term.list(codes), 0, rest}
      {:punct, "(", _} ->
        {t, _, rest} = parse(rest, 1200)
        {t, 0, expect(rest, ")")}

      {:punct, "[", _} ->
        case rest do
          [{:punct, "]", _} | rest2] -> {[], 0, rest2}
          _ -> list(rest)
        end

      {:punct, "{", _} ->
        case rest do
          [{:punct, "}", _} | rest2] -> name_term("{}", rest2, max)
          _ ->
            {t, _, rest2} = parse(rest, 1200)
            {{:c, "{}", [t]}, 0, expect(rest2, "}")}
        end

      {:atom, "-", _} ->
        case rest do
          [{:int, n, false} | rest2] -> {-n, 0, rest2}
          [{:float, f, false} | rest2] -> {-f, 0, rest2}
          _ -> name_term("-", rest, max)
        end

      {:atom, name, _} -> name_term(name, rest, max)
      {:qatom, name, _} -> name_term(name, rest, max, true)
      {:punct, p, _} -> throw({:syntax_error, "unexpected #{p}"})
      {:end, _, _} -> throw({:syntax_error, "unexpected end of clause"})
    end
  end

  defp string_term(codes) do
    case Process.get(:pl_flag_double_quotes, "codes") do
      "chars" -> Term.list(Enum.map(codes, &<<&1::utf8>>))
      "atom" -> List.to_string(codes)
      _ -> Term.list(codes)
    end
  end

  defp name_term(name, [{:punct, "(", false} | rest], _max, _quoted) do
    {args, rest} = arglist(rest, [])
    {{:c, name, args}, 0, rest}
  end

  defp name_term(name, rest, max, quoted) do
    pre = if quoted, do: nil, else: op_info(name, :prefix)

    cond do
      pre != nil and term_start?(rest) ->
        {p, type} = pre
        {p, argmax} = if p > max, do: {999, 999}, else: {p, if(type == :fy, do: p, else: p - 1)}
        {arg, _ap, rest2} = parse(rest, argmax)
        {{:c, name, [arg]}, p, rest2}

      true ->
        # an operator used as a plain atom (e.g. `X = (-)`, `maplist(+, ...)`)
        {name, 0, rest}
    end
  end

  defp name_term(name, rest, max), do: name_term(name, rest, max, false)

  defp term_start?([]), do: false

  defp term_start?([tok | rest]) do
    case tok do
      {:end, _, _} -> false
      {:punct, p, _} when p in [")", "]", "}", ",", "|"] -> false
      {:atom, n, _} ->
        infix = op_info(n, :infix)
        prefix = op_info(n, :prefix)

        cond do
          infix != nil and prefix == nil ->
            # `- = x`: treat the prefix op as an atom unless the infix op is
            # actually applied as a function, e.g. `- =(a)` (rare)
            match?([{:punct, "(", false} | _], rest)

          true ->
            true
        end

      _ -> true
    end
  end

  defp arglist(toks, acc) do
    {a, _, rest} = parse(toks, 999)

    case rest do
      [{:punct, ",", _} | rest2] -> arglist(rest2, [a | acc])
      [{:punct, ")", _} | rest2] -> {Enum.reverse([a | acc]), rest2}
      _ -> throw({:syntax_error, "expected , or ) in arguments"})
    end
  end

  defp list(toks), do: list(toks, [])

  defp list(toks, acc) do
    {a, _, rest} = parse(toks, 999)

    case rest do
      [{:punct, ",", _} | rest2] ->
        list(rest2, [a | acc])

      [{:punct, "|", _} | rest2] ->
        {tail, _, rest3} = parse(rest2, 999)
        {Term.list(Enum.reverse([a | acc]), tail), 0, expect(rest3, "]")}

      [{:punct, "]", _} | rest2] ->
        {Term.list(Enum.reverse([a | acc])), 0, rest2}

      _ ->
        throw({:syntax_error, "expected , | or ] in list"})
    end
  end

  defp expect([{:punct, p, _} | rest], p), do: rest
  defp expect(_, p), do: throw({:syntax_error, "expected #{p}"})

  defp infix(left, lp, max, toks) do
    {name, rest} =
      case toks do
        [{:atom, n, _} | r] -> {n, r}
        [{:qatom, n, _} | r] -> {n, r}
        [{:punct, ",", _} | r] -> {",", r}
        [{:punct, "|", _} | r] -> {"|", r}
        _ -> {nil, toks}
      end

    info = name && op_info(name, :infix)

    case info do
      {p, type} when p <= max ->
        la = if type == :yfx, do: p, else: p - 1
        ra = if type == :xfy, do: p, else: p - 1

        if lp <= la and term_start_after_infix?(rest) do
          {right, _, rest2} = parse(rest, ra)
          fname = if name == "|", do: ";", else: name
          infix({:c, fname, [left, right]}, p, max, rest2)
        else
          postfix(left, lp, max, toks)
        end

      _ ->
        postfix(left, lp, max, toks)
    end
  end

  defp term_start_after_infix?([]), do: false
  defp term_start_after_infix?([{:end, _, _} | _]), do: false
  defp term_start_after_infix?([{:punct, p, _} | _]) when p in [")", "]", "}", ",", "|"], do: false
  defp term_start_after_infix?(_), do: true

  defp postfix(left, lp, max, toks) do
    case toks do
      [{:atom, n, _} | rest] ->
        case op_info(n, :postfix) do
          {p, type} when p <= max ->
            la = if type == :yf, do: p, else: p - 1
            if lp <= la, do: infix({:c, n, [left]}, p, max, rest), else: {left, lp, toks}

          _ ->
            {left, lp, toks}
        end

      _ ->
        {left, lp, toks}
    end
  end
end
