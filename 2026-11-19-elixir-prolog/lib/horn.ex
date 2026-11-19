defmodule Horn do
  @moduledoc """
  Horn - a Prolog interpreter in Elixir.

      Horn.start()
      Horn.consult("app(X, Y) :- append(X, Y, [1,2]).")
      Horn.query("app(X, Y)")
      #=> [%{"X" => "[]", "Y" => "[1,2]"}, %{"X" => "[1]", "Y" => "[2]"}, ...]
  """
  alias Horn.{Engine, Parser, Term, Writer}

  def start, do: Engine.init()

  def consult(text), do: Engine.consult_string(text)

  @doc "All answers to a query as maps of variable name => writeq text. Raises on uncaught exceptions."
  def query(text, limit \\ :infinity) do
    {:ok, goal, names} = Parser.read_term(text <> " .")
    collect(Engine.solve(goal, %{}), names, limit, [])
  end

  defp collect(:fail, _names, _limit, acc), do: Enum.reverse(acc)
  defp collect(_, _names, 0, acc), do: Enum.reverse(acc)

  defp collect({:ok, s, k}, names, limit, acc) do
    ans = Map.new(names, fn {n, v} -> {n, Writer.to_string(v, s, quoted: true)} end)
    limit = if limit == :infinity, do: limit, else: limit - 1
    if limit == 0, do: Enum.reverse([ans | acc]), else: collect(Engine.next(k), names, limit, [ans | acc])
  end

  @doc "Run a goal for its output; returns captured stdout."
  def run_output(text) do
    {_, out} =
      Horn.Builtins.capture(fn ->
        {:ok, goal, _} = Parser.read_term(text <> " .")

        try do
          Engine.once(goal, %{})
        catch
          {:pl_uncaught, b} -> Horn.Builtins.out("uncaught: " <> Writer.to_string(b, %{}, quoted: true))
        end
      end)

    out
  end

  def show(t, s \\ %{}), do: Writer.to_string(Term.resolve(t, s), %{}, quoted: true)
end
