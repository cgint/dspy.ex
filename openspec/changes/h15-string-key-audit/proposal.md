# H15 — String-key audit: one canonical accessor for `attrs`

Status: **DRAFT, locked-ready (Greta 2026-10-02)** — needs Horst's rulings **R1–R5** below. Paper only.
Base: `main` at `3fcbea1` (v0.4.4 + H20 stage 1). Queue: `PARITY_QUEUE.md` H15, ruled T3/T4 (Horst 2026-09-30). **Must land before M1-e.**
Harness: **first slice built on `plan/research/harness/mutlib.py` from the start.** Every acceptance row below is a test name that some declared `Mutation(expect=…, kind=…)` must claim. Anything unclaimed fails the run (C3a).

## Why
- `attrs` maps hold atom keys when built in code and string keys when loaded from JSON, CSV or a dataset.
- Two shipped bugs come from reading only the atom key, and both were **re-verified today** on `3fcbea1`:
  - **P1 (loud):** `Dspy.Metrics.answer_exact_match/2,3` and `answer_passage_match/2` read `Map.fetch(attrs, :answer | :context)` (`metrics.ex:140,209`). A string-keyed example raises `"example[:answer] is missing"`. In `Evaluate`, every loaded example therefore scores `failure_score`.
  - **P2 (silent, worst):** `Signature` renders a demo through `format_fields/2` → `Map.get(example.attrs || example, field.name, "")` (`signature.ex:480`), which the Default and JSON adapters reach through `to_prompt` (`:108`). Re-running `plan/research/m1e-refresh-2026-09-30/demo_probe*.exs` today gives:

    | Adapter | String-keyed demo in prompt |
    |---|---|
    | Default | **false** |
    | JSON | **false** |
    | Chat | true (it uses `Example.get/2`) |

    A few-shot optimiser on a loaded trainset trains on **blank demos** and reports nothing.
- The library **already** has the right rule (atom → string fallback), in two private copies: `existing_key/2` in `example.ex:199` and `prediction.ex:203`. Four more call sites reimplement it by hand. That is the H12 "several copies" lesson, so the fix routes **every site through one function**, rather than adding a 13th copy.

## (a) Contract

### A1. The canonical accessor (R1)
A new internal module `Dspy.Attrs` (`@moduledoc false`) provides `get(source, key, default \\ nil)`, `fetch(source, key)` and `has_key?(source, key)`.
- **Sources:** `%Dspy.Example{}`, `%Dspy.Prediction{}` (their `attrs`), and plain maps.
- **Key rule:** exactly today's `existing_key/2`, moved and not changed:
  - an atom key finds the atom key first, then its string form;
  - a string key finds only that exact string (no atom is ever created);
  - **when both `:k` and `"k"` exist, the atom wins** (R2).
- `Dspy.Example.get/fetch` and `Dspy.Prediction.get/fetch` **delegate** to it. Both private `existing_key/2` copies are deleted, and `key_for_put` calls the shared function.

### A2. Sites
Each site is routed through `Dspy.Attrs`, and the public behaviour of each is pinned.

