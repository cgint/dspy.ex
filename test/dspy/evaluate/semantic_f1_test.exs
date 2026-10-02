defmodule Dspy.Evaluate.SemanticF1Test do
  @moduledoc """
  SS3 (M1-d): `Dspy.Evaluate.SemanticF1` module + `JudgeError` exception.

  Rows:
  1.  Judge answers precision 1.0 / recall 1.0 → metric returns 1.0 (float, not Prediction)
  2.  precision 0.8 / recall 0.6 → abs(score - 0.6857) < 0.001
  3.  threshold_metric with threshold 0.5, judge answers 1.0/1.0 → true
  3b. precision 0.6 / recall 0.6: threshold 0.5 → true; default 0.66 → false
  3c. F1 exactly 0.66 at the default threshold → true (boundary)
  4.  Two judged calls: 0.8/0.6 then 0.9/0.7 → second score > first
  7.  precision 1.5, recall −0.2 (clamped to 1.0, 0.0) → 0.0
  8.  precision 0 / recall 0 → 0.0, no division error
  10. Missing :response on the example → ArgumentError naming :response
  12. decompositional: true → judge parses the decompositional fields, scores 0.6667; prompt is the decompositional one
  13. String-keyed example scores same as atom-keyed
  14. parameters/1 lists inner predictor under "module."; update_parameters/2 round-trips
  9.  Judge answers "N/A" for recall → metric raises Dspy.Evaluate.JudgeError
  9b. JudgeError carries the reason and raw answer (Q3)
  15. Through Dspy.Evaluate.evaluate/4: one example where judge answers "N/A" → failures == 1
  15b. Same as 15 but max_errors: 1 → raises Dspy.Evaluate.MaxErrorsExceeded
  15c. Successful judge through evaluate/4 → scored 0.6857, failures == 0 (D1 pin, B3)
  """

  use ExUnit.Case, async: true

  # Load the shared helper.
  Code.require_file("dummy_lm.ex", Path.expand("../../support", __DIR__))

  alias Dspy.TestSupport.DummyLM
  # (No additional aliases needed — signatures are referenced by full name.)

  # --- helpers ---

  defp atom_example do
    Dspy.Example.new(%{question: "What is the capital of France?", response: "Paris"})
  end

  defp prediction do
    Dspy.Prediction.new(%{response: "The capital of France is Paris."})
  end

  # A simple program (ChainOfThought on question -> response) for use in evaluate/4.
  defp eval_program do
    sig =
      Dspy.Signature.define("question -> response")

    Dspy.ChainOfThought.new(sig)
  end

  # --- Row 1 ---

  test "row 1: judge answers 1.0/1.0 → metric returns 1.0, a float (not a %Prediction{})" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    lm = DummyLM.new([[reasoning: "perfect", recall: 1.0, precision: 1.0]])

    score =
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    assert is_float(score)
    assert score == 1.0
  end

  # --- Row 2 ---

  test "row 2: precision 0.8 / recall 0.6 → abs(score - 0.6857) < 0.001" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    lm = DummyLM.new([[reasoning: "r", recall: 0.6, precision: 0.8]])

    score =
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    assert abs(score - 0.6857) < 0.001
  end

  # --- Row 3 ---

  test "row 3: threshold_metric with threshold 0.5, judge answers 1.0/1.0 → true" do
    judge = Dspy.Evaluate.SemanticF1.new(threshold: 0.5)
    threshold_fn = Dspy.Evaluate.SemanticF1.threshold_metric(judge)

    lm = DummyLM.new([[reasoning: "r", recall: 1.0, precision: 1.0]])

    result =
      Dspy.context([lm: lm], fn ->
        threshold_fn.(atom_example(), prediction())
      end)

    assert result == true
  end

  # --- Row 3b ---

  test "row 3b: precision 0.6 / recall 0.6 (F1 0.6): threshold 0.5 → true; default 0.66 → false" do
    lm_05 = DummyLM.new([[reasoning: "r", recall: 0.6, precision: 0.6]])
    judge_05 = Dspy.Evaluate.SemanticF1.new(threshold: 0.5)
    fn_05 = Dspy.Evaluate.SemanticF1.threshold_metric(judge_05)

    result_05 =
      Dspy.context([lm: lm_05], fn ->
        fn_05.(atom_example(), prediction())
      end)

    assert result_05 == true

    # Default threshold 0.66
    lm_default = DummyLM.new([[reasoning: "r", recall: 0.6, precision: 0.6]])
    judge_default = Dspy.Evaluate.SemanticF1.new()
    fn_default = Dspy.Evaluate.SemanticF1.threshold_metric(judge_default)

    result_default =
      Dspy.context([lm: lm_default], fn ->
        fn_default.(atom_example(), prediction())
      end)

    assert result_default == false
  end

  # --- Row 4 ---

  test "row 4: two judged calls 0.8/0.6 then 0.9/0.7 → second score > first" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    # First call: precision 0.8, recall 0.6 → f1 = 2*0.8*0.6/(0.8+0.6) = 0.96/1.4 ≈ 0.6857
    lm1 = DummyLM.new([[reasoning: "r1", recall: 0.6, precision: 0.8]])

    score1 =
      Dspy.context([lm: lm1], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    # Second call: precision 0.9, recall 0.7 → f1 = 2*0.9*0.7/(0.9+0.7) = 1.26/1.6 = 0.7875
    lm2 = DummyLM.new([[reasoning: "r2", recall: 0.7, precision: 0.9]])

    score2 =
      Dspy.context([lm: lm2], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    assert score2 > score1
  end

  # --- Row 7 (clamping) ---

  test "row 7: precision 1.5, recall -0.2 → clamped to 1.0 and 0.0 → f1 = 0.0" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    # recall: -0.2 clamps to 0.0; precision: 1.5 clamps to 1.0
    # f1(1.0, 0.0) = 2*1.0*0.0/(1.0+0.0) = 0.0
    lm = DummyLM.new([[reasoning: "r", recall: -0.2, precision: 1.5]])

    score =
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    assert score == 0.0
  end

  # --- Row 7b (clamp pins the upper bound — M3 killer) ---

  test "row 7b: precision 1.5, recall 1.0 → clamped to 1.0 and 1.0 → f1 = 1.0 (not > 1.0)" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    # Without the clamp (or with a wider clamp), precision 1.5 would stay 1.5,
    # and f1(1.5, 1.0) = 2*1.5*1.0/(1.5+1.0) = 1.2 > 1.0.
    # With the correct clamp [0,1], precision 1.5 → 1.0, and f1(1.0, 1.0) = 1.0.
    lm = DummyLM.new([[reasoning: "r", recall: 1.0, precision: 1.5]])

    score =
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    assert score == 1.0,
           "score #{inspect(score)} exceeds 1.0 — the clamp is not pinning the upper bound"
  end

  test "row 7c: precision 0.5, recall 1.5 → clamped to 0.5 and 1.0 → f1 = 0.6667" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    # recall 1.5 clamps to 1.0; precision 0.5 stays 0.5.
    # f1(0.5, 1.0) = 2*0.5*1.0/(0.5+1.0) = 0.6667.
    # Without the recall clamp, recall 1.5 would stay 1.5,
    # and f1(0.5, 1.5) = 2*0.5*1.5/(0.5+1.5) = 0.75 ≠ 0.6667.
    lm = DummyLM.new([[reasoning: "r", recall: 1.5, precision: 0.5]])

    score =
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    assert abs(score - 0.6667) < 0.001,
           "score #{inspect(score)} — recall clamp not pinning the upper bound"
  end

  # --- Row 8 (both zero) ---

  test "row 8: precision 0 / recall 0 → 0.0, no division error" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    lm = DummyLM.new([[reasoning: "r", recall: 0.0, precision: 0.0]])

    score =
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    assert score == 0.0
  end

  # --- Row 10 (missing field) ---

  test "row 10: missing :response on the example → ArgumentError naming :response" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    bad_example = Dspy.Example.new(%{question: "What is the capital of France?"})

    assert_raise ArgumentError, ~r/response/, fn ->
      Dspy.context([lm: DummyLM.new([[reasoning: "r", recall: 1.0, precision: 1.0]])], fn ->
        metric_fn.(bad_example, prediction())
      end)
    end
  end

  # --- Row 12 (decompositional) ---

  test "row 12: decompositional: true → judge parses its 6 fields and scores 0.6667" do
    judge = Dspy.Evaluate.SemanticF1.new(decompositional: true)
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    # The decompositional signature has 5 output fields, plus the reasoning
    # field ChainOfThought prepends. DummyLM emits them in this (signature)
    # order — an ordered keyword list, never a map (B2: map order is arbitrary
    # on OTP 26+, which is what made this row look like a parser limitation).
    lm =
      DummyLM.new([
        [
          reasoning: "r",
          ground_truth_key_ideas: "Paris, France",
          system_response_key_ideas: "Paris, capital",
          discussion: "Good overlap",
          recall: 1.0,
          precision: 0.5
        ]
      ])

    score = Dspy.context([lm: lm], fn -> metric_fn.(atom_example(), prediction()) end)

    # f1(precision 0.5, recall 1.0) = 2*0.5*1.0/1.5 = 0.6667
    assert abs(score - 0.6667) < 0.001

    # The LM was called (scripted answer was consumed).
    assert DummyLM.call_count(lm) == 1

    # The request should include the decompositional prompt content.
    [request | _] = DummyLM.requests(lm)
    messages = request[:messages]
    # messages is a list of maps: [%{role: "user", content: prompt}]
    prompt_text =
      messages
      |> Enum.map(& &1[:content])
      |> Enum.join("\n")

    # The decompositional signature mentions "key ideas" in its instructions
    # and output field descriptions. The non-decompositional signature does not.
    assert prompt_text =~ "key ideas"
    assert prompt_text =~ "ground_truth_key_ideas"
  end

  # --- Row 13 (string-keyed example) ---

  test "row 13: string-keyed example scores the same as atom-keyed" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    string_example =
      Dspy.Example.new(%{"question" => "What is the capital of France?", "response" => "Paris"})

    lm1 = DummyLM.new([[reasoning: "r", recall: 0.6, precision: 0.8]])

    score_atom =
      Dspy.context([lm: lm1], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    lm2 = DummyLM.new([[reasoning: "r", recall: 0.6, precision: 0.8]])

    score_string =
      Dspy.context([lm: lm2], fn ->
        metric_fn.(string_example, prediction())
      end)

    assert score_string == score_atom
  end

  # --- Row 14 (parameters delegation) ---

  test "row 14: parameters/1 lists inner predictor under 'module.'; update_parameters/2 round-trips" do
    judge = Dspy.Evaluate.SemanticF1.new()
    params = Dspy.Module.parameters(judge)

    # The inner ChainOfThought has parameters like "predict.examples" and
    # "predict.instructions" (since the signature has instructions).
    # After delegation they should be prefixed with "module.".
    # Also assert the list is non-empty (vacuous-truth guard for M11).
    names = Enum.map(params, & &1.name)
    assert length(names) > 0, "parameters/1 returned an empty list"
    assert Enum.all?(names, fn name -> String.starts_with?(name, "module.") end)

    # Round-trip: update_parameters with the same params should preserve values.
    updated = Dspy.Module.update_parameters(judge, params)
    updated_params = Dspy.Module.parameters(updated)
    updated_names = Enum.map(updated_params, & &1.name)

    assert Enum.all?(updated_names, fn name -> String.starts_with?(name, "module.") end)
  end

  # --- Row 9 (JudgeError on "N/A") ---

  test "row 9: judge answers 'N/A' for recall → metric raises Dspy.Evaluate.JudgeError" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    # The DummyLM formats values via to_string/inspect. For :number fields,
    # "N/A" will fail the strict parser → {:error, {:invalid_output_value, ...}}.
    lm = DummyLM.new([[reasoning: "r", recall: "N/A", precision: 0.8]])

    assert_raise Dspy.Evaluate.JudgeError, fn ->
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)
    end
  end

  # --- Row 9b (Q3: JudgeError carries reason and raw answer) ---

  test "row 9b: JudgeError carries reason and raw answer" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    lm = DummyLM.new([[reasoning: "r", recall: "N/A", precision: 0.8]])

    try do
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

      flunk("expected JudgeError to be raised")
    rescue
      e in Dspy.Evaluate.JudgeError ->
        # Q3: reason is the adapter's tuple, raw_answer is the raw text
        assert e.reason != nil

        # The reason should be a tuple starting with :invalid_output_value or :missing_required_outputs
        assert is_tuple(e.reason)
        # B1 (Lene): the raw judge text is carried in raw_answer itself (not
        # only by accident through the inspected reason), and the message shows it.
        assert e.raw_answer == "Reasoning: r\nRecall: N/A\nPrecision: 0.8"

        assert Exception.message(e) =~
                 "(raw answer: \"Reasoning: r\\nRecall: N/A\\nPrecision: 0.8\")"
    end
  end

  # --- Row 15 (through evaluate/4: one failing example) ---

  test "row 15: through evaluate/4 → failures == 1, failure_score counted" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)

    # The program (CoT on question -> response) is called first, then the metric.
    # We need 2 scripted answers: one for the program, one for the judge (which will fail).
    # Program answer: question -> response
    # Judge answer: precision 0.8, recall "N/A" → parse error → JudgeError → :error → failure
    program = eval_program()

    # The program and judge share the same LM context. We need 2 scripted answers:
    # 1st: the program's answer (question -> response)
    # 2nd: the judge's answer (with "N/A" for recall → will fail parsing)
    lm =
      DummyLM.new([
        [reasoning: "program thinks", response: "Paris"],
        [reasoning: "judge thinks", recall: "N/A", precision: 0.8]
      ])

    devset = [atom_example()]

    result =
      Dspy.context([lm: lm], fn ->
        Dspy.Evaluate.evaluate(program, devset, metric_fn, max_errors: 2)
      end)

    assert result.failures == 1
  end

  # --- Row 15b (max_errors: 1 → MaxErrorsExceeded) ---

  test "row 15b: same as 15 but max_errors: 1 → raises MaxErrorsExceeded" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)
    program = eval_program()

    lm =
      DummyLM.new([
        [reasoning: "program thinks", response: "Paris"],
        [reasoning: "judge thinks", recall: "N/A", precision: 0.8]
      ])

    devset = [atom_example()]

    assert_raise Dspy.Evaluate.MaxErrorsExceeded, fn ->
      Dspy.context([lm: lm], fn ->
        Dspy.Evaluate.evaluate(program, devset, metric_fn, max_errors: 1)
      end)
    end
  end

  # --- Row 15c (B3, Lene): D1 pinned through evaluate/4 with a SUCCESSFUL judge ---

  test "row 15c: successful judge through evaluate/4 → scored (a float reaches Evaluate), no failures" do
    judge = Dspy.Evaluate.SemanticF1.new()
    metric_fn = Dspy.Evaluate.SemanticF1.metric(judge)
    program = eval_program()

    lm =
      DummyLM.new([
        [reasoning: "program thinks", response: "Paris"],
        [reasoning: "judge thinks", recall: 0.6, precision: 0.8]
      ])

    result =
      Dspy.context([lm: lm], fn ->
        Dspy.Evaluate.evaluate(program, [atom_example()], metric_fn, max_errors: 2)
      end)

    assert result.failures == 0
    assert result.successes == 1
    assert [score] = result.scores
    assert abs(score - 0.6857) < 0.001
  end

  # --- Row 3c (Lene): F1 exactly ON the default threshold passes (>=, not >) ---

  test "row 3c: precision 0.66 / recall 0.66 (F1 exactly 0.66) at default threshold → true" do
    lm = DummyLM.new([[reasoning: "r", recall: 0.66, precision: 0.66]])
    judge = Dspy.Evaluate.SemanticF1.new()
    fn_default = Dspy.Evaluate.SemanticF1.threshold_metric(judge)

    assert Dspy.context([lm: lm], fn -> fn_default.(atom_example(), prediction()) end) == true
  end
end
