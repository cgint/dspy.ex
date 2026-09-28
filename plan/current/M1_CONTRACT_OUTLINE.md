# M1 "Evaluation you can trust" — contract OUTLINE (Greta draft 2026-09-28)

Status: **OUTLINE, not a Clarity-Gate contract.** When H0b-2 has landed it becomes `openspec/changes/m1-evaluation/` (proposal + specs, with `openspec validate` green); Horst adds the team card.
Reference: Python DSPy 3.4.0 (`../dspy-3.4.0/dspy/evaluate/`, `datasets/`, `predict/aggregation.py`). Queue: `PARITY_QUEUE.md` §M1 (10 items, 17 pts).
**After M1 you can** measure your program reliably: failed examples count against the score as in Python, results can be saved and shown as a table, and standard metrics and data loaders are ready to use.

## Precondition (from H0b-2, NOT part of M1)
`failure_score` and `max_errors` (setting default 10, `MaxErrorsExceeded`), per-item isolation, alignment. M1 builds on these and must not re-open them.

## Slices (proposal; order follows the dependencies)
| Slice | Items | Upstream (3.4.0) | Size |
|---|---|---|---|
| M1-a | **EvaluationResult** (U008) + remaining Evaluate options (S031): `provide_traceback`, `save_as_csv`, `save_as_json`, `display_table`, `display_progress` | `evaluate/evaluate.py:45-60` (class), `:74-110` (ctor) | M |
| M1-b | Metrics: `answer_exact_match(frac, answers list)` (U010), `answer_passage_match` (U011), public `normalize_text` (U012), `EM`/`F1` over answers lists | `evaluate/metrics.py:11-39, 87-125, 273-320` | S |
| M1-c | `Dspy.majority` (S044): most common completion per field, ties go to the earlier completion, `normalize` returning nil means ignore | `predict/aggregation.py:9-` | S |
| M1-d | LM-judged metrics `SemanticF1(threshold 0.66, decompositional)` (U009), `CompleteAndGrounded(threshold 0.66)` (U006) as `Dspy.Module`s using their upstream signatures | `evaluate/auto_evaluation.py:7-120` | M |
| M1-e | `Dspy.Dataset` base (train/dev/test, `shuffle_and_sample`, seeds) (U003) + `Dspy.DataLoader.from_csv/from_json` (U002, local files only) | `datasets/dataset.py`, `datasets/dataloader.py` | M |

## Pinned decisions (proposed; Horst ✓ needed)
1. **EvaluationResult shape.** The upstream fields are `score` (**a percentage**, e.g. 67.30) and `results: [(example, prediction, score)]`. Ours: `%Dspy.Evaluate.Result{}` with `@behaviour Access` keeps **every current key** (`mean`, `std`, `count`, `items`, `scores`, `predictions`, …) and **adds** `score` (= mean×100, rounded to 2 as upstream) and `results` (a list of `{example, prediction, score}`). Non-breaking in practice (checked 2026-09-26: 0 consumer uses, no Access/`==` reads). Test one per old access pattern: `.mean`, `[:mean]`, `Map.get`, `%{mean: m}`.
2. **`display_table`** renders a plain-text table to Logger/IO. There is no pandas or HTML (an idiom, recorded as such).
3. **DataLoader scope.** CSV/JSON from local files. `from_huggingface`, `from_pandas`, `from_parquet` and `from_rm` stay in the M7+ pool (they need deps). CSV parsing: **dependency decision** — NimbleCSV (new dep, needs a handshake) or a minimal RFC-4180 parser in-repo. Checked 2026-09-28: NimbleCSV is **not** locked; `mix.lock` mentions it only as an optional dep of `req`. So it would be a **new dependency** and needs the user handshake. Alternative: a minimal in-repo RFC-4180 reader, with tests for quotes and embedded commas and newlines.
4. `save_as_csv`/`save_as_json` write to the path given; JSON via Jason (already a dep).
5. LM-judged metrics use the configured LM. Tests use DummyLM/fake adapters only; no network.

## Invariants
- The Evaluate success path's current keys and values stay unchanged (except `score`/`results`, which are added).
- H0b-2 semantics are untouched (failure_score, max_errors, alignment, `MaxErrorsExceeded`).
- No Python runtime. No new dep without the handshake (item 3).
- Teleprompters that read Evaluate results (`.mean`) keep working, and their tests stay unchanged.

## Acceptance sketch (each item mutation-proven)
- EvaluationResult: `score == Float.round(mean*100, 2)`; `results` aligned with the testset; all four old access patterns work. Mutation: drop the Access impl → the `[:mean]` test goes red.
- `answer_exact_match` with `frac: 0.5` and a list of answers matches upstream examples (port upstream `tests/evaluate/test_metrics.py` cases as the oracle).
- `majority`: tie → the earlier completion; nil-normalized completions are ignored (port upstream `tests/predict/test_aggregation.py`).
- SemanticF1: with a DummyLM returning fixed recall/precision → the expected F1 and threshold decision.
- DataLoader: a CSV fixture → examples with `with_inputs` set; the seeded `shuffle_and_sample` is deterministic.
- **Exit example** (`examples/m1_evaluation.exs`, offline): DataLoader CSV → CoT program → Evaluate with SemanticF1, `max_errors: 2` and one failing example → `failure_score` counted, `%Result{}` printed as a table, JSON saved. The canary stays green.

## Pre-mortem (top risks)
1. `score` as 0..1 instead of a percentage → an explicit test pins `67.3`-style values.
2. Metrics "ported" without upstream test cases → the upstream tests are required as the oracle.
3. The DataLoader silently grows HF/pandas scope → forbidden in M1.
4. The struct change edits teleprompter tests to pass → `git diff test/` shows additions only.

## Decided (Horst 2026-09-28)
- **CSV:** NimbleCSV recommended to the user, answer pending. **The CSV part of M1-e is blocked** until then; JSON can go ahead.
- **Sequencing:** one lib-editing team at a time. M1-b/c come right after the H0b-1 release, before or alongside H0b-2 in sequence; Horst decides at that point. No parallel start.
- The team card is written by Horst at M1 launch.
