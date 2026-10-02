defmodule Dspy.Evaluate.JudgeScore do
  @moduledoc false
  # Shared scoring rules for the LM judges (`Dspy.Evaluate.SemanticF1`,
  # `Dspy.Evaluate.CompleteAndGrounded`). One copy, called by both judges.

  @doc """
  Upstream `f1_score` (`dspy/evaluate/auto_evaluation.py:36-39`): clamp each
  input to `[0.0, 1.0]`; `0.0` when their sum is 0; else `2ab/(a+b)`.
  Always returns a float.
  """
  @spec f1(number(), number()) :: float()
  def f1(a, b) do
    x = clamp01(a)
    y = clamp01(b)

    if x + y == 0.0 do
      0.0
    else
      2.0 * x * y / (x + y)
    end
  end

  defp clamp01(value) when is_number(value), do: max(0.0, min(1.0, value * 1.0))

  @doc """
  The raw judge text carried in an adapter error reason, or `nil`.

  The adapter pipeline returns terminal parse failures as
  `{:output_parse_failed, inner_reason, %{raw_output: text}}`
  (`lib/dspy/signature/adapter/pipeline.ex`). Any other reason shape
  (e.g. an LM transport error) carries no raw text.
  """
  @spec raw_output(term()) :: String.t() | nil
  def raw_output({:output_parse_failed, _inner, %{raw_output: text}}) when is_binary(text),
    do: text

  def raw_output(_reason), do: nil
end
