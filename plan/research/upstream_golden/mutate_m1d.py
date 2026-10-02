#!/usr/bin/env python3
"""M1-d mutation harness (2026-09-30; fix round Lene 2026-10-01).

Proves that every key acceptance row is pinned by a test, and that each
mutation is killed FOR ITS CLAIMED REASON: every mutation names the tests it
exists to pin (`expect`); the mutation counts as killed only if ALL of those
tests fail. A mutation killed only by other tests is a hard failure
(WRONG-REASON). A run that reports failures but no parseable test names is a
hard failure (INVALID) — that is how outage-corrupted runs look.

Mutations (file -> claimed rows):
  M1   SemanticF1.metric/1 returns %Prediction{} (revert D1)  -> SF1 rows 1, 15c (InvalidMetricResult)
  M1c  CompleteAndGrounded.metric/1 returns %Prediction{}      -> CAG rows 5, 15c (InvalidMetricResult)
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
  M15  DummyLM emits fields in sorted (map-like) order (revert B2) -> SF1 row 12
  M16  SF1 caller bypasses shared f1 (own unclamped copy)       -> SF1 row 7b
  M17  CAG caller bypasses shared f1 (own unclamped copy)       -> CAG row 7
  M18  SF1 threshold >= becomes >                               -> SF1 row 3c
  M19  CAG threshold >= becomes >                               -> CAG row 6c
  M20  CAG groundedness judge given the gold answer as context  -> CAG row 6b

EXIT 0 only if every defined mutation is applied and killed for its claimed
reason. Any NOT-APPLICABLE, SURVIVED, WRONG-REASON or INVALID -> exit 1.
ENFILE / "too many open files" in any run -> abort immediately (exit 2).

Originals are held in memory and restored in try/finally; SIGTERM/SIGHUP are
turned into exceptions so the finally block runs on a kill.

Usage: python3 plan/research/upstream_golden/mutate_m1d.py
"""

import re
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
EV = ROOT / "lib" / "dspy" / "evaluate"
SEMANTIC_F1 = EV / "semantic_f1.ex"
CAG = EV / "complete_and_grounded.ex"
JUDGE_SCORE = EV / "judge_score.ex"
DUMMY_LM = ROOT / "test" / "support" / "dummy_lm.ex"
MUTATED_FILES = (SEMANTIC_F1, CAG, JUDGE_SCORE, DUMMY_LM)

# Every test file of the slice (an omitted file is a false-zero source).
TEST_DIR = ROOT / "test" / "dspy" / "evaluate"

SF1T = "Dspy.Evaluate.SemanticF1Test"
CAGT = "Dspy.Evaluate.CompleteAndGroundedTest"

_SNAPSHOTS = {}


class Interrupted(Exception):
    pass


def _on_signal(signum, _frame):
    raise Interrupted(f"signal {signum}")


def snapshot_all():
    for f in MUTATED_FILES:
        _SNAPSHOTS[f] = f.read_text()


def restore_all():
    for f, content in _SNAPSHOTS.items():
        f.write_text(content)


def detect_leftovers():
    """Refuse to start if the tree carries debris from a killed prior run."""
    issues = []
    for f in MUTATED_FILES:
        if "MUTATION" in f.read_text():
            issues.append((f, "MUTATION marker present"))
    return issues


TEST_RE = re.compile(r"^\s+\d+\) test (.+) \((Dspy\.[\w.]+)\)\s*$", re.MULTILINE)


def run_tests():
    test_files = sorted(str(p.relative_to(ROOT)) for p in TEST_DIR.glob("*_test.exs"))
    result = subprocess.run(
        ["mix", "test", *test_files], capture_output=True, text=True, cwd=str(ROOT)
    )
    out = result.stdout + result.stderr
    if "ENFILE" in out or "too many open files" in out.lower() or "file table overflow" in out:
        print("ABORT: ENFILE / too many open files seen in test output. Stop and escalate.")
        print(out[-1500:])
        raise SystemExit(2)
    failed = [(mod, name) for name, mod in TEST_RE.findall(out)]
    return result.returncode, out, failed


