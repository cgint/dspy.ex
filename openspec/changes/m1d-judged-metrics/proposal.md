# M1-d — LM-judged metrics: SemanticF1 and CompleteAndGrounded

Status: **DRAFT (Greta 2026-09-28)** — needs Horst's calls on D1–D6, then the team card and both signatures. Paper only.
Queue: `PARITY_QUEUE.md` §M1 rows **U009** (SemanticF1), **U006** (CompleteAndGrounded). Both M.
Base: `main` after the M1-a fix round. Depends on nothing in M1-b/M1-c. **Release depends on queue H12** (strict `:number` parsing) — see RULED D3.

Reference, anchored to DSPy **3.4.0** (`../dspy-3.4.0`, tag `3.4.0`):
- `dspy/evaluate/auto_evaluation.py`: `SemanticRecallPrecision` `:7-17`; `DecompositionalSemanticRecallPrecision` `:20-33`; `f1_score` (clamps both to `[0,1]`, `0.0` when both are 0) `:36-39`; `SemanticF1` (`threshold=0.66`, **`decompositional=False` by default**) `:42-62`; `AnswerCompleteness` `:68-80`; `AnswerGroundedness` `:83-99`; `CompleteAndGrounded` (`threshold=0.66`, completeness call **then** groundedness call) `:102-123`.
- Reads `example.question`, `example.response`, `pred.response` (`:59`, `:116`) and, for groundedness, `pred.context` (`:119`). **`response`, not `answer`.**
- Returns `Prediction(score=f1)` without a trace, `Prediction(score=f1 >= threshold)` with one (`:62`, `:123`). Upstream Evaluate can sum these only because `Prediction` implements `__float__`/`__add__`/`__radd__`/comparisons on its `score` field (`dspy/primitives/prediction.py:9-15`, `:53-107`).
- **Oracle:** `tests/evaluate/test_auto_evaluation.py`, 7 tests, all on `DummyLM` (no network): SemanticF1 without trace `:7-32`, with trace `:35-59`, score value 0.8/0.6 `:62-86`, CompleteAndGrounded without trace `:89-121`, with trace `:124-156`, comparison of two scores `:159-191`.

## Why
The upstream docs recommend these two for open-ended answers, where exact match is meaningless. They are the metric in the M1 exit example ("evaluate a CoT program with SemanticF1").

## (a) Contract

### A1. Signatures (prompt-bearing, ported verbatim)
Four `Dspy.Signature` modules under `Dspy.Evaluate.AutoEvaluation`: `SemanticRecallPrecision`, `DecompositionalSemanticRecallPrecision`, `AnswerCompleteness`, `AnswerGroundedness`. Field **names, order, descriptions and instructions** are upstream's, character for character (whitespace normalised the way our Signature DSL normalises instructions). Upstream `float` outputs map to our `:number` type (we have no `:float`); `str` → `:string`.

### A2. Judges and how Evaluate uses them
```elixir
Dspy.Evaluate.SemanticF1.new(threshold: 0.66, decompositional: false) :: %Dspy.Evaluate.SemanticF1{}
Dspy.Evaluate.CompleteAndGrounded.new(threshold: 0.66)             :: %Dspy.Evaluate.CompleteAndGrounded{}

# Dspy.Module:
forward(judge, %{example: Example.t(), prediction: Prediction.t()}) ::
  {:ok, %Dspy.Prediction{attrs: %{score: float}}} | {:error, term()}
parameters/1, update_parameters/2  # delegate to the inner ChainOfThought program(s), names prefixed
                                    # with upstream's attribute names: "module." / "completeness_module." / "groundedness_module."

# The metric Evaluate calls (D1):
metric(judge)           :: (Example.t(), Prediction.t() -> float)      # the F1, in [0.0, 1.0]
threshold_metric(judge) :: (Example.t(), Prediction.t() -> boolean)    # f1 >= threshold (D2)
```
Usage: `Dspy.Evaluate.evaluate(program, devset, Dspy.Evaluate.SemanticF1.metric(judge))`.

### A3. Behaviour
- **SemanticF1**: one `ChainOfThought` call on `SemanticRecallPrecision` (or the decompositional one) with `question: ex[:question], ground_truth: ex[:response], system_response: pred[:response]`; `f1(precision, recall)`.
- **CompleteAndGrounded**: two calls, **completeness first, then groundedness** (upstream order; scripted test LMs depend on it); `f1(groundedness, completeness)`.
- **`f1/2`** (private, upstream `:36-39`): clamp each input to `[0.0, 1.0]`; `0.0` if their sum is 0; else `2pr/(p+r)`. Always returns a float.
- The judge LM is whatever `Dspy.Settings` / `Dspy.context` provides; no LM is stored on the judge.

