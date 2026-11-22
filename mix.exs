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
      # Keep the revision already tested in mix.lock when consumers resolve dspy.ex.
      {:req_llm, github: "agentjido/req_llm", ref: "66b40425a79d85a284dd99edbe1769d364c42066"},

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
      # REMOVE these three direct deps once req_llm/finch themselves require the
      # fixed versions (lib/ calls none of Req/Mint/HPAX directly).
      {:req, ">= 0.6.1 and < 1.0.0"},
      {:mint, ">= 1.11.0 and < 2.0.0"},
      {:hpax, ">= 1.1.0 and < 2.0.0"},

      # LLMDB 2026.5.2 emits atom and string runtime keys that Zoi 0.20
      # rejects at startup. Keep the pinned ReqLLM floor.
      # Remove after an upstream graph provides its own compatible constraint
      # or fixes the collision, verified by a fresh Extras resolution.
      {:zoi, ">= 0.14.0 and < 0.20.0"}

      # NOTE: Local inference deps (Bumblebee/Nx/EXLA) are intentionally NOT
      # dependencies of core `:dspy`. See `docs/BUMBLEBEE.md`.
    ]
  end
end
