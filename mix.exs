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
      {:telemetry, "~> 1.0"},

      # JSON Schema validation/casting for typed structured outputs.
      # Keep consumer lockfiles off EEF-CVE-2026-117680 and EEF-CVE-2026-117678.
      # JSV 0.28 is the first release that accepts the patched idna 8.
      {:jsv, ">= 0.28.0 and < 1.0.0"},
      {:idna, "~> 8.0"},

      # CSV encoding for `Dspy.Evaluate.Result` `save_as_csv` (M1-a, Horst-confirmed dep 2026-09-28).
      {:nimble_csv, "~> 1.2"},

      # LLM provider access (unified client; no provider maintenance in `dspy.ex`)
      {:req_llm, "~> 1.31"},

      # RetryPolicy matches Req.TransportError and Req.HTTPError directly.
      {:req, "~> 0.7"},
      # DiskCache.Identity inspects LLMDB.provider/1 and LLMDB.Model directly.
      {:llm_db, "~> 2026.11"},

      # Security floors: Finch permits older Mint and HPAX versions.
      # Keep these floors until its transitive requirements include the fixes.
      {:mint, ">= 1.11.0 and < 2.0.0"},
      {:hpax, ">= 1.1.0 and < 2.0.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}

      # NOTE: Local inference deps (Bumblebee/Nx/EXLA) are intentionally NOT
      # dependencies of core `:dspy`. See `docs/BUMBLEBEE.md`.
    ]
  end
end
