#!/usr/bin/env python3
"""H15 mutation harness on the H20-C2 library (mutation proof, C2).

Contract: `openspec/changes/h15-string-key-audit/` (LOCKED, rulings R1-R5).
Acceptance rows: `test/dspy/string_keys_test.exs` (C3a: every test claimed or exempt).

Mutation directions (contract (d)):
  * Direction 1, revert each caller: put back that site's code exactly as on
    3fcbea1; the site's row must go red, and nothing else.
  * Direction 2, break the shared function: every row that depends on it goes red.
  * Sites whose old code was already correct (S4-S6) are proven by MS1 + Z1
    (no revert mutation is declared for them, by the contract's own rule).

Usage: python3 plan/research/upstream_golden/mutate_h15.py
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "plan" / "research" / "harness"))

from mutlib import EXIT_ENFILE, EXIT_FAIL, EXIT_OK, Harness, Mutation  # noqa: E402

LIB = ROOT / "lib" / "dspy"
ATTRS = LIB / "attrs.ex"
METRICS = LIB / "metrics.ex"
SIGNATURE = LIB / "signature.ex"
TRAINSET = LIB / "trainset.ex"
ENSEMBLE = LIB / "teleprompt" / "ensemble.ex"
MCC = LIB / "multi_chain_comparison.ex"
MAJORITY = LIB / "majority.ex"
EXAMPLE = LIB / "example.ex"

# Every acceptance test file of the slice (an omitted file is a false-zero source).
ACCEPTANCE_FILES = [
    ROOT / "test" / "dspy" / "string_keys_test.exs",
]
TEST_FILES = [
    str(ROOT / "test" / "dspy" / "string_keys_test.exs"),
    str(ROOT / "test" / "dspy" / "attrs_test.exs"),
]


def main():
    mutations = [
        Mutation(
            id="MR1",
            file=METRICS,
            old="""  defp fetch_field!(%{attrs: attrs}, label) do
    case Dspy.Attrs.fetch(attrs, :answer) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{label}[:answer] is missing"
    end
  end""",
            new="""  defp fetch_field!(%{attrs: attrs}, label) do
    # MUTATION MR1 (revert S1 to the 3fcbea1 atom-only read)
    case Map.fetch(attrs, :answer) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{label}[:answer] is missing"
    end
  end""",
            expect=["row 1: answer_exact_match string-keyed example and prediction → true"],
            also=[
                "row 2: answer_passage_match string-keyed context → true",
                "row 4: Evaluate over a string-keyed devset scores 100.0, failures 0",
            ],
            kind="raise:Elixir.ArgumentError",
            why="fetch_field! back to Map.fetch(attrs, :answer)",
        ),
        Mutation(
            id="MR2",
            file=METRICS,
            old="""  defp fetch_context!(%{attrs: attrs}, label) do
    case Dspy.Attrs.fetch(attrs, :context) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{label}[:context] is missing"
    end
  end""",
            new="""  defp fetch_context!(%{attrs: attrs}, label) do
    # MUTATION MR2 (revert S2 to the 3fcbea1 atom-only read)
    case Map.fetch(attrs, :context) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{label}[:context] is missing"
    end
  end""",
            expect=["row 2: answer_passage_match string-keyed context → true"],
            kind="raise:Elixir.ArgumentError",
            why="fetch_context! back to atom-only Map.fetch",
        ),
        Mutation(
            id="MR3",
            file=SIGNATURE,
            old="""      # H15 (S3): the canonical accessor renders string-keyed demo values too;
      # the "" default keeps atom-keyed prompts byte-identical (MR3b pins it).
      # Plain-map demos (R3) remain out of scope: a bare map with no :attrs
      # raises, exactly as today.
      value = Dspy.Attrs.get(example, field.name, "")""",
            new="""      # MUTATION MR3 (revert S3 to the 3fcbea1 atom-only read)
      value = Map.get(example.attrs || example, field.name, "")""",
            expect=[
                "row 5: Default adapter renders string-keyed demo values",
                "row 6: JSON adapter renders string-keyed demo values",
            ],
            kind="assertion",
            why="format_fields back to Map.get(example.attrs || example, ...)",
        ),
        Mutation(
            id="MR3b",
            file=SIGNATURE,
            old='value = Dspy.Attrs.get(example, field.name, "")',
            new='value = Dspy.Attrs.get(example, field.name, nil) # MUTATION MR3b',
            expect=["row 7: atom-keyed demo prompts byte-identical to 3fcbea1"],
            kind="assertion",
            why="accessor default \"\" → nil (missing-field demo renders differently)",
        ),
        Mutation(
            id="MR3c",
            file=METRICS,
            old="""    case Dspy.Attrs.fetch(attrs, :answer) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "#{label}[:answer] is missing"
    end""",
            new="""    # MUTATION MR3c (row 3 mutation: no raise on missing, default "")
    Dspy.Attrs.get(attrs, :answer, "")""",
            expect=['row 3: answer missing in both forms → raises "example[:answer] is missing"'],
            kind="assertion",
            why="fetch_field! uses a default instead of raising",
        ),
        Mutation(
            id="MR7",
            file=TRAINSET,
            old="""      |> Enum.map(fn example ->
        # H15 (S7): canonical accessor — a string "difficulty" is now read.
        difficulty = Dspy.Attrs.get(example, difficulty_field, 0.5)
        {example, difficulty}
      end)""",
            new="""      |> Enum.map(fn example ->
        # MUTATION MR7 (revert S7 to atom-only)
        difficulty = Map.get(example.attrs, difficulty_field, 0.5)
        {example, difficulty}
      end)""",
            expect=['row 11: hard strategy orders by string "difficulty"'],
            kind="assertion",
            why="hard_sample back to atom-only Map.get",
        ),
        Mutation(
            id="MR8",
            file=TRAINSET,
            old="""      |> Enum.map(fn example ->
        # H15 (S8): canonical accessor — a string "uncertainty" is now read.
        uncertainty = Dspy.Attrs.get(example, uncertainty_field, 0.5)
        {example, uncertainty}
      end)""",
            new="""      |> Enum.map(fn example ->
        # MUTATION MR8 (revert S8 to atom-only)
        uncertainty = Map.get(example.attrs, uncertainty_field, 0.5)
        {example, uncertainty}
      end)""",
            expect=['row 12: uncertainty strategy uses string "uncertainty"'],
            kind="assertion",
            why="uncertainty_sample back to atom-only Map.get",
        ),
        Mutation(
            id="MR9",
            file=ENSEMBLE,
            old="""    |> Enum.max_by(fn pred ->
      # H15 (S9): canonical accessor — a string "confidence" is now read.
      Dspy.Attrs.get(pred, :confidence, 0.5)
    end)""",
            new="""    |> Enum.max_by(fn pred ->
      # MUTATION MR9 (revert S9 to atom-only)
      Map.get(pred.attrs, :confidence, 0.5)
    end)""",
            expect=['row 13: :confidence_based picks the member with the highest string "confidence"'],
            kind="assertion",
            why=":confidence back to atom-only Map.get",
        ),
        Mutation(
            id="MR10",
            file=MCC,
            old="""  # H15 (S10): both clause shapes use the canonical accessor, so a string-keyed
  # Prediction's rationale/answer are no longer dropped.
  defp get(source, key), do: Dspy.Attrs.get(source, key)""",
            new="""  # MUTATION MR10 (revert S10 to the 3fcbea1 two-clause copy)
  defp get(%Dspy.Prediction{attrs: attrs}, key), do: Map.get(attrs, key)
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))""",
            expect=["row 14: MultiChainComparison renders a string-keyed Prediction's rationale and answer"],
            kind="assertion",
            why="the %Prediction{} clause back to Map.get(attrs, key)",
        ),
        Mutation(
            id="MR11",
            file=MAJORITY,
            old="""    if is_atom(field) and Map.has_key?(map, field) and Map.has_key?(map, to_string(field)) do
      raise ArgumentError,
            "Dspy.majority/2: completion #{inspect(map)} holds both #{inspect(field)} and " <>
              inspect(to_string(field)) <> " — pass exactly one form"
    end

    case Dspy.Attrs.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:missing, nil}
    end""",
            new="""    # MUTATION MR11 (revert S11 map clause to the 3fcbea1 atom-only read)
    if Map.has_key?(map, field) do
      {:ok, Map.get(map, field)}
    else
      {:missing, nil}
    end""",
            expect=[
                "row 15: majority over string-keyed maps with field: :answer",
                "row 16: majority mixes atom- and string-keyed maps under field: :answer into one tally",
            ],
            also=[
                'row 18: majority on a map with both :answer and "answer" raises naming both',
            ],
            kind="raise:Elixir.ArgumentError",
            why="present_value_for map clause back to Map.has_key?(map, field)",
        ),
        Mutation(
            id="MR11b",
            file=MAJORITY,
            old="""    if is_atom(field) and Map.has_key?(map, field) and Map.has_key?(map, to_string(field)) do
      raise ArgumentError,
            "Dspy.majority/2: completion #{inspect(map)} holds both #{inspect(field)} and " <>
              inspect(to_string(field)) <> " — pass exactly one form"
    end

    case Dspy.Attrs.fetch(map, field) do""",
            new="""    # MUTATION MR11b (dual-key check removed)
    case Dspy.Attrs.fetch(map, field) do""",
            expect=['row 18: majority on a map with both :answer and "answer" raises naming both'],
            kind="assertion",
            why="dual-key check removed (assert_raise fails)",
        ),
        Mutation(
            id="MR11c",
            file=MAJORITY,
            old="""  defp missing_field_error(completion, field) do
    "Dspy.majority/2: completion #{inspect(completion)} is missing field #{inspect(field)}"
  end""",
            new="""  defp missing_field_error(completion, field) do
    # MUTATION MR11c (hint text restored in the shared error builder)
    "Dspy.majority/2: completion #{inspect(completion)} is missing field #{inspect(field)}" <>
      " (maps must use atom keys, e.g. %{answer: \\"2\\"} — a string key like " <>
      inspect(to_string(field)) <> " is present but will not match)"
  end""",
            expect=[
                "row 19: majority missing-field error no longer carries the atom-keys hint",
                "row 19b: majority missing-field error names the completion and field",
            ],
            also=[],
            kind="assertion",
            why="the now-removed atom-keys hint restored in the error",
        ),
        Mutation(
            id="MS1",
            file=ATTRS,
            old="""  defp existing_key(attrs, key) when is_atom(key) do
    cond do
      Map.has_key?(attrs, key) -> key
      Map.has_key?(attrs, Atom.to_string(key)) -> Atom.to_string(key)
      true -> nil
    end
  end""",
            new="""  defp existing_key(attrs, key) when is_atom(key) do
    # MUTATION MS1 (string fallback removed: atom key → atom only)
    if Map.has_key?(attrs, key), do: key, else: nil
  end""",
            expect=[
                "row 1: answer_exact_match string-keyed example and prediction → true",
                "row 2: answer_passage_match string-keyed context → true",
                "row 4: Evaluate over a string-keyed devset scores 100.0, failures 0",
                "row 5: Default adapter renders string-keyed demo values",
                "row 6: JSON adapter renders string-keyed demo values",
                "row 8: exact_match / f1_score / contains on string keys",
                "row 9: stratified_sample groups by a string-keyed field",
                "row 10: filter_quality keyword criteria on string keys",
                'row 11: hard strategy orders by string "difficulty"',
                'row 12: uncertainty strategy uses string "uncertainty"',
                'row 13: :confidence_based picks the member with the highest string "confidence"',
                "row 14: MultiChainComparison renders a string-keyed Prediction's rationale and answer",
                "row 15: majority over string-keyed maps with field: :answer",
                "row 16: majority mixes atom- and string-keyed maps under field: :answer into one tally",
            ],
            also=[
                "Example/Prediction delegation Example.get/2 and Prediction.get/2 agree with Attrs.get/3",
                "fetch/2 returns {:ok, value} for atom or string keys",
                "get/3 atom key falls back to its string form",
                "get/3 plain maps and Example/Prediction sources all work",
                "has_key?/2 reports presence in either accepted form",
                "row 20: Example.get / Prediction.get — atom wins when both forms exist",
            ],
            kind="any",
            why="shared accessor: string fallback removed (atom key → atom only)",
        ),
        Mutation(
            id="MS2",
            file=ATTRS,
            old="""  defp existing_key(attrs, key) when is_atom(key) do
    cond do
      Map.has_key?(attrs, key) -> key
      Map.has_key?(attrs, Atom.to_string(key)) -> Atom.to_string(key)
      true -> nil
    end
  end""",
            new="""  defp existing_key(attrs, key) when is_atom(key) do
    # MUTATION MS2 (string checked before atom)
    cond do
      Map.has_key?(attrs, Atom.to_string(key)) -> Atom.to_string(key)
      Map.has_key?(attrs, key) -> key
      true -> nil
    end
  end""",
            expect=["row 20: Example.get / Prediction.get — atom wins when both forms exist"],
            also=[
                "get/3 when both forms exist, the atom key wins",
            ],
            kind="assertion",
            why="shared accessor: string checked before atom",
        ),
        Mutation(
            id="MS3",
            file=EXAMPLE,
            old="""  def get(%__MODULE__{} = example, key, default \\\\ nil), do: Dspy.Attrs.get(example, key, default)""",
            new="""  def get(%__MODULE__{} = example, key, default \\\\ nil) do
    # MUTATION MS3 (Example.get stops delegating; 3fcbea1 behavior)
    Map.get(example.attrs, key, default)
  end""",
            expect=[
                "row 9: stratified_sample groups by a string-keyed field",
            ],
            also=[
                "Example/Prediction delegation Example.get/2 and Prediction.get/2 agree with Attrs.get/3",
                "row 10: filter_quality keyword criteria on string keys",
                'row 11: hard strategy orders by string "difficulty"',
                'row 12: uncertainty strategy uses string "uncertainty"',
                "row 20: Example.get / Prediction.get — atom wins when both forms exist",
            ],
            kind="assertion",
            why="Example.get stops delegating, back to Map.get(attrs, key, default)",
        ),
    ]

    # Row 17 passes today and no mutation within this slice can turn it red:
    # it never takes the fallback path, because the field is resolved to the
    # exact "answer" key. It is a regression pin, not a proof (contract (d)).
    exempt = {
        'row 17: majority with only "answer" keys and no :field (passes today; pinned)': (
            "never takes the fallback path; the field resolves to the exact "
            '"answer" key — a regression pin, not a proof (contract (d))'
        )
    }

    h = Harness(
        mutations=mutations,
        test_files=TEST_FILES,
        acceptance_files=ACCEPTANCE_FILES,
        root=ROOT,
        exempt=exempt,
        report_path=ROOT / "plan" / "research" / "pi_handoffs" / "h15" / "mutation_report.json",
    )
    sys.exit(h.run())


if __name__ == "__main__":
    main()
