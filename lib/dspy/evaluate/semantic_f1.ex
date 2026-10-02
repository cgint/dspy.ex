defmodule Dspy.Evaluate.SemanticF1 do
  @moduledoc """
  LM-judged semantic F1 metric (upstream `dspy.evaluate.auto_evaluation.SemanticF1`,
  DSPy 3.4.0).

  Wraps a `Dspy.ChainOfThought` on either `SemanticRecallPrecision` (default) or
  `DecompositionalSemanticRecallPrecision` (when `decompositional: true`).

  ## Usage

      judge = Dspy.Evaluate.SemanticF1.new()
      metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)
      Dspy.Evaluate.evaluate(program, devset, metric_fn)

  The metric function returns a **float** (the F1, in `[0.0, 1.0]`), never a
  `%Dspy.Prediction{}` (D1). It **raises** `Dspy.Evaluate.JudgeError` on judge
  parse failure — it does NOT catch and return `0.0` (H5 anti-pattern).
  """

  use Dspy.Module

  alias Dspy.Evaluate.AutoEvaluation
  alias Dspy.Evaluate.JudgeError
  alias Dspy.Evaluate.JudgeScore

  defstruct [:threshold, :decompositional, :module]

  @type t :: %__MODULE__{
          threshold: float(),
          decompositional: boolean(),
          module: Dspy.ChainOfThought.t()
        }

  @doc """
  Create a new SemanticF1 judge.

  Options:
  - `:threshold` (default `0.66`) — the F1 threshold for `threshold_metric/1`.
  - `:decompositional` (default `false`) — use the decompositional signature.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.66)
    decompositional = Keyword.get(opts, :decompositional, false)

    signature =
      if decompositional do
        AutoEvaluation.DecompositionalSemanticRecallPrecision
      else
        AutoEvaluation.SemanticRecallPrecision
      end

    judge_module = Dspy.ChainOfThought.new(signature.signature())

    %__MODULE__{
      threshold: threshold,
      decompositional: decompositional,
      module: judge_module
    }
  end

  @impl true
  def forward(%__MODULE__{} = judge, %{example: example, prediction: prediction}) do
    question = require_field(example, :question, "example[:question]")
    ground_truth = require_field(example, :response, "example[:response]")
    system_response = require_field(prediction, :response, "prediction[:response]")

    case Dspy.call(judge.module, %{
           question: question,
           ground_truth: ground_truth,
           system_response: system_response
         }) do
      {:ok, prediction_result} ->
        precision = Map.get(prediction_result.attrs, :precision)
        recall = Map.get(prediction_result.attrs, :recall)

        if precision == nil or recall == nil do
          missing =
            Enum.reject(
              [{:precision, precision}, {:recall, recall}],
              fn {_, v} -> v != nil end
            )
            |> Keyword.keys()

          raw_answer = raw_text(prediction_result)
          raise JudgeError, reason: {:missing_required_outputs, missing}, raw_answer: raw_answer
        end

        score = JudgeScore.f1(precision, recall)
        {:ok, %{score: score}}

      {:error, reason} ->
        raise JudgeError, reason: reason, raw_answer: JudgeScore.raw_output(reason)
    end
  end

  @doc """
  Return a metric function for `Dspy.Evaluate.evaluate/4`.

  The returned function takes `(example, prediction)` and returns the F1
  score as a **float** (never a `%Dspy.Prediction{}`).

  Raises `Dspy.Evaluate.JudgeError` on judge parse failure.
  """
  @spec metric(t()) :: (Dspy.Example.t(), Dspy.Prediction.t() -> float())
  def metric(judge) do
    fn example, prediction ->
      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      score
    end
  end

  @doc """
  Return a threshold metric function for `Dspy.Evaluate.evaluate/4`.

  The returned function takes `(example, prediction)` and returns `true`
  when the F1 is at least the judge's threshold, `false` otherwise.

  Raises `Dspy.Evaluate.JudgeError` on judge parse failure.
  """
  @spec threshold_metric(t()) :: (Dspy.Example.t(), Dspy.Prediction.t() -> boolean())
  def threshold_metric(judge) do
    fn example, prediction ->
      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      score >= judge.threshold
    end
  end

  @impl true
  def parameters(%__MODULE__{} = judge) do
    judge.module
    |> Dspy.Module.parameters()
    |> Enum.map(fn param ->
      %{param | name: "module.#{param.name}"}
    end)
  end

  @impl true
  def update_parameters(%__MODULE__{} = judge, parameters) do
    inner_params =
      Enum.map(parameters, fn param ->
        %{param | name: strip_prefix(param.name)}
      end)

    %__MODULE__{judge | module: Dspy.Module.update_parameters(judge.module, inner_params)}
  end

  # Access the field via the Access protocol (works for both Example and
  # Prediction, and handles string-keyed attrs via their Access impls).
  defp require_field(container, field, label) do
    value = Access.fetch(container, field)

    case value do
      {:ok, v} -> v
      :error -> raise ArgumentError, "missing #{label}"
    end
  end

  # Extract the raw text from a Prediction's completions (if any).
  defp raw_text(%Dspy.Prediction{completions: [%{text: text} | _]}) when is_binary(text), do: text
  defp raw_text(%Dspy.Prediction{}), do: nil

  defp strip_prefix(name) do
    case String.split(name, ".", parts: 2) do
      ["module", rest] -> rest
      _ -> name
    end
  end
end
