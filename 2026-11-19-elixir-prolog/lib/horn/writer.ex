defmodule Horn.Writer do
  @moduledoc "write/1, writeq/1, print/1 and write_canonical/1 with operator-aware layout."
  alias Horn.{Parser, Term}

  @symbol ~c"+-*/\\^<>=~:.?@#&$"

  def to_string(t, s, opts \\ []) do
    q = Keyword.get(opts, :quoted, false)
    o = %{q: q, ops: not Keyword.get(opts, :ignore_ops, false), nv: Keyword.get(opts, :numbervars, true)}
    t |> w(s, 1200, o) |> IO.iodata_to_binary()
  end

  defp w(t, s, prec, o) do
    case Term.deref(t, s) do
      {:v, n} -> ["_G", Integer.to_string(n)]
      [] -> "[]"
      n when is_integer(n) -> Integer.to_string(n)
      f when is_float(f) -> float(f)
      a when is_binary(a) -> atom(a, o, prec)
      {:c, "[|]", [h, tl]} -> ["[", w(h, s, 999, o), tail(tl, s, o), "]"]
      {:c, "{}", [x]} when o.ops -> ["{", w(x, s, 1200, o), "}"]
      {:c, "$VAR", [n]} = c ->
        case Term.deref(n, s) do
          i when is_integer(i) and o.nv -> var_name(i)
          _ -> compound(c, s, prec, o)
        end

      c ->
        compound(c, s, prec, o)
    end
  end

  def var_name(i) do
    letter = <<?A + rem(i, 26)>>
    if i >= 26, do: letter <> Integer.to_string(div(i, 26)), else: letter
  end

  # SWI-Prolog style: shortest round-trip digits, fixed notation for
  # 1e-4 <= |f| < 1e15, otherwise d.ddde[+-]x; always at least one decimal.
  def float(f) when f == 0, do: if(<<f::float>> == <<-0.0::float>>, do: "-0.0", else: "0.0")

  def float(f) do
    sign = if f < 0, do: "-", else: ""
    str = :erlang.float_to_binary(abs(f), [:short])

    {mant, k} =
      case String.split(str, "e") do
        [m, e] -> {m, String.to_integer(e)}
        [m] -> {m, 0}
      end

    {a, b} =
      case String.split(mant, ".") do
        [a, b] -> {a, b}
        [a] -> {a, ""}
      end

    d = String.trim_leading(a <> b, "0")
    sci = String.length(d) - 1 + k - String.length(b)
    d = case String.trim_trailing(d, "0") do
      "" -> "0"
      x -> x
    end

    body =
      cond do
        sci >= -4 and sci < 15 and sci >= 0 ->
          ip = String.pad_trailing(String.slice(d, 0, sci + 1), sci + 1, "0")
          fp = String.slice(d, (sci + 1)..-1//1)
          ip <> "." <> if(fp == "", do: "0", else: fp)

        sci >= -4 and sci < 0 ->
          "0." <> String.duplicate("0", -sci - 1) <> d

        true ->
          {d1, rest} = String.split_at(d, 1)
          d1 <> "." <> if(rest == "", do: "0", else: rest) <> "e" <> if(sci >= 0, do: "+", else: "-") <> Integer.to_string(abs(sci))
      end

    sign <> body
  end

  defp tail(t, s, o) do
    case Term.deref(t, s) do
      [] -> []
      {:c, "[|]", [h, tl]} -> [",", w(h, s, 999, o), tail(tl, s, o)]
      x -> ["|", w(x, s, 999, o)]
    end
  end

  defp compound({:c, f, args} = c, s, prec, o) do
    case {o.ops, args} do
      {true, [l, r]} ->
        case Parser.op_info(f, :infix) do
          {p, type} -> infix(f, p, type, l, r, s, prec, o)
          nil -> canonical(c, s, o)
        end

      {true, [x]} ->
        case Parser.op_info(f, :prefix) do
          {p, type} when f not in ["-", "+"] or not is_number(x) -> prefix(f, p, type, x, s, prec, o)
          {_, _} -> [name(f, o), "(", w(x, s, 999, o), ")"]
          nil ->
            case Parser.op_info(f, :postfix) do
              {p, _} -> wrap(p > prec, [w(x, s, p - 1, o), name(f, o)])
              nil -> canonical(c, s, o)
            end
        end

      _ ->
        canonical(c, s, o)
    end
  end

  defp canonical({:c, f, args}, s, o) do
    [name(f, o), "(", Enum.intersperse(Enum.map(args, &w(&1, s, 999, o)), ","), ")"]
  end

  defp infix(f, p, type, l, r, s, prec, o) do
    lp = if type == :yfx, do: p, else: p - 1
    rp = if type == :xfy, do: p, else: p - 1
    ls = IO.iodata_to_binary(w(l, s, lp, o))
    rs = IO.iodata_to_binary(w(r, s, rp, o))
    fs = IO.iodata_to_binary(name(f, o))

    body =
      cond do
        f == "," -> [ls, ",", rs]
        alpha?(f) -> [ls, " ", fs, " ", rs]
        f in ["->", ":-", "-->", "*->"] -> [ls, fs, rs]
        true ->
          lsp = if glue?(last(ls), first(fs)), do: " ", else: ""
          rsp = if glue?(last(fs), first(rs)), do: " ", else: ""
          [ls, lsp, fs, rsp, rs]
      end

    wrap(p > prec, body)
  end

  defp prefix(f, p, type, x, s, prec, o) do
    ap = if type == :fy, do: p, else: p - 1
    xs = IO.iodata_to_binary(w(x, s, ap, o))
    fs = IO.iodata_to_binary(name(f, o))

    sep =
      cond do
        alpha?(f) -> " "
        glue?(last(fs), first(xs)) -> " "
        is_binary(Term.deref(x, s)) and Parser.ops() |> Map.has_key?(Term.deref(x, s)) -> " "
        true -> ""
      end

    wrap(p > prec, [fs, sep, xs])
  end

  defp wrap(true, io), do: ["(", io, ")"]
  defp wrap(false, io), do: io

  defp first(<<c::utf8, _::binary>>), do: c
  defp first(_), do: nil
  defp last(""), do: nil
  defp last(b), do: :binary.last(b)

  defp glue?(nil, _), do: false
  defp glue?(_, nil), do: false
  defp glue?(a, b), do: (a in @symbol and b in @symbol) or (alnum?(a) and alnum?(b))

  defp alnum?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  defp alpha?(<<c, _::binary>>) when c in ?a..?z, do: true
  defp alpha?(_), do: false

  defp name(a, o), do: if(o.q, do: quote_atom(a), else: a)

  defp atom(a, o, prec) do
    text = if o.q, do: quote_atom(a), else: a

    if prec < 1200 and o.ops and Parser.ops() |> Map.get(a, %{}) |> Enum.any?(fn {_, {p, _}} -> p > prec end) and
         a not in ["{}", "!", ";", ","] and prec < 999 do
      ["(", text, ")"]
    else
      text
    end
  end

  def quote_atom(a) do
    if needs_quotes?(a) do
      ["'", escape(a), "'"]
    else
      a
    end
  end

  defp needs_quotes?(a) when a in ["!", ";", "{}", "|"], do: a == "|"
  defp needs_quotes?(""), do: true

  defp needs_quotes?(<<c, rest::binary>>) when c in ?a..?z do
    not (rest |> String.to_charlist() |> Enum.all?(&(alnum?(&1) or &1 > 127)))
  end

  defp needs_quotes?(a) do
    cs = String.to_charlist(a)
    not Enum.all?(cs, &(&1 in @symbol))
  end

  defp escape(a) do
    a
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
  end
end