def failure_block(out, mod, name):
    """The ExUnit failure text for one test (for reason checks)."""
    header = f") test {name} ({mod})"
    i = out.find(header)
    if i < 0:
        return ""
    j = re.search(r"^\s+\d+\) test ", out[i + len(header):], re.MULTILINE)
    return out[i: i + len(header) + (j.start() if j else 2000)]


def base_green_check():
    code, out, failed = run_tests()
    if code != 0 or failed:
        print(f"BASE-GREEN CHECK FAILED (exit {code}): {failed}")
        print(out[-2000:])
        sys.exit(1)
    m = re.search(r"Result:\s+(\d+) passed", out) or re.search(r"(\d+) tests?, 0 failures", out)
    print(f"Base tests green: {m.group(0) if m else '(count line not found)'}")


# (name, file, old, new, desc, expect=[(module, row-prefix)],
#  reason=None | (module, row-prefix, substring that must appear in that test's failure text))
MUTATIONS = [
    (
        "M1",
        SEMANTIC_F1,
        """      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      score
    end
  end

  @doc \"\"\"
  Return a threshold metric""",
        """      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      # MUTATION M1
      Dspy.Prediction.new(%{score: score})
    end
  end

  @doc \"\"\"
  Return a threshold metric""",
        "SemanticF1.metric/1 returns %Prediction{} (revert D1)",
        [(SF1T, "row 1:"), (SF1T, "row 15c:")],
        (SF1T, "row 15c:", "InvalidMetricResult"),
    ),
    (
        "M1c",
        CAG,
        """      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      score
    end
  end

  @doc \"\"\"
  Return a threshold metric""",
        """      {:ok, %{score: score}} = forward(judge, %{example: example, prediction: prediction})
      # MUTATION M1c
      Dspy.Prediction.new(%{score: score})
    end
  end

  @doc \"\"\"
  Return a threshold metric""",
        "CompleteAndGrounded.metric/1 returns %Prediction{} (revert D1)",
        [(CAGT, "row 5:"), (CAGT, "row 15c:")],
        (CAGT, "row 15c:", "InvalidMetricResult"),
    ),
    (
        "M2",
        JUDGE_SCORE,
        "      2.0 * x * y / (x + y)",
        "      # MUTATION M2\n      (x + y) / 2.0",
        "shared f1: arithmetic mean instead of harmonic",
        [(SF1T, "row 2:")],
        None,
    ),
    (
        "M3",
        JUDGE_SCORE,
        "do: max(0.0, min(1.0, value * 1.0))",
        "do: max(0.0, min(1.5, value * 1.0)) # MUTATION M3",
        "shared clamp: upper bound 1.5",
        [(SF1T, "row 7b:"), (CAGT, "row 7:")],
        None,
    ),
    (
        "M3b",
        JUDGE_SCORE,
        "do: max(0.0, min(1.0, value * 1.0))",
        "do: max(-1.0, min(1.0, value * 1.0)) # MUTATION M3b",
        "shared clamp: lower bound -1.0",
        [(SF1T, "row 7:")],
        None,
    ),
    (
        "M4",
        JUDGE_SCORE,
        """    if x + y == 0.0 do
      0.0
    else
      2.0 * x * y / (x + y)
    end""",
        """    # MUTATION M4
    2.0 * x * y / (x + y)""",
        "shared f1: drop the sum == 0 guard",
        [(SF1T, "row 8:")],
        (SF1T, "row 8:", "ArithmeticError"),
    ),
    (
        "M5",
        CAG,
        """    completeness =
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
        """    # MUTATION M5
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
        "CAG: groundedness call first",
        [(CAGT, "row 6b:")],
        None,
    ),
    (
        "M6",
        CAG,
        "    score = JudgeScore.f1(groundedness_value, completeness_value)",
        "    # MUTATION M6\n    score = completeness_value * 1.0",
        "CAG: score from completeness alone",
        [(CAGT, "row 5b:")],
        None,
    ),
    (
        "M7",
        SEMANTIC_F1,
        "    threshold = Keyword.get(opts, :threshold, 0.66)",
        "    # MUTATION M7\n    threshold = 0.66",
        "SF1: ignore the threshold option",
        [(SF1T, "row 3b:")],
        None,
    ),
    (
        "M8",
        CAG,
        "    threshold = Keyword.get(opts, :threshold, 0.66)",
        "    # MUTATION M8\n    threshold = 0.66",
        "CAG: ignore the threshold option",
        [(CAGT, "row 6d:")],
        None,
    ),
    (
        "M9",
        SEMANTIC_F1,
        """      :error -> raise ArgumentError, "missing #{label}\"""",
        """      :error -> "" # MUTATION M9""",
        "SF1: missing field defaults to \"\"",
        [(SF1T, "row 10:")],
        None,
    ),
    (
        "M10",
        SEMANTIC_F1,
        """    value = Access.fetch(container, field)
""",
        """    # MUTATION M10
    value = Map.fetch(container.attrs, field)
""",
        "SF1: Map.fetch on attrs instead of Access (string keys break)",
        [(SF1T, "row 13:")],
        None,
    ),
    (
        "M11",
        SEMANTIC_F1,
        """  def parameters(%__MODULE__{} = judge) do
    judge.module
    |> Dspy.Module.parameters()""",
        """  def parameters(%__MODULE__{} = judge) do
    # MUTATION M11
    _ = judge
    []""",
        "SF1: parameters/1 returns []",
        [(SF1T, "row 14:")],
        None,
    ),
    (
        "M12",
        SEMANTIC_F1,
        """      {:error, reason} ->
        raise JudgeError, reason: reason, raw_answer: JudgeScore.raw_output(reason)""",
        """      {:error, _reason} ->
        # MUTATION M12
        {:ok, %{score: 0.0}}""",
        "SF1: swallow {:error, _} into 0.0 (H5)",
        [(SF1T, "row 9:"), (SF1T, "row 15:")],
        None,
    ),
    (
        "M13",
        SEMANTIC_F1,
        "raise JudgeError, reason: reason, raw_answer: JudgeScore.raw_output(reason)",
        "raise JudgeError, reason: reason, raw_answer: nil # MUTATION M13",
        "SF1: raw_answer not filled from the reason (revert B1)",
        [(SF1T, "row 9b:")],
        None,
    ),
    (
        "M14",
        CAG,
        "raise JudgeError, reason: reason, raw_answer: JudgeScore.raw_output(reason)",
        "raise JudgeError, reason: reason, raw_answer: nil # MUTATION M14",
        "CAG: raw_answer not filled from the reason (revert B1)",
        [(CAGT, "row 9b:")],
        None,
    ),
    (
        "M15",
        DUMMY_LM,
        """    entry
    |> Enum.map(fn {field, value} ->""",
        """    entry
    # MUTATION M15
    |> Enum.sort()
    |> Enum.map(fn {field, value} ->""",
        "DummyLM emits fields in sorted (map-like) order (revert B2)",
        [(SF1T, "row 12:")],
        None,
    ),
    (
        "M16",
        SEMANTIC_F1,
        "        score = JudgeScore.f1(precision, recall)",
        "        # MUTATION M16\n        score = 2.0 * precision * recall / (precision + recall)",
        "SF1 caller bypasses the shared f1 (unclamped local copy)",
        [(SF1T, "row 7b:")],
        None,
    ),
    (
        "M17",
        CAG,
        "    score = JudgeScore.f1(groundedness_value, completeness_value)",
        "    # MUTATION M17\n    score = 2.0 * groundedness_value * completeness_value / (groundedness_value + completeness_value)",
        "CAG caller bypasses the shared f1 (unclamped local copy)",
        [(CAGT, "row 7:")],
        None,
    ),
    (
        "M18",
        SEMANTIC_F1,
        "      score >= judge.threshold",
        "      score > judge.threshold # MUTATION M18",
        "SF1 threshold: >= becomes >",
        [(SF1T, "row 3c:")],
        None,
    ),
    (
        "M19",
        CAG,
        "      score >= judge.threshold",
        "      score > judge.threshold # MUTATION M19",
        "CAG threshold: >= becomes >",
        [(CAGT, "row 6c:")],
        None,
    ),
    (
        "M20",
        CAG,
        """        retrieved_context: retrieved_context,
        system_response: system_response""",
        """        retrieved_context: ground_truth, # MUTATION M20
        system_response: system_response""",
        "CAG: groundedness judge given the gold answer instead of the context",
        [(CAGT, "row 6b:")],
        None,
    ),
]


