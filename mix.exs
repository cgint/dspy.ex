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
      # Using main for google_thinking_budget / reasoning_effort fix (PR #418)
      {:req_llm, github: "agentjido/req_llm"},

      # Security floors (SEC-1, 2026-09-28): req/mint/hpax reach :dspy transitively
      # through req_llm/finch. These direct floors pin consumers to advisory-fixed
      # versions so `mix deps` can never resolve a vulnerable version through the
      # wider transitive ranges (req_llm allows req >= 0.5.0).
      #   req  >= 0.6.1: EEF-CVE-2026-49755 (decompression bomb) + EEF-CVE-2026-49756
      #                  (multipart header injection)
      #   mint >= 1.11.0: 10+ advisories incl. HTTP/2 smuggling + request splitting
      #                   + EEF-CVE-2026-91043 (HPACK cookie field memory exhaustion)
      #   hpax >= 1.1.0:  EEF-CVE-2026-58226 (unbounded HPACK integer decoding DoS);
      #                   mint 1.11.0 requires hpax ~> 1.1, so floor moves with it
      # NOTE (req >= 0.6.0): automatic response archive/compressed decoding was
      # removed and auto-decompression is off — both are opt-in (`decoders:`,
      # `compressed: true`). :dspy itself never relies on either.
      {:req, ">= 0.6.1 and < 1.0.0"},
      {:mint, ">= 1.11.0 and < 2.0.0"},
      {:hpax, ">= 1.1.0 and < 2.0.0"}

      # NOTE: Local inference deps (Bumblebee/Nx/EXLA) are intentionally NOT
      # dependencies of core `:dspy`. See `docs/BUMBLEBEE.md`.
    ]
  end
end
