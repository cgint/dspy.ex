# M1-a — EvaluationResult + the remaining Evaluate options

Status: **DRAFT (Greta 2026-09-28)**. Clarity Gate: Horst ☐ / Greta ☐. Starts only after H0b-2 is released (Greta ticks once H0b-2 has landed and the shapes below have been re-checked against its code).
Reference: Python DSPy 3.4.0, `dspy/evaluate/evaluate.py` (class `:45-61`, options `:71-110`, `__call__` `:112-230`, row shape `:232-242`, `merge_dicts` `:310-330`, `truncate_cell` `:333-338`), and oracle tests in `tests/evaluate/test_evaluate.py`.
Queue: `PARITY_QUEUE.md` §M1 rows U008, S031. Outline: `plan/current/M1_CONTRACT_OUTLINE.md`.

## Why
Upstream returns an `EvaluationResult` with `score` (a **percentage**, rounded to 2 places) and `results` as `(example, prediction, score)` triples. It can show a table and save CSV/JSON. Ours returns a plain map with `mean` on a 0..1 scale and has none of the output options. The ported optimizers and user code will expect `score`/`results`.

## (a) Contract
### A1. Shape
`Dspy.Evaluate.evaluate/4` and `Dspy.evaluate/4` return `%Dspy.Evaluate.Result{}` (**the struct is the `EvaluationResult` equivalent**; the name follows the Elixir namespace). It has:
- **Every key produced after H0b-2, unchanged in name and value:** `mean, std, min, max, count, successes, failures, scores, predictions, items`.
- **Added:** `score :: float` = `Float.round(100 * sum(scores) / count, 2)` (upstream `:227-228`), and `results :: [{Example.t(), Prediction.t() | nil, number}]`, index-aligned with the testset, **always populated** (independent of `return_all`, as upstream).
- `@behaviour Access` (`fetch/2`, `get_and_update/3`, `pop/2`; `pop` raises `ArgumentError`, because a struct key cannot be removed). So `r[:mean]`, `r.mean`, `Map.get(r, :mean)` and `%{mean: m} = r` all keep working.
- `Inspect` shows `#Dspy.Evaluate.Result<score: 75.0, results: <4 results>>` (the upstream `__repr__` `:60-61`, in idiomatic Elixir form).
- `@type t` replaces `evaluation_result()`; `evaluation_result()` stays as an alias of `t()`.

### A2. New options on `evaluate/4` (all default off)
| Option | Upstream | Behaviour |
|---|---|---|
| `:display_progress` | `display_progress` | alias of the existing `:progress`; if both are given, `:display_progress` wins |
| `:display_table` | `display_table: bool \| int` | `true` → the whole plain-text table via `Logger.info`; integer `n` → the first n rows plus `... k more rows not displayed ...`; cells truncated to 25 words + `...` |
| `:provide_traceback` | `provide_traceback` | on an item failure, logs `Exception.format(kind, reason, stacktrace)` instead of the one-line message. The **stacktrace is captured in the child** (H0b-2 item-error value carries it) |
| `:save_as_csv` | `save_as_csv: path` | writes the rows (A3) with a header, via NimbleCSV (user "ok" 2026-09-28, still open to veto) |
| `:save_as_json` | `save_as_json: path` | writes a JSON array of the rows via Jason |
| `:metric_name` | (derived from `metric.__name__`) | column name for the score; default: the function name for `&Mod.fun/2` captures (`Function.info(f, :name)`), otherwise `"metric"` |

### A3. Row shape (the table, CSV and JSON share it; upstream `:232-242`, `merge_dicts` `:310-330`)
Each row is `Example` fields merged with `Prediction` fields; on a key collision the example key becomes `example_<k>` and the prediction key becomes `pred_<k>`; then `<metric_name> => score`. A failed item (prediction `nil`) gives the example fields plus `"prediction" => nil` plus the score. Values that are not JSON-encodable are rendered with `inspect/1` (a documented idiom deviation). Column order: example keys, then prediction keys, then the metric, each group sorted by key (deterministic; Python dicts keep insertion order — deviation, recorded).