def main():
    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGHUP, _on_signal)

    print(f"Mutation harness: {len(MUTATIONS)} patterns defined")
    snapshot_all()

    leftovers = detect_leftovers()
    if leftovers:
        for f, reason in leftovers:
            print(f"LEFTOVER DETECTED: {f}: {reason}")
        print("Refusing to start: the tree carries debris from a prior run.")
        sys.exit(1)

    base_green_check()

    applied, killed = 0, 0
    survived, not_applicable, wrong_reason, invalid = [], [], [], []

    try:
        for name, file, old, new, desc, expect, reason in MUTATIONS:
            content = file.read_text()
            if content.count(old) != 1:
                print(f"NOT-APPLICABLE: {name} ({desc}): old_text found {content.count(old)}x in {file.name}")
                not_applicable.append(name)
                continue

            file.write_text(content.replace(old, new, 1))
            applied += 1
            print(f"APPLIED: {name} ({desc})")
            try:
                code, out, failed = run_tests()
            finally:
                file.write_text(_SNAPSHOTS[file])

            names = [f"{m.split('.')[-1]}::{n}" for m, n in failed]
            if code == 0 and not failed:
                survived.append(name)
                print(f"  SURVIVED: {name} — all tests passed")
                continue
            if not failed:
                invalid.append(name)
                print(f"  INVALID: {name} — exit {code} but no failing test name parsed")
                print("  " + out[-800:].replace("\n", "\n  "))
                continue

            missing = [
                (m, p) for m, p in expect
                if not any(fm == m and fn.startswith(p) for fm, fn in failed)
            ]
            bad_reason = []
            if reason and not missing:
                rm, rp, rs = reason
                for fm, fn in failed:
                    if fm == rm and fn.startswith(rp) and rs not in failure_block(out, fm, fn):
                        bad_reason.append(f"{fm.split('.')[-1]}::{fn} lacks {rs!r}")
            if missing or bad_reason:
                wrong_reason.append(name)
                print(f"  WRONG-REASON: {name} — expected {expect} (reason {reason!r}); "
                      f"missing {missing}, reason absent in {bad_reason}; failed: {names}")
            else:
                killed += 1
                extra = [n for (m, fn), n in zip(failed, names)
                         if not any(m == em and fn.startswith(ep) for em, ep in expect)]
                claimed = [m.split(".")[-1] + "::" + p for m, p in expect]
                print(f"  KILLED: {name} — claimed {claimed} failed; also failed: {extra}")
    except Interrupted as e:
        print(f"INTERRUPTED by {e}; restoring sources.")
        restore_all()
        sys.exit(1)
    finally:
        restore_all()

    print(f"\n{'=' * 60}\nMUTATION HARNESS REPORT\n{'=' * 60}")
    print(f"Patterns defined:  {len(MUTATIONS)}")
    print(f"Mutations applied: {applied}")
    print(f"Killed (claimed reason): {killed}")
    print(f"Survived:          {len(survived)} {survived or ''}")
    print(f"Wrong reason:      {len(wrong_reason)} {wrong_reason or ''}")
    print(f"Invalid:           {len(invalid)} {invalid or ''}")
    print(f"NOT-APPLICABLE:    {len(not_applicable)} {not_applicable or ''}")

    if not_applicable or survived or wrong_reason or invalid or killed != len(MUTATIONS):
        print("\nHARD FAILURE.")
        sys.exit(1)
    print(f"\nALL CLEAR: {killed}/{len(MUTATIONS)} killed for their claimed reason.")
    sys.exit(0)


if __name__ == "__main__":
    main()
