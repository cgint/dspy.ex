defmodule Dspy.Teleprompt.DirectCompileErrorPropagationTest do
  use ExUnit.Case, async: true

  alias Dspy.{Example, Predict, Teleprompt}
  alias Dspy.Evaluate.{InvalidMetricResult, MaxErrorsExceeded}

  defmodule StaticLM do
    @behaviour Dspy.LM
    defstruct [:text]

    @impl true
    def generate(%__MODULE__{text: text}, _request) do
      {:ok, %{choices: [%{message: %{role: "assistant", content: text}}]}}
    end
  end

  for {optimizer, stage, accepted_scores} <- [
        {:mipro_v2, :trial, 0},
        {:gepa, :baseline, 0},
        {:gepa, :candidate, 5}
      ] do
    test "#{optimizer} propagates an exhausted evaluation budget during #{stage}" do
      assert %MaxErrorsExceeded{errors: 1, max_errors: 1} =
               assert_failure(unquote(optimizer), unquote(accepted_scores), MaxErrorsExceeded)
    end

    test "#{optimizer} propagates an invalid metric result during #{stage}" do
      assert %InvalidMetricResult{value: :invalid_score, example_index: 0} =
               assert_failure(unquote(optimizer), unquote(accepted_scores), InvalidMetricResult)
    end
  end

  defp assert_failure(type, accepted_scores, exception) do
    calls = start_supervised!({Agent, fn -> 0 end})

    metric = fn _example, _prediction ->
      attempt = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

      if attempt < accepted_scores do
        1.0
      else
        bad_score(exception)
      end
    end

    optimizer = Teleprompt.new(type, [metric: metric, seed: 42] ++ optimizer_options(type))

    program =
      Predict.new("question -> answer",
        adapter: Dspy.Signature.Adapters.JSONAdapter,
        lm: %StaticLM{text: ~s({"answer":"ok"})}
      )

    trainset = Enum.map(1..5, &Example.new(question: "Question #{&1}", answer: "ok"))

    error =
      Dspy.context([max_errors: 1, cache: false], fn ->
        assert_raise exception, fn -> Teleprompt.compile(optimizer, program, trainset) end
      end)

    assert Agent.get(calls, & &1) == accepted_scores + 1
    error
  end

  defp bad_score(MaxErrorsExceeded), do: raise("metric execution failed")
  defp bad_score(InvalidMetricResult), do: :invalid_score

  defp optimizer_options(:mipro_v2) do
    [
      max_bootstrapped_demos: 0,
      max_labeled_demos: 0,
      num_trials: 1,
      num_threads: 1,
      minibatch_size_per_trial: 1,
      max_instruction_candidates: 1,
      instruction_generation_rounds: 1,
      prompt_model: %StaticLM{text: "Answer the question directly from the given context."}
    ]
  end

  defp optimizer_options(:gepa), do: [candidates: ["Answer the question in a concise sentence."]]
end
