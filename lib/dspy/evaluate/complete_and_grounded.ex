defmodule Dspy.Evaluate.CompleteAndGrounded do
  @moduledoc """
  LM-judged completeness + groundedness metric (upstream
  `dspy.evaluate.auto_evaluation.CompleteAndGrounded`, DSPy 3.4.0).

  Wraps two `Dspy.ChainOfThought` judges: one on `AnswerCompleteness` (called
  **first**, upstream order `auto_evaluation.py:113-116`) and one on
  `AnswerGroundedness` (called **second**, `auto_evaluation.py:117-119`). The
  score is `f1(groundedness, completeness)` — mirroring upstream's argument
  order (`f1_score` is symmetric, so order does not change the value).

  ## Usage

      judge = Dspy.Evaluate.CompleteAndGrounded.new()
      metric_fn = Dspy.Evaluate.CompleteAndGrounded.metric(judge)
      Dspy.Evaluate.evaluate(program, devset, metric_fn)

  The metric function returns a **float** (the F1, in `[0.0, 1.0]`), never a
  `%Dspy.Prediction{}` (D1). It **raises** `Dspy.Evaluate.JudgeError` on judge
  parse failure — it does NOT catch and return `0.0` (H5 anti-pattern).
  """

  use Dspy.Module

  alias Dspy.Evaluate.AutoEvaluation
  alias Dspy.Evaluate.JudgeError
  alias Dspy.Evaluate.JudgeScore

  defstruct [:threshold, :completeness_module, :groundedness_module]

  @type t :: %__MODULE__{
          threshold: float(),
          completeness_module: Dspy.ChainOfThought.t(),
          groundedness_module: Dspy.ChainOfThought.t()
        }

  @doc """
  Create a new CompleteAndGrounded judge.

  Options:
  - `:threshold` (default `0.66`) — the F1 threshold for `threshold_metric/1`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.66)

    %__MODULE__{
      threshold: threshold,
      completeness_module: Dspy.ChainOfThought.new(AutoEvaluation.AnswerCompleteness.signature()),
      groundedness_module: Dspy.ChainOfThought.new(AutoEvaluation.AnswerGroundedness.signature())
    }
  end

  @impl true
  def forward(%__MODULE__{} = judge, %{example: example, prediction: prediction}) do
    question = require_field(example, :question, "example[:question]")
    ground_truth = require_field(example, :response, "example[:response]")
    system_response = require_field(prediction, :response, "prediction[:response]")
    retrieved_context = require_field(prediction, :context, "prediction[:context]")

    completeness =
      Dspy.call(judge.completeness_module, %{
        question: question,
        ground_truth: ground_truth,
        system_response: system_response
      })
      |> judge_result("completeness")

    groundedness =
      Dspy.call(judge.groundedness_module, %{
        question: question,
        retrieved_context: retrieved_context,
        system_response: system_response
      })
      |> judge_result("groundedness")

    completeness_value =
      case Map.get(completeness.attrs, :completeness) do
        nil ->
          raw_answer = raw_text(completeness)

          raise JudgeError,
            reason: {:missing_required_outputs, [:completeness]},
            raw_answer: raw_answer

        value ->
          value
      end

    groundedness_value =
      case Map.get(groundedness.attrs, :groundedness) do
        nil ->
          raw_answer = raw_text(groundedness)

          raise JudgeError,
            reason: {:missing_required_outputs, [:groundedness]},
            raw_answer: raw_answer

        value ->
          value
      end

    # Upstream order: f1_score(groundedness, completeness)
    score = JudgeScore.f1(groundedness_value, completeness_value)
    {:ok, %{score: score}}
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
    completeness_params =
      judge.completeness_module
      |> Dspy.Module.parameters()
      |> Enum.map(fn param -> %{param | name: "completeness_module.#{param.name}"} end)

    groundedness_params =
      judge.groundedness_module
      |> Dspy.Module.parameters()
      |> Enum.map(fn param -> %{param | name: "groundedness_module.#{param.name}"} end)

    completeness_params ++ groundedness_params
  end

  @impl true
  def update_parameters(%__MODULE__{} = judge, parameters) do
    completeness_params =
      parameters
      |> Enum.filter(fn param -> String.starts_with?(param.name, "completeness_module.") end)
      |> Enum.map(fn param ->
        %{param | name: String.replace_prefix(param.name, "completeness_module.", "")}
      end)

    groundedness_params =
      parameters
      |> Enum.filter(fn param -> String.starts_with?(param.name, "groundedness_module.") end)
      |> Enum.map(fn param ->
        %{param | name: String.replace_prefix(param.name, "groundedness_module.", "")}
      end)

    %__MODULE__{
      judge
      | completeness_module:
          Dspy.Module.update_parameters(judge.completeness_module, completeness_params),
        groundedness_module:
          Dspy.Module.update_parameters(judge.groundedness_module, groundedness_params)
    }
  end

  # Access the field via the Access protocol (works for both Example and
  # Prediction, and handles string-keyed attrs via their Access impls).
  defp require_field(container, field, label) do
    case Access.fetch(container, field) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "missing #{label}"
    end
  end

  # Wrap a Dspy.call result; raise JudgeError on adapter error (never swallow).
  defp judge_result({:ok, result}, _label), do: result

  defp judge_result({:error, reason}, _label) do
    raise JudgeError, reason: reason, raw_answer: JudgeScore.raw_output(reason)
  end

  # Extract the raw text from a Prediction's completions (if any).
  defp raw_text(%Dspy.Prediction{completions: [%{text: text} | _]}) when is_binary(text), do: text
  defp raw_text(%Dspy.Prediction{}), do: nil
end
