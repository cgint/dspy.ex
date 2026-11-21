# Run: mix run examples/offline/evaluation_callbacks_offline.exs

defmodule EvaluationCallbacksOffline do
  defmodule QA do
    use Dspy.Signature

    input_field(:question, :string, "Question")
    output_field(:answer, :string, "Answer")
  end

  defmodule ScriptedLM do
    @behaviour Dspy.LM
    defstruct [:outcomes]

    @impl true
    def generate(%__MODULE__{outcomes: outcomes}, %{messages: [%{content: prompt}]}) do
      [outcome] =
        for {question, outcome} <- outcomes, String.contains?(prompt, question), do: outcome

      outcome
    end
  end

  defmodule Recorder do
    @behaviour Dspy.Evaluate.Callback
    @behaviour Dspy.Module.Callback
    @behaviour Dspy.LM.Callback

    @impl Dspy.Evaluate.Callback
    def on_evaluate_start(meta, payload, events),
      do: record(events, :evaluate_start, meta, payload)

    @impl Dspy.Evaluate.Callback
    def on_evaluate_end(meta, payload, events), do: record(events, :evaluate_end, meta, payload)

    @impl Dspy.Module.Callback
    def on_module_start(meta, payload, events), do: record(events, :module_start, meta, payload)

    @impl Dspy.Module.Callback
    def on_module_end(meta, payload, events), do: record(events, :module_end, meta, payload)

    @impl Dspy.LM.Callback
    def on_lm_start(meta, payload, events), do: record(events, :lm_start, meta, payload)

    @impl Dspy.LM.Callback
    def on_lm_end(meta, payload, events), do: record(events, :lm_end, meta, payload)

    defp record(events, event, meta, payload) do
      Agent.update(events, &[{event, meta, payload} | &1])
    end
  end

  def run do
    {:ok, events} = Agent.start_link(fn -> [] end)

    try do
      %Dspy.Evaluate.Result{count: 2, failures: 1, scores: scores, score: 50.0} =
        result = evaluate(events)

      true = scores == [1.0, 0.0]

      verify_lifecycle!(Agent.get(events, & &1))

      IO.puts(
        "Evaluated #{result.count} rows with #{result.failures} failure and a score of #{result.score}%."
      )

      IO.puts("Verified 1 evaluation, 2 module calls, and 2 LM calls through paired callbacks.")
    after
      Agent.stop(events)
    end
  end

  defp evaluate(events) do
    success_question = "What is two plus two?"
    failure_question = "What is the scripted unavailable answer?"

    # Select the result by question so either evaluation task can run first.
    lm = %ScriptedLM{
      outcomes: %{
        success_question => {:ok, "Answer: Four"},
        failure_question => {:error, :scripted_failure}
      }
    }

    predictor =
      Dspy.predict(QA,
        lm: lm,
        adapter: Dspy.Signature.Adapters.Default,
        max_retries: 0,
        max_output_retries: 0
      )

    examples =
      for {question, answer} <- [{success_question, "Four"}, {failure_question, "Unknown"}] do
        Dspy.Example.new(%{question: question, answer: answer})
        |> Dspy.Example.with_inputs([:question])
      end

    Dspy.context([cache: false], fn ->
      Dspy.with_callbacks([{Recorder, events}], fn ->
        Dspy.Evaluate.evaluate(predictor, examples, &Dspy.Metrics.answer_exact_match/2,
          num_threads: 2,
          max_errors: 2,
          failure_score: 0.0
        )
      end)
    end)
  end

  defp verify_lifecycle!(events) do
    events =
      Enum.group_by(events, &elem(&1, 0), fn {_event, meta, payload} -> {meta, payload} end)

    6 = map_size(events)

    [{%{call_id: root} = root_meta, start_payload}] = events.evaluate_start
    true = is_reference(root) and start_payload == %{}
    nil = Map.get(root_meta, :parent_call_id)
    [{^root_meta, %{status: :ok, count: 2, failures: 1}}] = events.evaluate_end

    modules = paired_outcomes(events.module_start, events.module_end)
    lms = paired_outcomes(events.lm_start, events.lm_end)
    call_ids = [root | Enum.map(modules ++ lms, fn {%{call_id: id}, _status} -> id end)]
    5 = length(Enum.uniq(call_ids))

    module_outcomes =
      Enum.map(modules, fn {%{call_id: id, parent_call_id: ^root}, status} -> {id, status} end)

    lm_outcomes =
      Enum.map(lms, fn {%{parent_call_id: module_id}, status} -> {module_id, status} end)

    [:error, :ok] = module_outcomes |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    true = Enum.sort(module_outcomes) == Enum.sort(lm_outcomes)
  end

  defp paired_outcomes(starts, ends) do
    2 = length(starts)
    2 = length(ends)

    by_id =
      Map.new(starts, fn {%{call_id: id} = meta, payload} ->
        true = is_reference(id) and payload == %{}
        {id, meta}
      end)

    2 = map_size(by_id)

    Enum.map(ends, fn {%{call_id: id} = meta, %{status: status}} ->
      ^meta = Map.fetch!(by_id, id)
      {meta, status}
    end)
  end
end

EvaluationCallbacksOffline.run()
