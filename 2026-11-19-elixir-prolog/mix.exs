defmodule Horn.MixProject do
  use Mix.Project

  def project do
    [
      app: :horn,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: false,
      escript: [main_module: Horn.CLI, name: "horn"],
      deps: []
    ]
  end

  def application, do: [extra_applications: []]
end
