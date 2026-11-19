defmodule Horn.CLI do
  @moduledoc """
  Command line entry point.

      horn                       interactive toplevel
      horn file.pl ...           consult files, then toplevel (or halt via initialization(main, main))
      horn file.pl -g 'goal'     consult, run goal once, exit
      horn --fuzz N [seed]       differential fuzzing against swipl (see fuzz/)
  """
  alias Horn.{Engine, Parser, Writer}

  def main(args) do
    Engine.init()

    try do
      dispatch(args, [], nil)
    catch
      {:pl_halt, code} -> System.halt(code)
    end
  end

  defp dispatch(["--fuzz" | rest], _, _) do
    {n, seed, jobs} =
      case rest do
        [n, seed, jobs | _] -> {String.to_integer(n), String.to_integer(seed), String.to_integer(jobs)}
        [n, seed] -> {String.to_integer(n), String.to_integer(seed), System.schedulers_online()}
        [n] -> {String.to_integer(n), 1, System.schedulers_online()}
        [] -> {1000, 1, System.schedulers_online()}
      end

    Horn.Fuzz.run(n, seed, jobs)
  end

  defp dispatch(["-g", goal | rest], files, _), do: dispatch(rest, files, goal)
  defp dispatch(["-q" | rest], files, g), do: dispatch(rest, files, g)
  defp dispatch([f | rest], files, g), do: dispatch(rest, [f | files], g)

  defp dispatch([], files, goal) do
    for f <- Enum.reverse(files) do
      case File.read(f) do
        {:ok, src} -> Engine.consult_string(src)
        {:error, why} -> IO.puts(:stderr, "cannot read #{f}: #{why}")
      end
    end

    case goal do
      nil -> repl()
      g -> System.halt(run_goal(g))
    end
  end

  defp run_goal(text) do
    case Parser.read_term(text <> " .") do
      {:ok, g, _} ->
        try do
          case Engine.once(g, %{}) do
            {:ok, _} -> 0
            :fail -> IO.puts(:stderr, "Warning: goal failed"); 1
          end
        catch
          {:pl_uncaught, b} ->
            IO.puts(:stderr, "uncaught exception: " <> Writer.to_string(b, %{}, quoted: true))
            2
        end

      {:error, m} ->
        IO.puts(:stderr, "syntax error: #{m}")
        2
    end
  end

  # --- toplevel ---------------------------------------------------------------------

  defp repl do
    IO.puts("Horn Prolog (Elixir #{System.version()}) - type halt. to quit")
    loop()
  end

  defp loop do
    case read_query("?- ", "") do
      :eof -> IO.puts("")
      text ->
        answer(text)
        loop()
    end
  end

  defp read_query(prompt, acc) do
    case IO.gets(prompt) do
      :eof -> :eof
      {:error, _} -> :eof
      line ->
        acc = acc <> line
        t = String.trim(acc)

        cond do
          t == "" -> read_query(prompt, "")
          String.ends_with?(t, ".") -> t
          true -> read_query("|    ", acc)
        end
    end
  end

  defp answer(text) do
    case Parser.read_term(text) do
      {:error, m} ->
        IO.puts("Syntax error: #{m}")

      {:ok, goal, names} ->
        try do
          show(Engine.solve(goal, %{}), names)
        catch
          {:pl_uncaught, b} -> IO.puts("ERROR: " <> describe(b) <> "\n")
        end
    end
  end

  defp describe({:c, "error", [{:c, "existence_error", ["procedure", pi]}, _]}),
    do: "Unknown procedure: " <> Writer.to_string(pi, %{}, quoted: true)

  defp describe({:c, "error", [formal, _]}), do: Writer.to_string(formal, %{}, quoted: true)
  defp describe(ball), do: "Unhandled exception: " <> Writer.to_string(ball, %{}, quoted: true)

  defp show(:fail, _), do: IO.puts("false.\n")

  defp show({:ok, s, {cps, _} = k}, names) do
    visible = Enum.reject(names, fn {n, _} -> String.starts_with?(n, "_") end)

    text =
      case visible do
        [] -> "true"
        _ -> Enum.map_join(visible, ",\n", fn {n, v} -> "#{n} = " <> Writer.to_string(v, s, quoted: true) end)
      end

    if cps == [] do
      IO.puts(text <> ".\n")
    else
      IO.write(text <> " ")

      case IO.gets("") do
        line when is_binary(line) ->
          if String.trim(line) == ";" do
            IO.puts(";")
            show(Engine.next(k), names)
          else
            IO.puts(".\n")
          end

        _ ->
          IO.puts(".\n")
      end
    end
  end
end