### A4. Decisions needing a gate
- **G1 (Horst ✓):** struct name `Dspy.Evaluate.Result` rather than `Dspy.EvaluationResult`. Alternative: also add `Dspy.EvaluationResult` as the public name. Greta: one name only, `Dspy.Evaluate.Result`, with the doc mapping it to upstream.
- **G2 (USER — deviation/breaking, via Horst):** an empty testset: upstream **raises** `ValueError` (`:162-163`, test `test_evaluate_raises_on_empty_devset`); ours returns `mean 0.0`. Greta recommends **raise `ArgumentError`** (parity; returning 0.0 hides a caller bug). This is breaking for anyone who passes `[]`; internal callers (simba minibatches, cross_validate folds) must be checked for empty inputs **before** the switch. The alternative is to keep 0.0 as a documented deviation. **M1-a does not launch without this answer.** *(2026-09-28: moved into H0b-2 as open parameter Q3; M1-a inherits whatever the user decides there.)*
- **G3 (info):** `return_outputs` does not exist in our API, so there is nothing to reject.

### A5. Invariants
1. H0b-2 semantics are unchanged (failure_score, max_errors, alignment, `MaxErrorsExceeded`).
2. Teleprompters and `cross_validate`/`batch_evaluate`/`compare_results` work **unchanged**, with zero diff to their tests.
3. The options have no side effect when they are unset: no file written, no table logged.
4. `test/consumer_contract/**` and `mix.exs` stay unchanged, except the NimbleCSV dep line (the only allowed `mix.exs`/`mix.lock` change, `only`-free and runtime).

### A6. Forbidden
Hand-rolling CSV quoting; pandas-style HTML; putting `score` on a 0..1 scale; editing asserted shapes in existing tests; making `results` depend on `return_all`.

### A7. Non-goals
Callback metadata (`callback_metadata`, M3 callbacks); the class-style `Evaluate.new(devset:, metric:)` call form (idiom: options at the call site; this can be revisited if a ported optimizer needs it); IPython display.

## (b) Team card — Horst at launch.

## (c) Acceptance (each item mutation-proven; oracle = the upstream test with the same name, ported)
| # | Scenario | Mutation it catches |
|---|---|---|
| 1 | 3 of 4 score 1.0 → `score == 75.0`, `mean == 0.75` | score on a 0..1 scale → red |
| 2 | a rounding case: 2 of 3 → `66.67` | no rounding or `trunc` → red |
| 3 | `results` has length `count` and the tuple order is `(example, prediction, score)` with `return_all: false` | populated only with return_all → red |
| 4 | the four access forms `.mean`, `[:mean]`, `Map.get`, and the pattern match all work; `pop` raises | drop the Access impl → red |
| 5 | inspect output as in A1 (`test_evaluation_result_repr`) | default struct inspect → red |
| 6 | `display_table: 2` on 4 rows → 2 rows + "... 2 more rows not displayed ..."; a 30-word cell is truncated to 25 + "..." (`capture_log`) | no truncation → red |
| 7 | `save_as_json` round-trip: rows with a key collision become `example_answer`/`pred_answer`, and the metric column is named after the fn (`test_evaluate_save_as_json_with_history`) | no collision rename → red |
| 8 | `save_as_csv` with a comma, a quote and a newline in a value re-parses to identical rows (`test_evaluate_save_as_csv_with_history`) | naive `Enum.join(",")` → red |
| 9 | `provide_traceback: true` on a raising item → the log contains a stacktrace line of the raising module | message only → red |
| 10 | no options → no file is created in the tmp dir and nothing is logged at info | an always-on side effect → red |
| 11 | G2 per the user's answer (raise, or `mean 0.0` pinned) | – |
| 12 | full suite plus the consumer canary green; zero diff to existing tests | – |

## (d) Pre-mortem
1. `score` computed from `mean` after H0b-2 changed what mean includes → pinned by #1 and #6c from H0b-2, and from the same aligned `scores`.
2. The stacktrace is lost across the task boundary → #9 requires it to be captured in the child.
3. The Access impl is written but `get_and_update` is untested → #4 includes `put_in(r[:mean], x)` (allowed; it returns a struct).
4. Nondeterministic column order breaks CSV snapshots → A3 fixes the order.
5. G2 is switched without checking empty minibatches → the controller greps every internal caller and reports before the edit.

## (e) Echo-back before the first edit: A1 field list, `score` formula, A3 collision rule, the G2 answer, one sentence per A5 invariant.

## (f) `Clarity Gate: Horst ☐ <date> / Greta ☐ <date>` — requires G1 ✓, a G2 user answer, and H0b-2 released.