### A4. What happens when the judge answers badly (Horst's question 3)
After H0b-2 + Q2, Evaluate **raises** `InvalidMetricResult` for a metric result that is neither a number nor a boolean, while a metric that **raises** is a failed example scoring `failure_score` and counting toward `max_errors` (D-U1). Upstream: an unparseable judge answer makes the adapter raise inside the metric → the example scores `failure_score` (`evaluate.py:181`).

| Judge output | Our path | Metric does | Evaluate result |
|---|---|---|---|
| clean numbers (`0.8`, `1`, `1e-1`) | parsed | returns the clamped F1 | scored |
| out of range (`1.5`, `-0.2`) | parsed | clamps (upstream `:38`) | scored |
| `N/A`, missing field, empty | `forward` → `{:error, {:invalid_output_value \| :missing_required_outputs, …}}` (`signature.ex:270`, `:733`) | **raises** `Dspy.Evaluate.JudgeError` carrying the reason | **failed example, `failure_score`, counts toward `max_errors`** — upstream parity |
| **`80%`, `1/2`, `0.8 (high)`** | **today:** parsed leniently to `80.0`, `1.0`, `0.8` (`signature.ex:645-652`) — `80%` clamps to a perfect 1.0. **After H12 (a prerequisite of this slice):** rejected, as upstream's `parse_value` rejects them (probe) | raises | **failed example, `failure_score`** |
| `.5`, `5.`, `+0.5`, `"0.8"` (quoted), `1_000` | **today:** `.5` rejected. **After H12:** accepted, as upstream | returns the clamped F1 | scored |
| `NaN`, `inf`, `true` | upstream accepts; its clamp turns `NaN`/`inf` into a **perfect 1.0**, and `true` into 1.0. **After H12:** rejected (H12 (a)/(b), pending Horst's ruling) — BEAM floats cannot hold NaN/inf at all | raises | failed example |

The metric **never** returns `nil`, a string, a map or a `%Prediction{}`. A value that is not a number cannot reach Evaluate from these metrics, so `InvalidMetricResult` is not a path here, by construction.

### A5. Missing inputs
`ex[:question]`, `ex[:response]` or `pred[:response]` (and `pred[:context]` for groundedness) absent → the metric **raises** `ArgumentError` naming the field (upstream `AttributeError`) → failed example in Evaluate. Never a silent `""`. String-keyed examples (from DataLoader, M1-e) must work via `Example` Access (`example.ex:165-178`).

### A6. Invariants
1. No network in any test, ever: judges run against a scripted test LM (D5).
2. `Dspy.Evaluate`, `run_metric`, H0b-2/M1-a semantics: unchanged. These are new modules only.
3. The signature text (instructions, field names, descs, order) equals upstream's — pinned by a golden generated from upstream 3.4.0 (same generator as M1-b F1).
4. `test/consumer_contract/**`, `mix.exs`, `mix.lock`: unchanged.

### A7. Forbidden
Returning `%Dspy.Prediction{}` from the metric function (Evaluate raises `InvalidMetricResult`); catching the judge's `{:error, _}` and returning `0.0` (the `create_metric` anti-pattern, H5); calling the LM from the test process without a scripted LM; changing the global `:number` parser inside this slice (D3); reordering the two CompleteAndGrounded calls.

### A8. Non-goals
A trace protocol for metrics (D2); making `run_metric` unwrap `%Prediction{score:}` (D1); strict number parsing (D3); callback metadata.

## (c) Acceptance map
Tiers: **[T]** ported upstream test · **[G]** golden from running upstream 3.4.0 · **[–]** contract behaviour.

| # | Tier | Scenario | Mutation that must turn it RED |
|---|---|---|---|
| 1 | T | SemanticF1, judge answers precision 1.0 / recall 1.0 → `metric` returns `1.0`, a float (`test_semantic_f1_returns_prediction_without_trace`, reshaped per D1) | metric returns `%Prediction{}` (Evaluate would raise) |
| 2 | T | precision 0.8 / recall 0.6 → `abs(score - 0.6857) < 0.001` (`test_semantic_f1_score_value`) | arithmetic mean instead of harmonic |
| 3 | T | `threshold_metric` with threshold 0.5 on 1.0/1.0 → `true` (`…_with_trace`, reshaped per D2) | none on its own: a score of 1.0 passes *any* threshold. The threshold is pinned by row 3b |
| 3b | – | precision 0.6 / recall 0.6 (F1 0.6): `threshold: 0.5` → `true`; default threshold (0.66) → `false` | threshold ignored (default always used), or the default not 0.66 |
| 4 | T | two judged calls, 0.8/0.6 then 0.9/0.7 → second score > first (`test_semantic_f1_prediction_can_be_compared`) | metric returns a constant |
| 5 | T | CompleteAndGrounded 1.0/1.0 → `1.0` (`…_without_trace`) | none on its own: 1.0/1.0 cannot tell the two inputs apart. Pinned by row 5b |
| 5b | – | completeness 1.0, groundedness 0.5 → `abs(score - 0.6667) < 0.001` | score from completeness alone, or from groundedness alone (→ 1.0 or 0.5) |
| 6 | T | CompleteAndGrounded completeness 0.9, groundedness 0.8, threshold 0.7 → `threshold_metric` `true` (`…_with_trace`) | the two calls in the other order (the scripted answers then misparse) |
| 7 | – | **Clamp:** precision 1.5, recall −0.2 → `0.0` (clamped to 1.0 and 0.0) | no clamping (→ a value outside [0, 1]) |
| 8 | – | **Both zero:** 0 / 0 → `0.0`, no division error | unguarded division |
| 9 | – | **Unparseable judge** (`"N/A"` for recall) → the metric raises `Dspy.Evaluate.JudgeError`; **through `Dspy.Evaluate.evaluate/4`** that example scores `failure_score`, `failures == 1`, and with `max_errors: 1` it raises `MaxErrorsExceeded` | catching `{:error, _}` and returning `0.0` (the example would count as scored, not failed) |
| 10 | – | Missing `:response` on the example → `ArgumentError` naming `:response` | defaulting a missing field to `""` |
| 11 | G | The four signatures' instructions, field names, descriptions and order equal upstream 3.4.0's (golden) | any edited description or reordered field |
| 12 | – | `decompositional: true` uses the decompositional signature (the scripted LM sees its five output fields) | flag ignored |
| 13 | – | String-keyed example (`%{"question" => …, "response" => …}`) scores the same as the atom-keyed one | `Map.get(attrs, :response)` instead of Access |
| 14 | – | `parameters/1` lists the inner predictor(s) under upstream attribute names, and `update_parameters/2` round-trips them | parameters not delegated |
| 15 | – | **Public entry, the M1 exit shape:** `Dspy.Evaluate.evaluate(cot_program, devset, SemanticF1.metric(judge), max_errors: 2)` with one failing example → `failures == 1`, `failure_score` counted, a `%Dspy.Evaluate.Result{}` | – |
| 16 | – | Full suite + consumer canary green; `git diff test/` additions only; zero network (the test LM raises on any unexpected call) | – |

## (d) Pre-mortem
1. **Returns `%Prediction{score:}` from the metric** because upstream does. Every unit test on the judge passes; the first real `evaluate/4` raises `InvalidMetricResult`. → D1, rows 1 and 15.
2. **Swallows judge failures into `0.0`** "to be robust". The example then counts as *scored 0*, not *failed*, and never touches `max_errors`. → Row 9 goes through Evaluate, not the judge alone.
3. **Tests only clean numbers**, so the `80%` → `1.0` inflation never shows. → D3 makes it visible; the contract does not pin the lenient behaviour.
4. **Paraphrases the signature docstrings** while porting them. Prompt meaning drifts and no unit test notices. → Row 11, golden.
5. **Uses a mock that ignores which signature is asked**, so the decompositional flag and the call order are never really exercised. → Rows 6 and 12 require a scripted LM that answers per call and fails on an unexpected field set.
6. **Reads `:answer`** out of habit. Upstream uses `response`. → Rows 1–10 use `response`; row 10 pins the error.

## (e) Echo-back
The A2 signatures verbatim; the A4 table in own words (what raises, what scores, what fails); the call order; one sentence per A6 invariant.

## Decisions for Horst (not silent choices)
- **D1 — The metric returns a float, not a `%Prediction{}`.** Upstream's `Prediction` is summable through `__float__`/`__add__` on `score` (`prediction.py:53-107`); ours is not, and after Q2 Evaluate raises on it. Options: **(a, recommended)** `metric/1` returns the F1 float — no change to Evaluate or `run_metric`; **(b)** teach `run_metric` to unwrap `%Prediction{attrs: %{score: n}}` — true parity for *any* metric returning a scored Prediction, but it changes the H0b-2 surface shared by Evaluate and three optimizers. I recommend (a) now and booking (b) as its own decision.
- **D2 — `threshold` has no effect without a trace protocol.** Upstream only applies it when an optimizer passes `trace` (the bootstrap phase), turning the score into a boolean. Our `run_metric` never passes a trace, and our BootstrapFewShot accepts any demo with `score > 0` (`bootstrap_few_shot.ex:328`). ~~So a judge used as a bootstrap metric accepts a demo scoring 0.3, where upstream rejects it (0.3 < 0.66).~~ **CORRECTED 2026-09-28 (Greta, verified by running upstream):** that claim was wrong. Upstream's `Prediction` has `__len__` but no `__bool__`, so `Prediction(score=False)` is truthy, and upstream's bootstrap uses `success = metric_val` when no `metric_threshold` is set (`bootstrap.py:207-210`) — **so upstream accepts every judge-scored demo, whatever the score.** Only with `metric_threshold: t` does upstream filter, and then it compares the judge's *boolean* (0/1) with `t`. The full, precise divergence list is queue item **H13**. Recommendation unchanged: ship `threshold_metric/1` (boolean) as the explicit way to get "accept iff f1 ≥ threshold", and book the trace protocol separately.
- **D3 — Our `:number` parser is lenient, and it bites exactly here.** `signature.ex:645-652` accepts any numeric prefix: `"80%"` → `80.0` (then clamped to a perfect `1.0`), `"1/2"` → `1.0`, `"0.8 (high)"` → `0.8`; it rejects `".5"`, which Python accepts. (Replicated from those lines, not by calling the private function.) This is adapter-wide and pre-existing, not an M1-d defect — but M1-d is the first place it turns a malformed answer into a user-visible *score*. Recommendation: a small, separate slice **before M1-d releases**: strict, full-string float parsing compatible with Python's `float()` for number outputs, as its own behaviour change with a COMPATIBILITY note. Otherwise M1-d ships with a known inflation path, documented. Your call; the contract pins neither behaviour.
- **D4 — Where the judge's LM comes from.** Upstream uses the global LM, so the judge and the program share it unless the user sets one per module. Ours: same (Settings / `Dspy.context`). Using a different judge LM means wrapping the metric call in `Dspy.context(lm: judge_lm, …)`. Recommend: document it, no new option.
- **D5 — A shared test LM.** Upstream's oracle relies on `DummyLM` (a list of output dicts, answered in order, formatted for the adapter). We have per-file `MockLM`s and `H0b2.Support.ScriptedLM`. Recommend: M1-d adds **one shared test helper** (`test/support/dummy_lm.ex`: answers a list of output maps in order in the default adapter's wire format, records each request, and **raises on any call past the script**, which enforces the no-network invariant). M2+ will reuse it.
- **D6 — `context` as a list.** Upstream passes `pred.context` straight into a `str` field; for a list of passages its adapter renders a numbered list. Recommend: accept a binary or a list of binaries and use whatever our adapter already does for a list in a string input field; pin that rendering with a test. Parity of the rendered prompt is adapter-wide and not this slice's job.

