defmodule Horn.Arith do
  @moduledoc "Arithmetic evaluation for is/2 and the comparison predicates (SWI-compatible semantics)."
  alias Horn.Term
  import Bitwise

  # SWI evaluates the arguments of an arithmetic function right-to-left and
  # only then looks the function up; the order is visible in which error
  # term is raised (e.g. `X is f(a) + Y` gives instantiation_error).
  def eval(t, s) do
    case Term.deref(t, s) do
      n when is_number(n) -> n
      {:v, _} -> throw({:pl_error, Term.inst_error()})
      a when is_binary(a) -> const(a)
      [] -> type_err("evaluable", [])
      {:c, "[|]", [x, tl]} = l ->
        c = char_value(x, s)
        # "[X]" evaluates to X (a one-element code/char list)
        if Term.deref(tl, s) == [], do: c, else: type_err("[]", Term.resolve(l, s))

      {:c, f, [x]} -> un(f, eval(x, s))
      {:c, f, [x, y]} ->
        b = eval(y, s)
        a = eval(x, s)
        bin(f, a, b)

      {:c, f, args} ->
        args |> Enum.reverse() |> Enum.each(&eval(&1, s))
        type_err("evaluable", Term.pi(f, length(args)))
    end
  end

  defp char_value(x, s) do
    case Term.deref(x, s) do
      {:v, _} -> throw({:pl_error, Term.inst_error()})
      i when is_integer(i) and i >= 0 and i <= 0x10FFFF -> i
      a when is_binary(a) ->
        case String.to_charlist(a) do
          [c] -> c
          _ -> type_err("character", a)
        end

      other -> type_err("character", Term.resolve(other, s))
    end
  end

  defp const("pi"), do: :math.pi()
  defp const("e"), do: :math.exp(1)
  defp const("inf"), do: throw({:pl_error, Term.err({:c, "evaluation_error", ["undefined"]})})
  defp const("epsilon"), do: 2.220446049250313e-16
  defp const("max_tagged_integer"), do: (1 <<< 60) - 1
  defp const("random"), do: :rand.uniform()
  defp const("random_float"), do: :rand.uniform()
  defp const("cputime"), do: :erlang.statistics(:runtime) |> elem(0) |> Kernel./(1000)
  defp const("realtime"), do: System.os_time(:second)
  defp const(a), do: type_err("evaluable", Term.pi(a, 0))

  defp type_err(t, c), do: throw({:pl_error, Term.type_error(t, c)})
  defp eval_err(e), do: throw({:pl_error, Term.err({:c, "evaluation_error", [e]})})

  defp int!(x) when is_integer(x), do: x
  defp int!(x), do: type_err("integer", x)

  defp check(f) when is_float(f) do
    f
  end

  defp check(x), do: x

  defp fl(fun) do
    try do
      check(fun.())
    rescue
      ArithmeticError -> eval_err("undefined")
    end
  end

  defp un("-", x), do: -x
  defp un("+", x), do: x
  defp un("abs", x), do: abs(x)
  defp un("sign", x) when is_integer(x), do: (x > 0 && 1) || (x < 0 && -1) || 0
  defp un("sign", x), do: (x > 0 && 1.0) || (x < 0 && -1.0) || 0.0
  defp un("min", _), do: type_err("evaluable", Term.pi("min", 1))
  defp un("\\", x), do: bnot(int!(x))
  defp un("msb", x), do: int!(x) |> Integer.digits(2) |> length() |> Kernel.-(1)
  defp un("succ", x), do: int!(x) + 1
  defp un("sqrt", x) when x < 0, do: eval_err("undefined")
  defp un("sqrt", x), do: :math.sqrt(x)
  defp un("sin", x), do: :math.sin(x)
  defp un("cos", x), do: :math.cos(x)
  defp un("tan", x), do: :math.tan(x)
  defp un("asin", x), do: fl(fn -> :math.asin(x) end)
  defp un("acos", x), do: fl(fn -> :math.acos(x) end)
  defp un("atan", x), do: :math.atan(x)
  defp un("exp", x), do: fl(fn -> :math.exp(x) end)
  defp un("log", x) when x <= 0, do: if(x == 0, do: eval_err("undefined"), else: eval_err("undefined"))
  defp un("log", x), do: :math.log(x)
  defp un("log2", x) when x <= 0, do: eval_err("undefined")
  defp un("log2", x), do: :math.log2(x)
  defp un("sinh", x), do: :math.sinh(x)
  defp un("cosh", x), do: :math.cosh(x)
  defp un("tanh", x), do: :math.tanh(x)
  defp un("float", x), do: x * 1.0
  defp un("integer", x) when is_integer(x), do: x
  defp un("integer", x), do: round(x)
  defp un("float_integer_part", x), do: trunc(x) * 1.0
  defp un("float_fractional_part", x), do: x - trunc(x)
  defp un("truncate", x), do: trunc(x)
  defp un("round", x), do: round(x)
  defp un("ceiling", x) when is_integer(x), do: x
  defp un("ceiling", x), do: x |> Float.ceil() |> trunc()
  defp un("floor", x) when is_integer(x), do: x
  defp un("floor", x), do: x |> Float.floor() |> trunc()
  defp un("random", x), do: :rand.uniform(int!(x)) - 1
  defp un("random_float", _), do: :rand.uniform()
  defp un(f, _), do: type_err("evaluable", Term.pi(f, 1))

  defp bin("+", x, y), do: x + y
  defp bin("-", x, y), do: x - y
  defp bin("*", x, y), do: x * y

  defp bin("/", x, y) when is_integer(x) and is_integer(y) do
    cond do
      y == 0 -> eval_err("zero_divisor")
      rem(x, y) == 0 -> div(x, y)
      true -> x / y
    end
  end

  defp bin("/", x, y) do
    if y == 0, do: eval_err("zero_divisor"), else: x / y
  end

  defp bin("//", x, y) do
    x = int!(x)
    y = int!(y)
    if y == 0, do: eval_err("zero_divisor"), else: div(x, y)
  end

  defp bin("mod", x, y) do
    x = int!(x)
    y = int!(y)
    if y == 0, do: eval_err("zero_divisor"), else: Integer.mod(x, y)
  end

  defp bin("rem", x, y) do
    x = int!(x)
    y = int!(y)
    if y == 0, do: eval_err("zero_divisor"), else: rem(x, y)
  end

  defp bin("div", x, y) do
    x = int!(x)
    y = int!(y)
    if y == 0, do: eval_err("zero_divisor"), else: Integer.floor_div(x, y)
  end

  defp bin("min", x, y), do: if(y < x, do: y, else: x)
  defp bin("max", x, y), do: if(y > x, do: y, else: x)

  defp bin("**", x, y) when is_integer(x) and is_integer(y), do: bin("^", x, y)

  defp bin("**", x, y), do: fl(fn -> :math.pow(x, y) end)

  defp bin("^", x, y) when is_integer(x) and is_integer(y) do
    cond do
      y >= 0 -> Integer.pow(x, y)
      x == 1 -> 1
      x == -1 -> if rem(y, 2) == 0, do: 1, else: -1
      x == 0 -> eval_err("zero_divisor")
      true -> :math.pow(x, y)
    end
  end

  defp bin("^", x, y), do: fl(fn -> :math.pow(x, y) end)
  defp bin(">>", x, y), do: int!(x) >>> int!(y)
  defp bin("<<", x, y), do: int!(x) <<< int!(y)
  defp bin("/\\", x, y), do: band(int!(x), int!(y))
  defp bin("\\/", x, y), do: bor(int!(x), int!(y))
  defp bin("xor", x, y), do: bxor(int!(x), int!(y))
  defp bin("atan2", x, y), do: :math.atan2(x, y)
  defp bin("atan", x, y), do: :math.atan2(x, y)
  defp bin("copysign", x, y), do: if((y < 0) != (x < 0), do: -x, else: x)
  defp bin("gcd", x, y), do: Integer.gcd(int!(x), int!(y))
  defp bin("log", b, x), do: un("log", x) / un("log", b)
  defp bin("truncate", _, _), do: type_err("evaluable", Term.pi("truncate", 2))
  defp bin(f, _, _), do: type_err("evaluable", Term.pi(f, 2))

  def compare(op, a, b, s) do
    x = eval(a, s)
    y = eval(b, s)

    case op do
      "=:=" -> x == y
      "=\\=" -> x != y
      "<" -> x < y
      ">" -> x > y
      "=<" -> x <= y
      ">=" -> x >= y
    end
  end
end
