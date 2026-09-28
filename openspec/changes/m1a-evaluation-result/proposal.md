# M1-a — EvaluationResult + the remaining Evaluate options

Status: **SIGN-OFF QUALITY on paper (Greta 2026-09-28, rev 2)**. Based on the H0b-2 base semantics as reviewed at `deab721` (D-U1: failed items score `failure_score` in the mean; `MaxErrorsExceeded`; booleans → 1.0/0.0). Open parameters: **P-Q3** (follows the user's H0b-2 Q3 answer) and **P-OUT** (user, see A4). Launch only after H0b-2 is released.
Reference (re-verified against the 3.4.0 source 2026-09-28): `dspy/evaluate/evaluate.py`: `EvaluationResult` `:48-61` (repr `:60-61`); `__init__` options `:71-114` (`return_outputs` → ValueError `:113-114`); `__call__` `:116-230`; empty devset raise `:157-158`; failed item → `(dspy.Prediction(), failure_score)` `:181`; sum `:183`; `Average Metric` info log `:185`; table `:187-196`, `:268-300`; CSV `:198-212` (header = keys of the **first** row); JSON `:213-224` (`json.dump`, no default encoder); `score=round(100*ncorrect/ntotal, 2)` `:227`; rows `:232-242`; `prediction_is_dictlike` `:304-307`; `merge_dicts` `:310-330`; `truncate_cell` `:333-338`, and oracle tests in `tests/evaluate/test_evaluate.py`.
Queue: `PARITY_QUEUE.md` §M1 rows U008, S031. Outline: `plan/current/M1_CONTRACT_OUTLINE.md`.

## Why
Upstream returns an `EvaluationResult` with `score` (a **percentage**, rounded to 2 places) and `results` as `(example, prediction, score)` triples. It can show a table and save CSV/JSON. Ours returns a plain map with `mean` on a 0..1 scale and has none of the output options. The ported optimizers and user code will expect `score`/`results`.

## (a) Contract
### A1. Shape
`Dspy.Evaluate.evaluate/4` and `Dspy.evaluate/4` return `%Dspy.Evaluate.Result{}` (**the struct is the `EvaluationResult` equivalent**; the name follows the Elixir namespace). It has:
- **Every key produced after H0b-2, unchanged in name and value:** `mean, std, min, max, count, successes, failures, scores, predictions, items`.
- **Added:** `score :: float` = `Float.round(100 * Enum.sum(scores) / count, 2)` computed from the **unrounded** aligned `scores` (they already contain `failure_score` for failed items, D-U1; upstream `:181-183`, `:227`). Never derived from a rounded `mean`.
- **Added:** `results :: [{Example.t(), Prediction.t(), number}]`, index-aligned with the testset, **always populated** (independent of `return_all`, as upstream). A failed item is `{example, %Dspy.Prediction{} (empty), failure_score}`, exactly as upstream `:181`. The existing `predictions`/`items` fields keep their H0b-2 meaning (`nil` for a failure, gated by `return_all`); invariant A5.1.
- `@behaviour Access` (`fetch/2`, `get_and_update/3`, `pop/2`; `pop` raises `ArgumentError`, because a struct key cannot be removed). So `r[:mean]`, `r.mean`, `Map.get(r, :mean)` and `%{mean: m} = r` all keep working.
- `Inspect` shows `#Dspy.Evaluate.Result<score: 100.0, results: <list of 1 results>>` (upstream `__repr__` `:60-61` = `EvaluationResult(score=100.0, results=<list of 1 results>)`; same content, Elixir form; the odd plural is kept for parity).
- `@type t` replaces `evaluation_result()`; `evaluation_result()` stays as an alias of `t()`.

### A2. New options on `evaluate/4` (all default off)
| Option | Upstream | Behaviour |
|---|---|---|
| `:display_progress` | `display_progress` | alias of the existing `:progress`; if both are given, `:display_progress` wins |
| `:display_table` | `display_table: bool \| int` | `true` → the whole plain-text table via `Logger.info`; integer `n` → the first n rows plus `... k more rows not displayed ...` (upstream `:278-300`); cells over 25 words → first 25 + `...` (`:333-338`); `0` → header only plus the "more rows" line (upstream TODO `:401` notes the same quirk) |
| `:provide_traceback` | `provide_traceback` | on an item failure, logs `Exception.format(kind, reason, stacktrace)` instead of the one-line message. **Scope note (verified at `deab721`): H0b-2 does NOT capture the stacktrace** (`evaluate.ex` has no `__STACKTRACE__`). M1-a captures it in the child and carries it **only in the log path** (or an additive field); the H0b-2 `items[i].error` tuples stay byte-identical (their tests must not change) |
| `:save_as_csv` | `save_as_csv: path` | writes the rows (A3) with a header, via NimbleCSV (user "ok" 2026-09-28, still open to veto) |
| `:save_as_json` | `save_as_json: path` | writes a JSON array of the rows via Jason |
| `:metric_name` | (derived: `metric.__name__` for functions, class name otherwise, `:190`, `:199-203`) | column name for the score; default: the function name for `&Mod.fun/2` captures (`Function.info(f, :name)`), otherwise `"metric"` (anonymous fns have no useful name) |
| – | `Average Metric` log `:185` | **always** logs `Average Metric: <sum> / <n> (<pct>%)` at `:info`, pct rounded to 1 place — parity, not optional |

### A3. Row shape (the table, CSV and JSON share it; upstream `:232-242`, `merge_dicts` `:310-330`)
Each row is `Example` fields merged with `Prediction` fields; on a key collision the example key becomes `example_<k>` and the prediction key becomes `pred_<k>`; then `<metric_name> => score`. A failed item carries an empty `Prediction`, which is dict-like (`:304-307`), so its row is **the example fields plus the metric only** (merge with an empty map; upstream `:237`). Column order: example keys, then prediction keys, then the metric, each group sorted by key — Python keeps dict insertion order, but our `Example`/`Prediction` attrs are maps with no order, so sorting is forced by the data structure (documented, not a choice). Non-encodable values and ragged rows: see P-OUT.

### A4. Decisions needing a gate
- **G1 (Horst ✓):** struct name `Dspy.Evaluate.Result` rather than `Dspy.EvaluationResult`. Alternative: also add `Dspy.EvaluationResult` as the public name. Greta: one name only, `Dspy.Evaluate.Result`, with the doc mapping it to upstream.
- **P-Q3 (parameter; was G2) — follows the user's H0b-2 Q3 answer.** If *yes*: already implemented in H0b-2 (`4b8aaa0`); M1-a only ports the oracle `test_evaluate_raises_on_empty_devset` (`match: "devset"`). If *no*: M1-a pins `evaluate(p, [], m)` → `score 0.0, results [], mean 0.0` and records the deviation. *History:*  an empty testset: upstream **raises** `ValueError` (`:162-163`, test `test_evaluate_raises_on_empty_devset`); ours returns `mean 0.0`. Greta recommends **raise `ArgumentError`** (parity; returning 0.0 hides a caller bug). This is breaking for anyone who passes `[]`; internal callers (simba minibatches, cross_validate folds) must be checked for empty inputs **before** the switch. The alternative is to keep 0.0 as a documented deviation. **M1-a does not launch without this answer.** *(2026-09-28: moved into H0b-2 as open parameter Q3; M1-a inherits whatever the user decides there.)*
- **G3 (info):** upstream raises on the removed `return_outputs` kwarg (`:113-114`). Our keyword opts never had it; unknown opts are ignored today. Nothing to port.
- **P-OUT (USER — two small deviations where upstream crashes; batch into one question):** (i) CSV header: upstream takes the keys of the **first** row, so a later row with extra keys makes `DictWriter` raise `ValueError`. Recommended: header = the union of all row keys, missing cells empty. (ii) JSON: upstream `json.dump` raises `TypeError` on a non-serializable value. Recommended: render such values with `inspect/1`. Alternative for both: match upstream and raise. Build each behind its default in its own commit (same rule as H0b-2 Q2/Q3).
- **Dep (Horst, dependency owner):** NimbleCSV — `00_NOW` records it as "read as yes, say if not". Horst confirms before launch; it is the only allowed `mix.exs`/`mix.lock` change.

### A5. Invariants
1. H0b-2 semantics are unchanged (failure_score, max_errors, alignment, `MaxErrorsExceeded`).
2. Teleprompters and `cross_validate`/`batch_evaluate`/`compare_results` work **unchanged**, with zero diff to their tests.
3. The options have no side effect when they are unset: no file written, no table logged. The single `Average Metric` info line (parity, `:185`) is the only log output.
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
| 10 | no options → no file is created in the tmp dir; the only info log line is `Average Metric: 3.0 / 4 (75.0%)` | an always-on side effect, or a missing Average Metric line → red |
| 10b | a failed item (raising program): `results` entry is `{ex, %Prediction{}, 0.0}`; its CSV/JSON row = example fields + metric, no `prediction` key; `predictions[i]` is still `nil` | `nil` in results, or a `prediction` column → red |
| 10c | P-OUT per the user's answer (ragged rows; a PID value in JSON) | – |
| 11 | P-Q3 per the user's answer (raise with `devset` in the message, or `score 0.0` pinned) | – |
| 12 | full suite plus the consumer canary green; zero diff to existing tests | – |

## (d) Pre-mortem
1. `score` computed from `mean` after H0b-2 changed what mean includes → pinned by #1 and #6c from H0b-2, and from the same aligned `scores`.
2. The stacktrace is lost across the task boundary → #9 requires it to be captured in the child.
3. The Access impl is written but `get_and_update` is untested → #4 includes `put_in(r[:mean], x)` (allowed; it returns a struct).
4. Nondeterministic column order breaks CSV snapshots → A3 fixes the order.
5. P-Q3: the internal-caller audit and Ensemble guard were already done in H0b-2 (`4f084b8`, `deab721`); M1-a adds no new `evaluate` callers.
6. `score` and `mean` drift apart → #1/#2 assert both from the same fixture; `score == Float.round(mean*100, 2)` holds only up to float error, so tests compare against the formula, not against `mean`.

## (e) Echo-back before the first edit: A1 field list, `score` formula, the failed-item triple, A3 collision rule, the P-Q3/P-OUT answers, one sentence per A5 invariant.

## (f) Clarity Gate
- `Greta ✓ 2026-09-28` for everything **except P-Q3 and P-OUT** (☐, pending user). Launch additionally requires H0b-2 released and Horst's NimbleCSV confirmation.
- Horst ☐.

## (g) Side findings for H0b-2 (cite hygiene, no behaviour change)
- The H0b-2 Q3 code comment and COMPATIBILITY cite `evaluate.py:162-163`; the 3.4.0 raise is at **`:157-158`**. Upstream message: `"devset must contain at least one example, got an empty devset."`; ours lacks the suffix (the oracle only matches `devset`, fine).
- The boolean-parity cite `evaluate.py:182` should be **`:183`** (the sum); `:181` is the failure fill.
