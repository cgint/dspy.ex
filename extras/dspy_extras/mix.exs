defmodule DspyExtras.MixProject do
  use Mix.Project

  def project do
    [
      app: :dspy_extras,
      version: "0.0.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(_env) do
    # Compile the optional UI/coordination modules in `lib/` and also compile
    # quarantined/experimental modules that were moved out of core `:dspy`.
    ["lib", "unsafe/quarantine/lib"]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:dspy, path: "../.."},

      # Optional services dependencies
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:plug_cowboy, "~> 2.7"},
      {:gen_stage, "~> 1.2"},
      {:httpoison, "~> 2.2"}
    ]
  end
end
