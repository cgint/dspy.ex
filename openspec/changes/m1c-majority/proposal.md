# M1-c — Dspy.majority

Status: **DRAFT (Greta 2026-09-28)** — needs Horst's calls on C1–C4, then the team card and both signatures. Paper only.
Queue: `PARITY_QUEUE.md` §M1 row **S044** (majority). **Depends on M1-b** (`Dspy.Metrics.normalize_text/1` is the default normaliser) — C4.
Base: `main` at `bb7991d`.

Reference, re-anchored to DSPy **3.4.0** (`../dspy-3.4.0`, tag `3.4.0`):
- `dspy/predict/aggregation.py`: `default_normalize` `:5-6` (`normalize_text(s) or None` — an empty normalised string becomes `None`); `majority` `:9-54`: input type check `:16`; completions from a Prediction `:20-23`; default field = last output field of the signature, else **last key of the first completion dict** `:30-34`; `normalize=None` → identity `:37`; values normalised `:38`, `None` dropped `:39`; counting over non-`None` values, **or over all values if every one is `None`** `:43-44`; winner = `max(value_counts, key=value_counts.get)` over a dict in first-appearance order `:46`; returns the **first original completion** whose normalised value equals the winner `:49-51`, wrapped as `Prediction.from_completions([completion])` `:54`.
- Export: `dspy/predict/__init__.py:1,16` → `dspy.majority`.
- **Oracle:** `tests/predict/test_aggregation.py` — 6 tests: with a Prediction `:6-9`, with `Completions` `:12-15`, with a list `:18-21`, with `normalize=normalize_text` `:24-27`, with `field=` `:30-37`, no majority → first `:40-43`.

## Why
`majority` is the standard way to aggregate several completions (self-consistency). Ours has no equivalent; Ensemble's `:majority_vote` combines *programs* inside a teleprompter and is a different mechanism (queue note on S044).

## (a) Contract

### A1. Signature
```elixir
@spec majority([map() | Dspy.Prediction.t()], keyword()) :: Dspy.Prediction.t()
# opts:
#   field:     atom()                         — required unless every completion has exactly one and the same key (C2)
#   normalize: (term() -> term()) | nil       — default &Dspy.Majority.default_normalize/1 (see A2); nil = identity
```
Public as **`Dspy.majority/2`** (upstream `dspy.majority`), implemented in `Dspy.Majority` with `default_normalize/1` public so callers can compose it. Input is a **list of completions in caller order**, each a map with atom keys or a `%Dspy.Prediction{}` (read via Access) — the same completion shape `Dspy.MultiChainComparison` already accepts (`multi_chain_comparison.ex:17-19`).

### A2. Return types and what `nil` means (Horst's question 1)
This is the one place in M1 where `nil` carries meaning, so it is pinned exactly:
- `normalize` may return **any term**. **Only `nil` means "ignore this completion".** `false`, `""`, `0` and `[]` are ordinary votes. (Upstream tests `x is not None` `:39`, not truthiness.)
- `default_normalize/1` = `Dspy.Metrics.normalize_text(s)`, then `""` → `nil` (upstream `normalize_text(s) or None` `:6`). It is the **only** place where `""` becomes `nil`; with a custom `normalize`, `""` is a vote. `default_normalize/1` on a non-binary raises (upstream `TypeError`).
- Vote keys are compared by Elixir term equality: `1` and `1.0` are **different** votes (C3).
- `majority/2` always returns a `%Dspy.Prediction{}` or raises. It never returns `nil`.

### A3. Behaviour (upstream 3.4.0)
1. Normalise the chosen field of every completion.
2. Drop completions whose normalised value is `nil`. **If every value is `nil`, count them all** (so the winner is `nil`, and step 4 returns the first completion).
3. The winner is the value with the highest count; **on a tie, the value whose first appearance is earliest wins** (upstream `max` over an insertion-ordered dict `:46`). Counting must preserve first-appearance order.
4. Return the **first original completion** whose normalised value equals the winner — the original, not the normalised value. A `%Dspy.Prediction{}` completion is returned as is; a map `m` is returned as `Dspy.Prediction.new(m)`. The result's `completions` list is left `[]` (C1).

### A4. Errors (`ArgumentError`, naming the problem)
- the input is not a list, or is `[]` (upstream: `IndexError` / `max()` of empty);
- the input is a `%Dspy.Prediction{}` rather than a list (C1);
- a completion lacks the field (upstream `KeyError`);
- no `:field` given and the completions do not all have exactly one and the same key (C2) — the message lists the keys seen.

