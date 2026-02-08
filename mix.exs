defmodule Dspy.MixProject do
  use Mix.Project

  def project do
    [
      app: :dspy,
      version: "0.1.1",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :os_mon, :tools],
      mod: {Dspy.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},

      # Temporary: required for existing in-tree web + GenStage modules to compile.
      # We may later relocate these modules to keep `dspy.ex` library-only.
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:gen_stage, "~> 1.2"},
      {:httpoison, "~> 2.2"},

      # LLM provider access (unified client; no provider maintenance in `dspy.ex`)
      {:req_llm, "~> 1.3"}
    ]
  end
end
