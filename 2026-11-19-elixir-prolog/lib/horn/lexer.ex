defmodule Horn.Lexer do
  @moduledoc """
  Tokenizer for ISO-ish Prolog text.

  Tokens are tuples `{kind, value, layout_before?}` where `layout_before?`
  records whether whitespace preceded the token. The parser needs that to
  tell `foo(a)` (a compound) from `foo (a)` (an operator applied to `(a)`)
  and `-1` (a number) from `- 1` (the term `-(1)`).
  """

  @symbol ~c"+-*/\\^<>=~:.?@#&$"

  def tokenize(text) when is_binary(text), do: lex(String.to_charlist(text), true, [])

  defguardp is_digit(c) when c in ?0..?9
  defguardp is_lower(c) when c in ?a..?z
  defguardp is_upper(c) when c in ?A..?Z or c == ?_
  defguardp is_alnum(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c > 127
  defguardp is_space(c) when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v]

  defp lex([], _lay, acc), do: Enum.reverse(acc)
  defp lex([c | r], _lay, acc) when is_space(c), do: lex(r, true, acc)
  defp lex([?% | r], _lay, acc), do: lex(skip_line(r), true, acc)
  defp lex([?/, ?* | r], _lay, acc), do: lex(skip_block(r), true, acc)

  defp lex([c | _] = cs, lay, acc) when is_digit(c) do
    {tok, rest} = number(cs)
    lex(rest, false, [put_elem(tok, 2, lay) | acc])
  end

  defp lex([c | _] = cs, lay, acc) when is_upper(c) do
    {name, rest} = Enum.split_while(cs, &is_alnum/1)
    lex(rest, false, [{:var, List.to_string(name), lay} | acc])
  end

  defp lex([c | _] = cs, lay, acc) when is_lower(c) or c > 127 do
    {name, rest} = Enum.split_while(cs, &is_alnum/1)
    lex(rest, false, [{:atom, List.to_string(name), lay} | acc])
  end

  defp lex([?' | r], lay, acc) do
    {chars, rest} = quoted(r, ?', [])
    lex(rest, false, [{:qatom, List.to_string(chars), lay} | acc])
  end

  defp lex([?" | r], lay, acc) do
    {chars, rest} = quoted(r, ?", [])
    lex(rest, false, [{:str, chars, lay} | acc])
  end

  defp lex([?` | r], lay, acc) do
    {chars, rest} = quoted(r, ?`, [])
    lex(rest, false, [{:bq, chars, lay} | acc])
  end

  defp lex([c | r], lay, acc) when c in [?(, ?), ?[, ?], ?{, ?}, ?,, ?|] do
    case {c, r} do
      {?|, [?| | r2]} -> lex(r2, false, [{:atom, "||", lay} | acc])
      _ -> lex(r, false, [{:punct, <<c>>, lay} | acc])
    end
  end

  defp lex([c | r], lay, acc) when c in [?!, ?;] do
    lex(r, false, [{:atom, <<c>>, lay} | acc])
  end

  defp lex([?. | r], lay, acc) do
    case r do
      [] -> lex([], true, [{:end, ".", lay} | acc])
      [c | _] when is_space(c) or c == ?% -> lex(r, true, [{:end, ".", lay} | acc])
      _ -> symbol([?. | r], lay, acc)
    end
  end

  defp lex([c | _] = cs, lay, acc) when c in @symbol, do: symbol(cs, lay, acc)
  defp lex([c | _], _lay, _acc), do: throw({:syntax_error, "illegal character #{<<c::utf8>>}"})

  defp symbol(cs, lay, acc) do
    {name, rest} = Enum.split_while(cs, &(&1 in @symbol))
    lex(rest, false, [{:atom, List.to_string(name), lay} | acc])
  end

  defp skip_line([]), do: []
  defp skip_line([?\n | r]), do: r
  defp skip_line([_ | r]), do: skip_line(r)

  defp skip_block([]), do: []
  defp skip_block([?*, ?/ | r]), do: r
  defp skip_block([_ | r]), do: skip_block(r)

  # --- numbers ---------------------------------------------------------------

  defp number([?0, ?' | r]) do
    case r do
      [?', ?' | rest] -> {{:int, ?', nil}, rest}
      [?\\ | _] ->
        {c, rest} = escape(tl(r))
        {{:int, c, nil}, rest}
      [c | rest] -> {{:int, c, nil}, rest}
    end
  end

  defp number([?0, ?x | r]), do: radix(r, 16)
  defp number([?0, ?o | r]), do: radix(r, 8)
  defp number([?0, ?b | r]), do: radix(r, 2)

  defp number(cs) do
    {ds, rest} = Enum.split_while(cs, &(is_digit(&1) or &1 == ?_))
    ds = Enum.reject(ds, &(&1 == ?_))

    case rest do
      [?., d | _] when is_digit(d) ->
        {frac, rest2} = Enum.split_while(tl(rest), &is_digit/1)
        {exp, rest3} = exponent(rest2)
        {{:float, List.to_float(ds ++ [?.] ++ frac ++ exp), nil}, rest3}

      [e | _] when e in [?e, ?E] ->
        case exponent(rest) do
          {[], _} -> {{:int, List.to_integer(ds), nil}, rest}
          {exp, rest3} -> {{:float, List.to_float(ds ++ ~c".0" ++ exp), nil}, rest3}
        end

      _ ->
        {{:int, List.to_integer(ds), nil}, rest}
    end
  end

  defp exponent([e, s, d | _] = cs) when e in [?e, ?E] and s in [?+, ?-] and is_digit(d) do
    {ds, rest} = Enum.split_while(Enum.drop(cs, 2), &is_digit/1)
    {[?e, s | ds], rest}
  end

  defp exponent([e, d | _] = cs) when e in [?e, ?E] and is_digit(d) do
    {ds, rest} = Enum.split_while(tl(cs), &is_digit/1)
    {[?e | ds], rest}
  end

  defp exponent(cs), do: {[], cs}

  defp radix(r, base) do
    {ds, rest} = Enum.split_while(r, &(digit_val(&1) < base))
    {{:int, List.to_integer(ds, base), nil}, rest}
  end

  defp digit_val(c) when c in ?0..?9, do: c - ?0
  defp digit_val(c) when c in ?a..?f, do: c - ?a + 10
  defp digit_val(c) when c in ?A..?F, do: c - ?A + 10
  defp digit_val(_), do: 99

  # --- quoted items ----------------------------------------------------------

  defp quoted([], _q, _acc), do: throw({:syntax_error, "unterminated quoted"})
  defp quoted([q, q | r], q, acc), do: quoted(r, q, [q | acc])
  defp quoted([q | r], q, acc), do: {Enum.reverse(acc), r}
  defp quoted([?\\, ?\n | r], q, acc), do: quoted(r, q, acc)

  defp quoted([?\\ | r], q, acc) do
    {c, rest} = escape(r)
    quoted(rest, q, [c | acc])
  end

  defp quoted([c | r], q, acc), do: quoted(r, q, [c | acc])

  defp escape([?n | r]), do: {?\n, r}
  defp escape([?t | r]), do: {?\t, r}
  defp escape([?r | r]), do: {?\r, r}
  defp escape([?a | r]), do: {7, r}
  defp escape([?b | r]), do: {8, r}
  defp escape([?f | r]), do: {12, r}
  defp escape([?v | r]), do: {11, r}
  defp escape([?0 | r]) when hd(r) not in ?0..?7, do: {0, r}
  defp escape([?e | r]), do: {27, r}
  defp escape([?s | r]), do: {?\s, r}
  defp escape([?x | r]) do
    {ds, rest} = Enum.split_while(r, &(digit_val(&1) < 16))
    {List.to_integer(ds, 16), drop_bs(rest)}
  end
  defp escape([d | _] = r) when d in ?0..?7 do
    {ds, rest} = Enum.split_while(r, &(&1 in ?0..?7))
    {List.to_integer(ds, 8), drop_bs(rest)}
  end
  defp escape([c | r]), do: {c, r}

  defp drop_bs([?\\ | r]), do: r
  defp drop_bs(r), do: r
end