| # | Site (today) | Public entry | Today with string keys | After |
|---|---|---|---|---|
| S1 | `metrics.ex:209` `fetch_field!/2` (P1) | `Metrics.answer_exact_match/2,3` | raises "missing" | scores; a missing key **in both forms** still raises the same message |
| S2 | `metrics.ex:140` `fetch_context!/2` (P1) | `Metrics.answer_passage_match/2` | raises | scores; missing still raises |
| S3 | `signature.ex:480` `format_fields/2` (P2) | `Dspy.Module.forward/2` with `Predict` demos, Default and JSON adapters | **blank values** | values rendered; atom-keyed prompts byte-identical |
| S4 | `metrics.ex:526,530` `get_field_value/2` (copy) | `Metrics.exact_match/3`, `f1_score/3`, `contains/3` | works | works; copy deleted |
| S5 | `trainset.ex:207` (copy) | `Trainset.stratified_sample/3` | works | works; copy deleted |
| S6 | `trainset.ex:257` (copy) | `Trainset.filter_quality/2` (keyword criteria) | works | works; copy deleted |
| S7 | `trainset.ex:414` `hard_sample` | `Trainset.sample/3`, hard strategy | `"difficulty"` ignored → 0.5 | read |
| S8 | `trainset.ex:440` `uncertainty_sample` | `Trainset.sample/3`, uncertainty strategy | `"uncertainty"` ignored → 0.5 | read |
| S9 | `ensemble.ex:193` | `Teleprompt.Ensemble.forward/2`, `strategy: :confidence_based` | `"confidence"` ignored → 0.5 | read |
| S10 | `multi_chain_comparison.ex:105` `get/2` for `%Prediction{}` (the map clause is a copy) | `MultiChainComparison.forward/2` | a string-keyed Prediction's rationale/answer is dropped | rendered; both clauses use the accessor |
| S11 | `majority.ex` `present_value_for/2` (map clause), `value_of/2` hint (T4) | `Dspy.majority/2` | raises with the "maps must use atom keys" hint | string-keyed maps vote; hint removed; a map holding **both** `:k` and `"k"` raises `ArgumentError` naming both (R2) |

**Pattern-matched heads:** none on the current tree. `grep -rnE "attrs: %\{[a-z_\"]" lib` returns nothing. The static row Z1 keeps it that way.

**Not routed, on purpose (R4).** These read keys they themselves enumerated from the same map, so the key is always exact:
- `evaluate.ex:600,604` (`lookup_attr`);
- `ensemble.ex:128,152` (keys come from `all_attr_keys`);
- `semantic_f1.ex:74-75` and `complete_and_grounded.ex:78,91`, which read our own adapter's output, always atom keys from the signature.

  No honest string-keyed test can reach them. Routing them anyway would produce rows that C3a could never claim.

### A3. Out of scope
- Plain-map demos in `format_fields` (R3).
- Mixed atom and string completions in `majority` when no `:field` is given: they still raise the multi-key error (R5).
- Any change to how a value is **written** (`put`).

## (b) Consumer safety (`test/consumer_contract/**`)
- **Verified today:** none of the four consumer-contract files calls `Metrics`, `Trainset`, `Ensemble`, `MultiChainComparison`, `majority`, or renders demos. The only nearby reference is `assert p.examples == []` (`forward_contract_test.exs:126`).
- What could still break a consumer is **prompt drift** for atom-keyed demos (S3), and **atom-vs-string precedence** (A1). They are guarded:
  1. **Row 7** compares the atom-keyed Default and JSON prompts **byte for byte** with literals captured from `3fcbea1` **before** any edit, including a demo with a missing output field (today `"Answer: "`).
  2. **Row 20** pins "the atom wins when both exist" through the public `Example.get/2` and `Prediction.get/2`.
  3. `test/consumer_contract/**` is **not edited** and runs in the 20× gate. Any edit is a stop-and-escalate.
- **Every behaviour change is a loosening.** Something that used to raise, or that ignored a string key, now works. The single exception is the new dual-key raise in `majority`, which today silently votes on the atom key.

## (c) Acceptance map
**Test files:**
- `test/dspy/string_keys_test.exs` — every row; this is `acceptance_files`.
- `test/dspy/attrs_test.exs` — unit tests of the accessor.

Every row builds its data with **string keys**, and goes through the **public** entry, unless the row says otherwise.

