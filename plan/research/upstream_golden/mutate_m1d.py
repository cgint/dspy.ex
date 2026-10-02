#!/usr/bin/env python3
"""M1-d mutation harness on the H20-C2 library (migration 2026-10-02).

Migrated from `plan/research/upstream_golden/mutate_m1d.py` (v0.4.4) to use
`mutlib.py` (the shared mutation-testing library, contract H20-C2). The old
harness matched test names by module + row-prefix; the new library requires
exact ExUnit test names (without the "test " prefix) and decides the verdict
against a JSON report written by `mut_formatter.exs`.

Mutations (file -> claimed rows):
  M1   SemanticF1.metric/1 returns %Prediction{} (revert D1)  -> SF1 rows 1, 15c
  M1c  CompleteAndGrounded.metric/1 returns %Prediction{}      -> CAG rows 5, 15c
  M2   shared f1: arithmetic mean                               -> SF1 row 2
  M3   shared clamp upper bound 1.5                             -> SF1 row 7b, CAG row 7
  M3b  shared clamp lower bound -1.0                            -> SF1 row 7
  M4   shared f1: drop the sum==0 guard                         -> SF1 row 8
  M5   CAG: groundedness call before completeness               -> CAG row 6b
  M6   CAG: score from completeness alone                       -> CAG row 5b
  M7   SF1: ignore threshold option                             -> SF1 row 3b
  M8   CAG: ignore threshold option                             -> CAG row 6d
  M9   SF1: missing field defaults to ""                        -> SF1 row 10
  M10  SF1: Map.get instead of Access                           -> SF1 row 13
  M11  SF1: parameters/1 returns []                             -> SF1 row 14
  M12  SF1: swallow {:error, _} into 0.0 (H5)                   -> SF1 rows 9, 15
  M13  SF1: raw_answer not filled on {:error, _} (revert B1)    -> SF1 row 9b
  M14  CAG: raw_answer not filled on {:error, _} (revert B1)    -> CAG row 9b
  M15  DummyLM emits fields in sorted (map-like) order          -> SF1 row 12
  M16  SF1 caller bypasses shared f1 (own unclamped copy)       -> SF1 row 7b
  M17  CAG caller bypasses shared f1 (own unclamped copy)       -> CAG row 7
  M18  SF1 threshold >= becomes >                               -> SF1 row 3c
  M19  CAG threshold >= becomes >                               -> CAG row 6c
  M20  CAG groundedness judge given the gold answer as context  -> CAG row 6b

Usage: python3 plan/research/upstream_golden/mutate_m1d.py
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "plan" / "research" / "harness"))

from mutlib import EXIT_ENFILE, EXIT_FAIL, EXIT_OK, Harness, Mutation  # noqa: E402

EV = ROOT / "lib" / "dspy" / "evaluate"
SEMANTIC_F1 = EV / "semantic_f1.ex"
CAG = EV / "complete_and_grounded.ex"
JUDGE_SCORE = EV / "judge_score.ex"
DUMMY_LM = ROOT / "test" / "support" / "dummy_lm.ex"

# Every test file of the slice (an omitted file is a false-zero source).
TEST_DIR = ROOT / "test" / "dspy" / "evaluate"
TEST_FILES = sorted(str(p) for p in TEST_DIR.glob("*_test.exs"))

# Acceptance files for the coverage check (C3a).
ACCEPTANCE_FILES = [
    ROOT / "test" / "dspy" / "evaluate" / "semantic_f1_test.exs",
    ROOT / "test" / "dspy" / "evaluate" / "complete_and_grounded_test.exs",
]


def main():
    mutations = [
        Mutation(
            id="M1",
            file=SEMANTIC_F1,
            old="""      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      score
    end
  end

  @doc \"\"\"
  Return a threshold metric""",
            new="""      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      # MUTATION M1
      Dspy.Prediction.new(%{score: score})
    end
  end

  @doc \"\"\"
  Return a threshold metric""",
            expect=["row 1: judge answers 1.0/1.0 → metric returns 1.0, a float (not a %Prediction{})",
                    "row 15c: successful judge through evaluate/4 → scored (a float reaches Evaluate), no failures"],
            also=["row 2: precision 0.8 / recall 0.6 → abs(score - 0.6857) < 0.001",
                  "row 7: precision 1.5, recall -0.2 → clamped to 1.0 and 0.0 → f1 = 0.0",
                  "row 7b: precision 1.5, recall 1.0 → clamped to 1.0 and 1.0 → f1 = 1.0 (not > 1.0)",
                  "row 7c: precision 0.5, recall 1.5 → clamped to 0.5 and 1.0 → f1 = 0.6667",
                  "row 8: precision 0 / recall 0 → 0.0, no division error",
                  "row 12: decompositional: true → judge parses its 6 fields and scores 0.6667"],
            kind="any",
            why="SemanticF1.metric/1 returns %Prediction{} (revert D1)",
        ),
        Mutation(
            id="M1c",
            file=CAG,
            old="""      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      score
    end
  end

  @doc \"\"\"
  Return a threshold metric""",
            new="""      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      # MUTATION M1c
      Dspy.Prediction.new(%{score: score})
    end
  end

  @doc \"\"\"
  Return a threshold metric""",
            expect=["row 5: completeness 1.0 / groundedness 1.0 → metric returns 1.0, a float",
                    "row 15c: successful judge through evaluate/4 → scored 0.6667, no failures"],
            also=["row 5b: completeness 1.0, groundedness 0.5 → abs(score - 0.6667) < 0.001",
                  "row 6d: completeness 0.9, groundedness 0.55 (F1 0.6828), threshold 0.7 → false",
                  "row 7: completeness 1.5, groundedness 1.0 → clamped → 1.0 (not > 1.0)"],
            kind="any",
            why="CompleteAndGrounded.metric/1 returns %Prediction{} (revert D1)",
        ),
        Mutation(
            id="M2",
            file=JUDGE_SCORE,
            old="      2.0 * x * y / (x + y)",
            new="      # MUTATION M2\n      (x + y) / 2.0",
            expect=["row 2: precision 0.8 / recall 0.6 → abs(score - 0.6857) < 0.001"],
            also=["row 5b: completeness 1.0, groundedness 0.5 → abs(score - 0.6667) < 0.001",
                  "row 6d: completeness 0.9, groundedness 0.55 (F1 0.6828), threshold 0.7 → false",
                  "row 7: precision 1.5, recall -0.2 → clamped to 1.0 and 0.0 → f1 = 0.0",
                  "row 7c: precision 0.5, recall 1.5 → clamped to 0.5 and 1.0 → f1 = 0.6667",
                  "row 12: decompositional: true → judge parses its 6 fields and scores 0.6667",
                  "row 15c: successful judge through evaluate/4 → scored (a float reaches Evaluate), no failures",
                  "row 15c: successful judge through evaluate/4 → scored 0.6667, no failures"],
            kind="assertion",
            why="shared f1: arithmetic mean instead of harmonic",
        ),
        Mutation(
            id="M3",
            file=JUDGE_SCORE,
            old="do: max(0.0, min(1.0, value * 1.0))",
            new="do: max(0.0, min(1.5, value * 1.0)) # MUTATION M3",
            expect=["row 7b: precision 1.5, recall 1.0 → clamped to 1.0 and 1.0 → f1 = 1.0 (not > 1.0)"],
            also=["row 7: precision 1.5, recall -0.2 → clamped to 1.0 and 0.0 → f1 = 0.0",
                  "row 7c: precision 0.5, recall 1.5 → clamped to 0.5 and 1.0 → f1 = 0.6667",
                  "row 7: completeness 1.5, groundedness 1.0 → clamped → 1.0 (not > 1.0)"],
            kind="assertion",
            why="shared clamp: upper bound 1.5",
        ),
        Mutation(
            id="M3b",
            file=JUDGE_SCORE,
            old="do: max(0.0, min(1.0, value * 1.0))",
            new="do: max(-1.0, min(1.0, value * 1.0)) # MUTATION M3b",
            expect=["row 7: precision 1.5, recall -0.2 → clamped to 1.0 and 0.0 → f1 = 0.0"],
            kind="assertion",
            why="shared clamp: lower bound -1.0",
        ),
        Mutation(
            id="M4",
            file=JUDGE_SCORE,
            old="""    if x + y == 0.0 do
      0.0
    else
      2.0 * x * y / (x + y)
    end""",
            new="""    # MUTATION M4
    2.0 * x * y / (x + y)""",
            expect=["row 8: precision 0 / recall 0 → 0.0, no division error"],
            kind="raise:Elixir.ArithmeticError",
            why="shared f1: drop the sum == 0 guard",
        ),
        Mutation(
            id="M5",
            file=CAG,
            old="""    completeness =
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
      |> judge_result("groundedness")""",
            new="""    # MUTATION M5
    groundedness =
      Dspy.call(judge.groundedness_module, %{
        question: question,
        retrieved_context: retrieved_context,
        system_response: system_response
      })
      |> judge_result("groundedness")

    completeness =
      Dspy.call(judge.completeness_module, %{
        question: question,
        ground_truth: ground_truth,
        system_response: system_response
      })
      |> judge_result("completeness")""",
            expect=["row 6b: completeness call first, groundedness call second (upstream order)"],
            also=["row 5: completeness 1.0 / groundedness 1.0 → metric returns 1.0, a float",
                  "row 5b: completeness 1.0, groundedness 0.5 → abs(score - 0.6667) < 0.001",
                  "row 6: completeness 0.9, groundedness 0.8, threshold 0.7 → threshold_metric true",
                  "row 6c: completeness 0.66, groundedness 0.66 (F1 exactly 0.66) at default threshold → true",
                  "row 6d: completeness 0.9, groundedness 0.55 (F1 0.6828), threshold 0.7 → false",
                  "row 7: completeness 1.5, groundedness 1.0 → clamped → 1.0 (not > 1.0)",
                  "row 13: string-keyed example scores the same as atom-keyed",
                  "row 9b: groundedness 'N/A' → JudgeError.raw_answer is that call's raw text, shown in the message",
                  "row 15c: successful judge through evaluate/4 → scored 0.6667, no failures"],
            kind="raise:Dspy.Evaluate.JudgeError",
            why="CAG: groundedness call first",
        ),
        Mutation(
            id="M6",
            file=CAG,
            old="    score = JudgeScore.f1(groundedness_value, completeness_value)",
            new="    # MUTATION M6\n    score = completeness_value * 1.0",
            expect=["row 5b: completeness 1.0, groundedness 0.5 → abs(score - 0.6667) < 0.001"],
            also=["row 6d: completeness 0.9, groundedness 0.55 (F1 0.6828), threshold 0.7 → false",
                  "row 7: completeness 1.5, groundedness 1.0 → clamped → 1.0 (not > 1.0)",
                  "row 15c: successful judge through evaluate/4 → scored 0.6667, no failures"],
            kind="assertion",
            why="CAG: score from completeness alone",
        ),
        Mutation(
            id="M7",
            file=SEMANTIC_F1,
            old="    threshold = Keyword.get(opts, :threshold, 0.66)",
            new="    # MUTATION M7\n    threshold = 0.66",
            expect=["row 3b: precision 0.6 / recall 0.6 (F1 0.6): threshold 0.5 → true; default 0.66 → false"],
            kind="assertion",
            why="SF1: ignore the threshold option",
        ),
        Mutation(
            id="M8",
            file=CAG,
            old="    threshold = Keyword.get(opts, :threshold, 0.66)",
            new="    # MUTATION M8\n    threshold = 0.66",
            expect=["row 6d: completeness 0.9, groundedness 0.55 (F1 0.6828), threshold 0.7 → false"],
            kind="assertion",
            why="CAG: ignore the threshold option",
        ),
        Mutation(
            id="M9",
            file=SEMANTIC_F1,
            old="""      :error -> raise ArgumentError, "missing #{label}\"""",
            new="""      :error -> "" # MUTATION M9""",
            expect=["row 10: missing :response on the example → ArgumentError naming :response"],
            kind="any",
            why="SF1: missing field defaults to \"\"",
        ),
        Mutation(
            id="M10",
            file=SEMANTIC_F1,
            old="""    value = Access.fetch(container, field)
""",
            new="""    # MUTATION M10
    value = Map.fetch(container.attrs, field)
""",
            expect=["row 13: string-keyed example scores the same as atom-keyed"],
            kind="raise:Elixir.ArgumentError",
            why="SF1: Map.fetch on attrs instead of Access (string keys break)",
        ),
        Mutation(
            id="M11",
            file=SEMANTIC_F1,
            old="""  def parameters(%__MODULE__{} = judge) do
    judge.module
    |> Dspy.Module.parameters()""",
            new="""  def parameters(%__MODULE__{} = judge) do
    # MUTATION M11
    _ = judge
    []""",
            expect=["row 14: parameters/1 lists inner predictor under 'module.'; update_parameters/2 round-trips"],
            kind="assertion",
            why="SF1: parameters/1 returns []",
        ),
        Mutation(
            id="M12",
            file=SEMANTIC_F1,
            old="""      {:error, reason} ->
        raise JudgeError, reason: reason, raw_answer: JudgeScore.raw_output(reason)""",
            new="""      {:error, _reason} ->
        # MUTATION M12
        {:ok, %{score: 0.0}}""",
            expect=["row 9: judge answers 'N/A' for recall → metric raises Dspy.Evaluate.JudgeError",
                    "row 15: through evaluate/4 → failures == 1, failure_score counted"],
            also=["row 9b: JudgeError carries reason and raw answer",
                  "row 15b: same as 15 but max_errors: 1 → raises MaxErrorsExceeded"],
            kind="any",
            why="SF1: swallow {:error, _} into 0.0 (H5)",
        ),
        Mutation(
            id="M13",
            file=SEMANTIC_F1,
            old="raise JudgeError, reason: reason, raw_answer: JudgeScore.raw_output(reason)",
            new="raise JudgeError, reason: reason, raw_answer: nil # MUTATION M13",
            expect=["row 9b: JudgeError carries reason and raw answer"],
            kind="assertion",
            why="SF1: raw_answer not filled from the reason (revert B1)",
        ),
        Mutation(
            id="M14",
            file=CAG,
            old="raise JudgeError, reason: reason, raw_answer: JudgeScore.raw_output(reason)",
            new="raise JudgeError, reason: reason, raw_answer: nil # MUTATION M14",
            expect=["row 9b: groundedness 'N/A' → JudgeError.raw_answer is that call's raw text, shown in the message"],
            kind="assertion",
            why="CAG: raw_answer not filled from the reason (revert B1)",
        ),
        Mutation(
            id="M15",
            file=DUMMY_LM,
            old="""    entry
    |> Enum.map(fn {field, value} ->""",
            new="""    entry
    # MUTATION M15
    |> Enum.sort()
    |> Enum.map(fn {field, value} ->""",
            expect=["row 12: decompositional: true → judge parses its 6 fields and scores 0.6667"],
            also=["row 9b: JudgeError carries reason and raw answer",
                  "row 9b: groundedness 'N/A' → JudgeError.raw_answer is that call's raw text, shown in the message",
                  "emits fields in keyword-list order, not sorted order"],
            kind="any",
            why="DummyLM emits fields in sorted (map-like) order (revert B2)",
        ),
        Mutation(
            id="M16",
            file=SEMANTIC_F1,
            old="        score = JudgeScore.f1(precision, recall)",
            new="        # MUTATION M16\n        score = 2.0 * precision * recall / (precision + recall)",
            expect=["row 7b: precision 1.5, recall 1.0 → clamped to 1.0 and 1.0 → f1 = 1.0 (not > 1.0)"],
            also=["row 8: precision 0 / recall 0 → 0.0, no division error",
                  "row 7c: precision 0.5, recall 1.5 → clamped to 0.5 and 1.0 → f1 = 0.6667",
                  "row 7: precision 1.5, recall -0.2 → clamped to 1.0 and 0.0 → f1 = 0.0"],
            kind="assertion",
            why="SF1 caller bypasses the shared f1 (unclamped local copy)",
        ),
        Mutation(
            id="M17",
            file=CAG,
            old="    score = JudgeScore.f1(groundedness_value, completeness_value)",
            new="    # MUTATION M17\n    score = 2.0 * groundedness_value * completeness_value / (groundedness_value + completeness_value)",
            expect=["row 7: completeness 1.5, groundedness 1.0 → clamped → 1.0 (not > 1.0)"],
            kind="assertion",
            why="CAG caller bypasses the shared f1 (unclamped local copy)",
        ),
        Mutation(
            id="M18",
            file=SEMANTIC_F1,
            old="      score >= judge.threshold",
            new="      score > judge.threshold # MUTATION M18",
            expect=["row 3c: precision 0.66 / recall 0.66 (F1 exactly 0.66) at default threshold → true"],
            kind="assertion",
            why="SF1 threshold: >= becomes >",
        ),
        Mutation(
            id="M19",
            file=CAG,
            old="      score >= judge.threshold",
            new="      score > judge.threshold # MUTATION M19",
            expect=["row 6c: completeness 0.66, groundedness 0.66 (F1 exactly 0.66) at default threshold → true"],
            kind="assertion",
            why="CAG threshold: >= becomes >",
        ),
        Mutation(
            id="M20",
            file=CAG,
            old="""        retrieved_context: retrieved_context,
        system_response: system_response""",
            new="""        retrieved_context: ground_truth, # MUTATION M20
        system_response: system_response""",
            expect=["row 6b: completeness call first, groundedness call second (upstream order)"],
            kind="assertion",
            why="CAG: groundedness judge given the gold answer instead of the context",
        ),
    ]

    # Tests that are not claimed by any mutation (suite-level or out of scope).
    exempt = {
        "row 3: threshold_metric with threshold 0.5, judge answers 1.0/1.0 → true": "M18 covers row 3c; row 3 is a different test",
        "row 4: two judged calls 0.8/0.6 then 0.9/0.7 → second score > first": "not covered by M1-d mutations",
        "row 6: completeness 0.9, groundedness 0.8, threshold 0.7 → threshold_metric true": "M5 covers row 6b; row 6 is a different test",
        "row 7c: precision 0.5, recall 1.5 → clamped to 0.5 and 1.0 → f1 = 0.6667": "M3 covers row 7b; row 7c is a different test",
        "row 10: missing :context on the prediction → ArgumentError naming :context": "CAG row 10, not covered",
        "row 13: string-keyed example scores the same as atom-keyed": "CAG row 13, covered by M5 also",
        "row 14: parameters/1 lists both inner predictors; update_parameters/2 round-trips": "CAG row 14, not covered",
        "row 15b: same as 15 but max_errors: 1 → raises MaxErrorsExceeded": "M12 covers row 15; row 15b is a different test",
    }

    h = Harness(
        mutations=mutations,
        test_files=TEST_FILES,
        acceptance_files=ACCEPTANCE_FILES,
        root=ROOT,
        exempt=exempt,
        report_path=ROOT / "mutation_report.json",
    )
    sys.exit(h.run())


if __name__ == "__main__":
    main()