### RULED 2026-09-28 (Horst)
- **D1 — AGREED:** `metric/1` returns the F1 float, never a `%Prediction{}` (upstream judges return `Prediction(score=...)`, which our Evaluate would reject with `InvalidMetricResult` after Q2). Making `run_metric` unwrap a scored Prediction is not part of this slice.
- **D2 — AGREED:** ship `threshold_metric/1`; the trace protocol is booked as queue **H13**, which states the divergences precisely — including the correction above (upstream accepts every judge-scored demo unless `metric_threshold` is set).
- **D3 — RULED: the parser is a live bug in shipped code and outranks M1-d.** Booked as its own slice, queue **H12**, with every case enumerated from upstream's own `parse_value`. **H12 must be released before M1-d ships**; this contract's A4 table describes behaviour *after* H12. If M1-d is built first, its unparseable-judge rows (9) must use `N/A`, which fails on both parsers, and no test may pin the lenient `80%` behaviour.
- **Row 11 golden (signature text) — generator RULED (M1-b F1):** produced by the committed `uv` generator under `plan/research/upstream_golden/`. Python is a fixture-generation tool, not a runtime dependency of the library.
- **Still OPEN:** D4 (judge LM from Settings/`Dspy.context`, documented), D5 (shared `test/support/dummy_lm.ex`), D6 (`context` as binary or list of binaries).

## (b) Team card — Horst.

## (f) Clarity Gate
- Greta ☐ — signs once D1–D6 are ruled on.
- Horst ☐