| # | Row (test name prefix) | Entry |
|---|---|---|
| 1 | `row 1: answer_exact_match string-keyed example and prediction → true` | `Metrics.answer_exact_match/2` |
| 2 | `row 2: answer_passage_match string-keyed context → true` | `Metrics.answer_passage_match/2` |
| 3 | `row 3: answer missing in both forms → raises "example[:answer] is missing"` | `Metrics.answer_exact_match/2` |
| 4 | `row 4: Evaluate over a string-keyed devset scores 100.0, failures 0` | `Dspy.Evaluate` with `answer_exact_match` |
| 5 | `row 5: Default adapter renders string-keyed demo values` (`DEMO_Q`, `DEMO_A` in the captured request) | `Dspy.Module.forward/2` |
| 6 | `row 6: JSON adapter renders string-keyed demo values` | same, `adapter: JSON` |
| 7 | `row 7: atom-keyed demo prompts byte-identical to 3fcbea1` (Default and JSON; one demo with a missing output field) | same |
| 8 | `row 8: exact_match / f1_score / contains on string keys` | `Metrics` |
| 9 | `row 9: stratified_sample groups by a string-keyed field` | `Trainset` |
| 10 | `row 10: filter_quality keyword criteria on string keys` | `Trainset` |
| 11 | `row 11: hard strategy orders by string "difficulty"` (values chosen so 0.5 would give a different order) | `Trainset.sample/3` |
| 12 | `row 12: uncertainty strategy uses string "uncertainty"` | `Trainset.sample/3` |
| 13 | `row 13: :confidence_based picks the member with the highest string "confidence"` (both values ≠ 0.5) | `Ensemble.forward/2` |
| 14 | `row 14: MultiChainComparison renders a string-keyed Prediction's rationale and answer` | `MultiChainComparison.forward/2` (capturing LM) |
| 15 | `row 15: majority over string-keyed maps with field: :answer` | `Dspy.majority/2` |
| 16 | `row 16: majority mixes atom- and string-keyed maps under field: :answer into one tally` | `Dspy.majority/2` |
| 17 | `row 17: majority with only "answer" keys and no :field` (passes today; pinned) | `Dspy.majority/2` |
| 18 | `row 18: majority on a map with both :answer and "answer" raises naming both` | `Dspy.majority/2` |
| 19 | `row 19: majority missing-field error no longer carries the atom-keys hint` | `Dspy.majority/2` |
| 20 | `row 20: Example.get / Prediction.get — atom wins when both forms exist` | public `get/2` |
| Z1 | **static, exempt with a printed reason:** besides `lib/dspy/attrs.ex` and the R4 allow-list, `rg` finds no `Map.(get\|fetch\|has_key?)(…attrs…, :atom)` and no `to_string(field)` fallback. | — |
| Z2 | **static, exempt:** `test/consumer_contract/**` unchanged (`git diff --quiet`) and green in the gate | — |

## (d) Declared mutations (C2 format)
- **Direction 1, revert each caller** (the M1-d rule): put back that site's code exactly as it is on `3fcbea1`. The site's row must go red, and nothing else.
- **Direction 2, break the shared function:** every row that depends on it must go red.
- **Sites whose old code was already correct (S4–S6):** reverting them proves nothing, because the old copy also worked. They are proven by Direction 2 plus Z1, which shows the copy is gone. This is stated so nobody adds a revert mutation that cannot fail.

| Id | File | Change | `expect` | `kind` |
|---|---|---|---|---|
| MR1 | `metrics.ex` | `fetch_field!` back to `Map.fetch(attrs, :answer)` | row 1 (`also`: row 4) | `raise:ArgumentError` |
| MR2 | `metrics.ex` | `fetch_context!` back to atom-only | row 2 | `raise:ArgumentError` |
| MR3 | `signature.ex` | `format_fields` back to `Map.get(example.attrs \|\| example, field.name, "")` | rows 5, 6 | `assertion` |
| MR3b | `signature.ex` | the accessor default `""` → `nil` | row 7 (missing-field demo renders differently) | `assertion` |
| MR7 | `trainset.ex` | `hard_sample` back to atom-only | row 11 | `assertion` |
| MR8 | `trainset.ex` | `uncertainty_sample` back to atom-only | row 12 | `assertion` |
| MR9 | `ensemble.ex` | `:confidence` back to atom-only | row 13 | `assertion` |
| MR10 | `multi_chain_comparison.ex` | the `%Prediction{}` clause back to `Map.get(attrs, key)` | row 14 | `assertion` |
| MR11 | `majority.ex` | `present_value_for` back to `Map.has_key?(map, field)` | rows 15, 16 | `raise:ArgumentError` |
| MR11b | `majority.ex` | dual-key check removed | row 18 | `assertion` (`assert_raise` fails) |
| MR11c | `majority.ex` | hint text restored | row 19 | `assertion` |
| MS1 | `attrs.ex` | string fallback removed (atom key → atom only) | rows 1, 2, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15, 16 | **`any`** (R5b: mixed kinds under one mutation); `also` lists the existing `Example`/`Prediction` string-key tests, by name |
| MS2 | `attrs.ex` | string checked before atom | row 20; also row 18 if the dual-key check uses the accessor | `assertion` |
| MS3 | `example.ex` | `Example.get` stops delegating and goes back to `Map.get(attrs, key, default)` | row 20 and the existing `Example` string-key tests | `assertion` |

