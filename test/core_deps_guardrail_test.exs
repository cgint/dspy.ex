defmodule Dspy.CoreDepsGuardrailTest do
  use ExUnit.Case, async: false

  @required_runtime_deps [:jason, :req_llm]
  @forbidden_heavy_runtime_deps [
    :phoenix,
    :phoenix_live_view,
    :phoenix_html,
    :phoenix_pubsub,
    :plug_cowboy,
    :gen_stage,
    :httpoison
  ]

  test "core :dspy keeps runtime deps minimal (guardrail)" do
    runtime_deps =
      Mix.Project.config()
      |> Keyword.fetch!(:deps)
      |> Enum.filter(&runtime_dep?/1)
      |> Enum.map(&dep_name/1)
      |> Enum.sort()

    # We enforce "lightweight + no heavy deps" rather than freezing the exact set forever.
    # (Dev/test-only tooling deps are allowed and filtered out above.)
    assert Enum.empty?(@required_runtime_deps -- runtime_deps)

    assert Enum.empty?(Enum.filter(runtime_deps, &(&1 in @forbidden_heavy_runtime_deps)))
  end

  defp dep_name({name, _req}), do: name
  defp dep_name({name, _req, _opts}), do: name

  defp runtime_dep?({_name, _req}), do: true

  defp runtime_dep?({_name, _req, opts}) when is_list(opts) do
    only = Keyword.get(opts, :only)

    runtime? = Keyword.get(opts, :runtime, true) == true

    only_dev_or_test? =
      case only do
        nil -> false
        :dev -> true
        :test -> true
        envs when is_list(envs) -> Enum.any?(envs, &(&1 in [:dev, :test]))
        _ -> false
      end

    runtime? and not only_dev_or_test?
  end
end