### A5. Invariants
1. Pure: no LM call, no process, no Settings read.
2. `Dspy.Prediction` (struct, `@type completion`, `add_completion/2`) is unchanged.
3. Ensemble's `:majority_vote` and every existing test: unchanged, zero diff.
4. `test/consumer_contract/**`, `mix.exs`, `mix.lock`: unchanged. No new dependency.
5. `Dspy.Metrics.normalize_text/1` is used, never re-implemented.

### A6. Forbidden
`Enum.frequencies/1` (or any map) followed by `Enum.max_by/2` to pick the winner — a map loses first-appearance order and breaks ties alphabetically; truthiness filters (`if v`, `Enum.filter(& &1)`) instead of `!= nil` / `is_nil/1`; returning the normalised value; reading `Prediction.completions`; guessing the default field from map key order; a private copy of `normalize_text`.

### A7. Non-goals
A `Dspy.Completions` type; `Prediction.from_completions`; populating `Prediction.completions`; multi-completion generation in `Predict` (`n > 1`); signature-based default field.

## (c) Acceptance map
Tiers: **[T]** ported upstream test · **[G]** golden vector generated by running upstream 3.4.0 (same generator as M1-b F1) · **[–]** contract-only behaviour (a declared decision).

| # | Tier | Scenario | Mutation that must turn it RED |
|---|---|---|---|
| 1 | T | `[%{answer: "2"}, %{answer: "2"}, %{answer: "3"}]` → `result[:answer] == "2"` (`test_majority_with_list`; also the list form of `_with_prediction` and `_with_completions`, see C1) | return the last completion |
| 2 | T | `[%{answer: "2"}, %{answer: " 2"}, %{answer: "3"}]`, `normalize: &Dspy.Metrics.normalize_text/1` → `"2"` (`test_majority_with_normalize`) | none on its own: without normalisation all three tie and the first (`"2"`) still wins. Normalisation is pinned by row 6 |
| 3 | T | `field: :other` on `[{answer 2, other 1}, {2, 1}, {3, 2}]` → `result[:other] == "1"` (`test_majority_with_field`) | field ignored, always `:answer` |
| 4 | T | `["2","3","4"]` → `"2"` (`test_majority_with_no_majority`) | return the last on a tie |
| 5 | G | **THE TIE TRAP (its own test, elevated by Horst 2026-09-28).** `["b", "a"]` → `result[:answer] == "b"`. The data MUST be a **non-alphabetical** tie: upstream's own tie test (`["2","3","4"]`, row 4) is alphabetical and passes the broken implementation. The test MUST carry a one-line comment saying so, e.g. `# Deliberately NOT alphabetical: an Enum.frequencies |> Enum.max_by winner breaks ties by sort order and would pass ["2","3","4"]. Do not reorder.` | **Implement the winner with `Enum.frequencies \|> Enum.max_by`** (verified: returns `{"a", 1}` for `["b","a"]`) |
| 5b | G | Interleaved tie: `["x", "y", "y", "x"]` → `"x"` (first appearance, not last occurrence, not count order) | winner chosen by the position of the *last* occurrence |
| 6 | G | **Normalises, then returns the original:** `["3", " 2", "2"]` with `normalize: &Dspy.Metrics.normalize_text/1` → `result[:answer] == " 2"` | normalisation ignored (tie → `"3"`); returning the normalised value (`"2"`); returning the last matching completion (`"2"`) |
| 7 | G | **`nil` = ignore:** normalize maps `"x"` → `nil`; `["x","x","y"]` → `"y"` | counting `nil` as a vote |
| 8 | G | **All `nil` → first completion:** normalize always `nil`; `["p","q"]` → `"p"` | raising / `Enum.max` on an empty tally |
| 9 | – | **`false` is a vote:** normalize maps `"x"` → `false`, `"y"` → `"y"`; `["x","x","y"]` → `result[:answer] == "x"` | truthiness filter (`Enum.filter(& &1)`) |
| 10 | G | **Default normaliser drops `""`:** `["!!", "!!", "3"]` (normalises to `""`, `""`, `"3"`) → `"3"`; and with `normalize: nil` → `"!!"` | default without the `""`→`nil` step; `normalize: nil` not treated as identity |
| 11 | – | `%Dspy.Prediction{}` elements are accepted and the winner is returned as the same struct (`==`) | re-wrapping loses fields |
| 12 | – | A4 errors: `[]`; a `%Dspy.Prediction{}` as the whole input; a completion missing the field; two-key completions without `:field` (message lists the keys) | a guessed default field (`Map.keys \|> List.last`) |
| 13 | – | Single common key with no `:field` → that key is used | always requiring `:field` |
| 14 | – | Full suite + consumer canary green; `git diff test/` additions only | – |

