defmodule Dspy.Evaluate.CompleteAndGroundedTest do
  @moduledoc """
  SS4 (M1-d): `Dspy.Evaluate.CompleteAndGrounded` module.

  Rows:
  5.  Judge answers completeness 1.0 / groundedness 1.0 → metric returns 1.0 (float)
  5b. completeness 1.0, groundedness 0.5 → abs(score - 0.6667) < 0.001
  6.  completeness 0.9, groundedness 0.8, threshold 0.7 → threshold_metric true
  6c. F1 exactly 0.66 at the default threshold → true (boundary)
  6d. F1 0.6828 with threshold 0.7 → false (rejects side; true under the default 0.66)
  7.  completeness 1.5 → clamped to 1.0 → score 1.0 (shared clamp reached)
  6b. Call order pinned: first request has :ground_truth, second has :retrieved_context
  10. Missing :context on the prediction → ArgumentError naming :context
  13. String-keyed example scores same as atom-keyed
  14. parameters/1 lists both inner predictors; update_parameters/2 round-trips

  15c. Successful judge through evaluate/4 → scored 0.6667, failures == 0 (D1 pin, B3)
  9b. Unparseable groundedness → JudgeError.raw_answer is that call's raw text

  NOTE: DummyLM scripts are ordered keyword lists in the signature's
  output-field order (B2: a map's iteration order is arbitrary on OTP 26+, so
  map-based scripts only matched signature order by chance). AnswerCompleteness:
  reasoning, ground_truth_key_ideas, system_response_key_ideas, discussion,
  completeness. AnswerGroundedness: reasoning, system_response_claims,
  discussion, groundedness.
  """

  use ExUnit.Case, async: true

  # Load the shared helper.
  Code.require_file("dummy_lm.ex", Path.expand("../../support", __DIR__))

  alias Dspy.TestSupport.DummyLM

  # --- helpers ---

  defp atom_example do
    Dspy.Example.new(%{question: "What is the capital of France?", response: "Paris"})
  end

  defp prediction do
    Dspy.Prediction.new(%{
      response: "The capital of France is Paris.",
      context: "France's capital is Paris."
    })
  end

  # --- Row 5 ---

  test "row 5: completeness 1.0 / groundedness 1.0 → metric returns 1.0, a float" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    metric_fn = Dspy.Evaluate.CompleteAndGrounded.metric(judge)

    lm =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "Full overlap",
          completeness: 1.0
        ],
        [
          reasoning: "r2",
          system_response_claims: "capital is Paris",
          discussion: "Fully supported",
          groundedness: 1.0
        ]
      ])

    score =
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    assert is_float(score)
    assert score == 1.0
  end

  # --- Row 5b (discriminability: not completeness alone, not groundedness alone) ---

  test "row 5b: completeness 1.0, groundedness 0.5 → abs(score - 0.6667) < 0.001" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    metric_fn = Dspy.Evaluate.CompleteAndGrounded.metric(judge)

    lm =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "Full overlap",
          completeness: 1.0
        ],
        [
          reasoning: "r2",
          system_response_claims: "capital is Paris",
          discussion: "Partly supported",
          groundedness: 0.5
        ]
      ])

    score =
      Dspy.context([lm: lm], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    # f1(0.5, 1.0) = 2 * 0.5 * 1.0 / (0.5 + 1.0) = 0.6667
    # If score came from completeness alone it would be 1.0; groundedness alone → 0.5.
    assert abs(score - 0.6667) < 0.001
  end

  # --- Row 6 (threshold) ---

  test "row 6: completeness 0.9, groundedness 0.8, threshold 0.7 → threshold_metric true" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new(threshold: 0.7)
    threshold_fn = Dspy.Evaluate.CompleteAndGrounded.threshold_metric(judge)

    lm =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "Mostly overlap",
          completeness: 0.9
        ],
        [
          reasoning: "r2",
          system_response_claims: "capital is Paris",
          discussion: "Well supported",
          groundedness: 0.8
        ]
      ])

    result =
      Dspy.context([lm: lm], fn ->
        threshold_fn.(atom_example(), prediction())
      end)

    # f1(0.8, 0.9) = 2 * 0.8 * 0.9 / (0.8 + 0.9) = 0.8687 ≥ 0.7
    assert result == true
  end

  # --- Row 6b (call order pin) ---

  test "row 6b: completeness call first, groundedness call second (upstream order)" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new(threshold: 0.7)
    threshold_fn = Dspy.Evaluate.CompleteAndGrounded.threshold_metric(judge)

    lm =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "Mostly overlap",
          completeness: 0.9
        ],
        [
          reasoning: "r2",
          system_response_claims: "capital is Paris",
          discussion: "Well supported",
          groundedness: 0.8
        ]
      ])

    Dspy.context([lm: lm], fn ->
      assert threshold_fn.(atom_example(), prediction()) == true
    end)

    assert DummyLM.call_count(lm) == 2
    [first_request, second_request | _] = DummyLM.requests(lm)

    # Each request is a map with a :messages key; the prompt is in the user
    # message content. Check that the first call's prompt contains
    # "Ground_truth:" (completeness call) and the second's contains
    # "Retrieved_context:" (groundedness call).
    first_prompt = first_request[:messages] |> List.last() |> Map.get(:content)
    second_prompt = second_request[:messages] |> List.last() |> Map.get(:content)

    # DummyLM stores requests in reverse order (prepended), so the FIRST
    # element is the LATEST call (groundedness) and the SECOND is the FIRST
    # call (completeness).
    assert first_prompt =~ "Retrieved_context:"
    refute first_prompt =~ "Ground_truth:"
    assert second_prompt =~ "Ground_truth:"
    refute second_prompt =~ "Retrieved_context:"

    # Lene: pin the VALUE after each label, so handing the groundedness judge
    # the gold answer instead of the retrieved context goes red.
    assert first_prompt =~ "Retrieved_context: France's capital is Paris."
    assert second_prompt =~ "Ground_truth: Paris\n"
  end

  # --- Row 10 (missing :context) ---

  test "row 10: missing :context on the prediction → ArgumentError naming :context" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    metric_fn = Dspy.Evaluate.CompleteAndGrounded.metric(judge)

    bad_prediction = Dspy.Prediction.new(%{response: "The capital of France is Paris."})

    assert_raise ArgumentError, ~r/context/, fn ->
      Dspy.context(
        [lm: DummyLM.new([[reasoning: "r", completeness: 1.0, groundedness: 1.0]])],
        fn ->
          metric_fn.(atom_example(), bad_prediction)
        end
      )
    end
  end

  # --- Row 13 (string-keyed example) ---

  test "row 13: string-keyed example scores the same as atom-keyed" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    metric_fn = Dspy.Evaluate.CompleteAndGrounded.metric(judge)

    string_example =
      Dspy.Example.new(%{"question" => "What is the capital of France?", "response" => "Paris"})

    lm1 =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "d",
          completeness: 0.9
        ],
        [reasoning: "r2", system_response_claims: "c", discussion: "d", groundedness: 0.8]
      ])

    score_atom =
      Dspy.context([lm: lm1], fn ->
        metric_fn.(atom_example(), prediction())
      end)

    lm2 =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "d",
          completeness: 0.9
        ],
        [reasoning: "r2", system_response_claims: "c", discussion: "d", groundedness: 0.8]
      ])

    score_string =
      Dspy.context([lm: lm2], fn ->
        metric_fn.(string_example, prediction())
      end)

    assert score_string == score_atom
  end

  # --- Row 14 (parameters delegation) ---

  test "row 14: parameters/1 lists both inner predictors; update_parameters/2 round-trips" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    params = Dspy.Module.parameters(judge)
    names = Enum.map(params, & &1.name)

    # Non-empty guard (vacuous-truth protection for M11).
    assert length(names) > 0, "parameters/1 returned an empty list"
    assert Enum.any?(names, &String.starts_with?(&1, "completeness_module."))
    assert Enum.any?(names, &String.starts_with?(&1, "groundedness_module."))

    # Round-trip: updating with the same params should preserve the prefixes.
    updated = Dspy.Module.update_parameters(judge, params)
    updated_names = Enum.map(Dspy.Module.parameters(updated), & &1.name)

    assert Enum.any?(updated_names, &String.starts_with?(&1, "completeness_module."))
    assert Enum.any?(updated_names, &String.starts_with?(&1, "groundedness_module."))
  end

  # --- Row 9b (B1, Lene): unparseable groundedness → JudgeError carries the raw text ---

  test "row 9b: groundedness 'N/A' → JudgeError.raw_answer is that call's raw text, shown in the message" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    metric_fn = Dspy.Evaluate.CompleteAndGrounded.metric(judge)

    lm =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "d",
          completeness: 0.9
        ],
        [reasoning: "r2", system_response_claims: "c", discussion: "d", groundedness: "N/A"]
      ])

    e =
      assert_raise Dspy.Evaluate.JudgeError, fn ->
        Dspy.context([lm: lm], fn -> metric_fn.(atom_example(), prediction()) end)
      end

    raw = "Reasoning: r2\nSystem_response_claims: c\nDiscussion: d\nGroundedness: N/A"
    assert e.raw_answer == raw
    assert Exception.message(e) =~ "(raw answer: #{inspect(raw)})"
    assert {:output_parse_failed, {:invalid_output_value, :groundedness, _}, _} = e.reason
  end

  # --- Row 15c (B3, Lene): D1 pinned through evaluate/4 for CompleteAndGrounded ---

  test "row 15c: successful judge through evaluate/4 → scored 0.6667, no failures" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    metric_fn = Dspy.Evaluate.CompleteAndGrounded.metric(judge)
    program = Dspy.ChainOfThought.new(Dspy.Signature.define("question -> response, context"))

    lm =
      DummyLM.new([
        [reasoning: "program thinks", response: "Paris", context: "France's capital is Paris."],
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "d",
          completeness: 1.0
        ],
        [reasoning: "r2", system_response_claims: "c", discussion: "d", groundedness: 0.5]
      ])

    result =
      Dspy.context([lm: lm], fn ->
        Dspy.Evaluate.evaluate(program, [atom_example()], metric_fn, max_errors: 2)
      end)

    assert result.failures == 0
    assert result.successes == 1
    assert [score] = result.scores
    assert abs(score - 0.6667) < 0.001
  end

  # --- Row 6c (Lene): F1 exactly ON the default threshold passes (>=, not >) ---

  test "row 6c: completeness 0.66, groundedness 0.66 (F1 exactly 0.66) at default threshold → true" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    threshold_fn = Dspy.Evaluate.CompleteAndGrounded.threshold_metric(judge)

    lm =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "d",
          completeness: 0.66
        ],
        [reasoning: "r2", system_response_claims: "c", discussion: "d", groundedness: 0.66]
      ])

    assert Dspy.context([lm: lm], fn -> threshold_fn.(atom_example(), prediction()) end) == true
  end

  # --- Row 6d (Lene): the rejects side of row 6 ---

  test "row 6d: completeness 0.9, groundedness 0.55 (F1 0.6828), threshold 0.7 → false" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new(threshold: 0.7)
    threshold_fn = Dspy.Evaluate.CompleteAndGrounded.threshold_metric(judge)

    lm =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "d",
          completeness: 0.9
        ],
        [reasoning: "r2", system_response_claims: "c", discussion: "d", groundedness: 0.55]
      ])

    assert Dspy.context([lm: lm], fn -> threshold_fn.(atom_example(), prediction()) end) == false
  end

  # --- Row 7 (Lene): CompleteAndGrounded goes through the shared clamp too ---

  test "row 7: completeness 1.5, groundedness 1.0 → clamped → 1.0 (not > 1.0)" do
    judge = Dspy.Evaluate.CompleteAndGrounded.new()
    metric_fn = Dspy.Evaluate.CompleteAndGrounded.metric(judge)

    lm =
      DummyLM.new([
        [
          reasoning: "r1",
          ground_truth_key_ideas: "Paris",
          system_response_key_ideas: "Paris",
          discussion: "d",
          completeness: 1.5
        ],
        [reasoning: "r2", system_response_claims: "c", discussion: "d", groundedness: 1.0]
      ])

    # Unclamped, f1(1.0, 1.5) = 1.2.
    assert Dspy.context([lm: lm], fn -> metric_fn.(atom_example(), prediction()) end) == 1.0
  end
end
