defmodule Selftest.MixProject do
  use Mix.Project

  def project do
    [
      app: :selftest,
      version: "0.0.1",
      elixir: "~> 1.18",
      start_permanent: false
    ]
  end

  def application, do: []
end