## (d) Pre-mortem
1. **Winner via `Enum.frequencies |> Enum.max_by`.** All 6 upstream tests still pass — their only tie (`["2","3","4"]`) happens to be alphabetical too. Ties then break by *sort order*, not first appearance. → Row 5 (verified: `Enum.max_by(Enum.frequencies(["b","a"]), …)` returns `{"a", 1}`).
2. **Truthiness.** `Enum.reject(values, &(!&1))` drops `false` as well as `nil`. → Row 9.
3. **Returns the normalised value** (`Prediction.new(%{answer: winner})`), or ignores `normalize` entirely. The upstream normalize test passes either way: `"2"` normalises to itself, and without normalisation the three values tie and the first is `"2"`. → Row 6.
4. **Reads `prediction.completions`** to support the Prediction input form. That list holds LM records (`%{text:, tokens:, …}`, `prediction.ex:11-16`), nothing populates it, and `add_completion/2` **prepends** (`prediction.ex:146-148`), so "earlier" would mean "newer". → C1, row 12.
5. **Guesses the default field from key order.** Small Elixir maps iterate in sorted key order, so "last key" is alphabetical, not Python's insertion order. → C2, rows 12–13.
6. **Re-implements `normalize_text` privately** because M1-b isn't merged yet. → A5.5, C4 (M1-c starts after M1-b is released).

## (e) Echo-back before the first edit
The A1 signature and opts verbatim; A2 in own words (what `nil` means, what `false` and `""` mean); the four A3 steps; the tie rule in one sentence; the A6 forbidden list; one sentence per A5 invariant.

## Decisions for Horst (not silent choices)
- **C1 — No Prediction/Completions input form (declared deviation).** Upstream takes a Prediction (reads its `.completions`), a `Completions` object, or a list. We have no `Completions` type, and our `Prediction.completions` holds raw LM records that nothing populates, in newest-first order. I recommend **list only**; a `%Dspy.Prediction{}` passed as the whole input raises `ArgumentError` pointing at the list form. The oracle tests `test_majority_with_prediction` and `test_majority_with_completions` are then ported in their list form (same data, same assertion) and recorded as such — not claimed as ported verbatim. Revisit when `Predict` can return `n > 1` parsed completions.
- **C2 — Default field (declared deviation).** Upstream uses the signature's last output field, or else the last key of the first completion dict (Python insertion order). Neither exists for a list of Elixir maps. I recommend: **use the key if every completion has exactly one and the same key; otherwise require `:field` and raise.** Never guess from key order.
- **C3 — Vote equality.** Python dict keys treat `1`, `1.0` and `True` as one key; Elixir map keys don't (verified: `Map.has_key?(%{1 => :x}, 1.0)` is `false`). This only matters for a custom `normalize` returning numbers or booleans. Recommend **declare, don't emulate**.
- **C4 — Sequencing.** M1-c's default normaliser is M1-b's `normalize_text/1`. With one lib-editing team at a time, the order is **M1-b, then M1-c**; the contracts can be signed in parallel. Size: S (unchanged).

### RULED 2026-09-28 (Horst)
- **C1 — AGREED: list only.** A `%Dspy.Prediction{}` passed as the whole input raises. This is a **deliberate shape change, not an omission**: `add_completion/2` prepends (`prediction.ex:146-148`), so reading `Prediction.completions` would make "earlier" silently mean "newer" and ship a backwards tie-break. `test_majority_with_prediction` and `test_majority_with_completions` are ported **in list form** (same data, same assertion) and the port records that they were reshaped and why.
- **C2 — AGREED: require `:field` unless every completion has the same single key.** The `ArgumentError` names the ambiguity: it says `:field` is required because the completions do not share one single key, and lists the keys seen. Upstream's "last key of the first completion" is not ported — in Elixir it would mean "alphabetically last", which would be invented, not parity.
- **Tie trap — ELEVATED** to its own row (row 5) with the mutation stated as "implement the winner with `Enum.frequencies |> Enum.max_by`", non-alphabetical data, and a mandatory comment in the test.
- **C3 — AGREED: declare** in `docs/COMPATIBILITY.md` that votes use Elixir term equality (`1` and `1.0` are different votes). Not emulated.
- **C4 — AGREED: M1-b before M1-c.**
- **Golden rows [G] — generator RULED (Horst 2026-09-28, M1-b F1):** produced by the committed `uv` generator under `plan/research/upstream_golden/` running `dspy.majority` from DSPy 3.4.0, written to a committed fixture. Python is a fixture-generation tool, not a runtime dependency: `mix test` and CI never run it.

## (b) Team card — Horst.

## (f) Clarity Gate
- Greta ☐ — signs once C1–C4 are ruled on.
- Horst ☐
