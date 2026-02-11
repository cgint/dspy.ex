defmodule Dspy.MixProject do
  use Mix.Project

  @version __DIR__
           |> Path.join("VERSION")
           |> File.read!()
           |> String.trim()

  def project do
    [
      app: :dspy,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # Keep the core library lightweight and quiet by default.
      extra_applications: [:logger, :inets, :ssl],
      mod: {Dspy.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},

      # JSON Schema validation/casting for typed structured outputs.
      {:jsv, "~> 0.16"},

      # LLM provider access (unified client; no provider maintenance in `dspy.ex`)
      {:req_llm, "~> 1.3"}

      # NOTE: Local inference deps (Bumblebee/Nx/EXLA) are intentionally NOT
      # dependencies of core `:dspy`. See `docs/BUMBLEBEE.md`.
    ]
  end
end