**Row 17** passes today, and no mutation within this slice can turn it red: it never takes the fallback path, because the field is resolved to the exact `"answer"` key. It goes in `exempt` with that reason, printed in every report. It is a regression pin, not a proof. **Row 4** is claimed by MS1. Under MR1 it is only collateral (`also`), because `Evaluate` turns the raise into `failure_score`, so its failure is an assertion and not `ArgumentError`. Note: C3a counts only `expect`, never `also`.

**Mutation for row 3:** MR3c changes `fetch_field!` to use `Dspy.Attrs.get(attrs, :answer, "")` instead of a raise on `:error`. Row 3 must go red with `assertion`.

**Wrong-reason guard:** MR1, MR2 and MR11 declare `raise:ArgumentError`. If the revert raised `KeyError` instead, C2 reports WRONG-REASON. That is exactly the M1-c "red for the wrong reason" failure, now mechanical.

## (e) Pre-mortem
1. **Capturing the row-7 golden *after* editing `signature.ex`.** That makes the byte-identity proof circular. → The golden literals are written and committed first, as their own step, from `3fcbea1`, and the controller report shows that hash.
2. **Rows that pass with atom keys.** A string-keyed row that accidentally builds atom keys proves nothing. → Each row also asserts `Map.keys(example.attrs) |> Enum.all?(&is_binary/1)`, and the row asserts on a **non-empty** list (the C3b form).
3. **Ensemble and Trainset rows with values equal to the 0.5 default.** The revert would survive. → Rows 11–13 use values that are not 0.5 and that order differently from it, and MR7–MR9 prove it.
4. **"Fixing" the R4 sites anyway.** It adds rows nobody can claim. → They are on Z1's allow-list, which names each with its reason.
5. **MS1 drifting to `kind: any` everywhere.** → `any` is allowed **only** on MS1, and the report prints the count of `any`.

## Rulings needed (Horst)
- **R1 — `Dspy.Attrs` stays internal** (`@moduledoc false`); users keep using `Example.get/2` and `Prediction.get/2`. *Recommended:* this adds no new public API, and the rule already ships in those functions.
- **R2 — dual keys:** the accessor keeps **atom-wins**, unchanged from today's `Example.get`; changing it could break consumers. `majority` alone **raises** on a map holding both (as T4 was ruled: "keep both raising"). *Recommended.* The alternative is a raise in the accessor everywhere: stricter, but it changes `Example.get`, which is shipped.
- **R3 — plain-map demos in `format_fields`** stay out of scope (today `example.attrs` on a plain map is a `KeyError`; **unverified as reachable** from `Predict`). *Recommended:* defer; it is a separate behaviour change.
- **R4 — the not-routed sites** listed in A2. *Recommended:* each reads a key it enumerated itself.
- **R5 —** (a) in `majority`, mixed atom/string completions **without** `:field` keep raising multi-key. *Recommended:* a guess here is what BC1 forbade. (b) `kind: any` is allowed on MS1 only.

## Verify-first (controller, before code)
- That `Trainset.sample/3` reaches `hard_sample` and `uncertainty_sample` through a public option, and its exact name.
- That MultiChainComparison's attempts are rendered from `Prediction` completions through `get/2` (the `:105` clause).
- That `Evaluate` with a raising metric yields `failure_score`, not a raise. This decides whether row 4 is `also` under MR1 (as written) or must be moved.

## Rulings (Horst, 2026-10-02)
R1 YES · R2 YES (atom wins; only `majority` raises on both keys) · R3 YES (deferred) · R4 YES — those sites read keys they enumerated from the same map, so no honest string-keyed test reaches them and C3a could never claim such rows · R5 YES. **LOCKED.**
