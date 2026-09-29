# Decision: our old text metrics give wrong answers a perfect score

Prepared by Greta for Horst to put to the user · 2026-09-29 · evidence run on v0.4.0 (`184d3a5`) and upstream DSPy 3.4.0

## In one minute

- **The bug.** `Dspy.Metrics.exact_match` and `f1_score` (and `contains`, `substring_match`, `bleu_score`, which share the same text cleaner) delete every character that is not plain ASCII before comparing.
  - Two answers written entirely in another script both become empty and then **match perfectly**: `東京` vs `大阪` (Tokyo vs Osaka), `Москва` vs `Санкт-Петербург`, `القاهرة` vs `الإسكندرية`, `👍` vs `👎` all score **1.0**. Python DSPy scores them 0.0.
  - In German, `Müller` vs `Möller` and `Größe` (size) vs `Grüße` (greetings) also score **1.0**.
- **Who is affected today.** None of the five apps that use dspy.ex calls these functions, `Evaluate`, or any optimizer (checked). Exposed: anyone calling `Dspy.Metrics` directly, anyone following our optimizer documentation (it recommends these functions), and Ensemble, which uses `exact_match` by default to weight its members.
- **Recommendation: option 1 now** — a one-flag fix that removes every wrong perfect score and changes nothing for plain-English text. Then point our docs and Ensemble at the Python-compatible metrics (shipping in M1-b).

## Evidence (same pairs, both implementations run)

Prediction vs expected answer; scores are exact match (EM) / F1.

| Pair | Ours today | Option 1 (one-flag fix) | Python DSPy 3.4.0 |
|---|---|---|---|
| `東京` vs `大阪` | **1.0 / 1.0** | 0.0 / 0.0 | 0.0 / 0.0 |
| `Москва` vs `Санкт-Петербург` | **1.0 / 1.0** | 0.0 / 0.0 | 0.0 / 0.0 |
| `القاهرة` vs `الإسكندرية` | **1.0 / 1.0** | 0.0 / 0.0 | 0.0 / 0.0 |
| `Müller` vs `Möller` | **1.0 / 1.0** | 0.0 / 0.0 | 0.0 / 0.0 |
| `Größe` vs `Grüße` | **1.0 / 1.0** | 0.0 / 0.0 | 0.0 / 0.0 |
| `👍` vs `👎` | **1.0 / 1.0** | **1.0 / 1.0** (still) | 0.0 / 0.0 |
| `東京` vs `東京` | 1.0 / 1.0 | 1.0 / 1.0 | 1.0 / 1.0 |
| `The Eiffel Tower` vs `Eiffel Tower` | 0.0 / 0.8 | 0.0 / 0.8 | 1.0 / 1.0 |
| `the cat the cat` vs `cat` | 0.0 / 0.4 | 0.0 / 0.4 | 0.0 / 0.667 |
| empty vs empty | 1.0 / 1.0 | 1.0 / 1.0 | 1.0 / 0.0 |
| `Paris, France` vs `Paris` | 0.0 / 0.667 | 0.0 / 0.667 | 0.0 / 0.667 |

Scripts (re-runnable): `plan/research/decisions/2026-09-29-h13-legacy-metrics/h13_legacy.exs` (run with `PAIRS=<file> mix run`), `h13_upstream.py` (`PAIRS=<file> uv run`), pairs in `h13_pairs.json` and `h13_pairs2.json`. Option 1 was measured by adding the `u` flag to the `[^\w\s]` regex in the private normaliser.

## The options, and what breaks under each

1. **One-flag fix now (recommended).** Make the text cleaner keep letters from every script (add Unicode mode to one regular expression).
   - *Changes:* only answers containing non-ASCII characters. Every wrong perfect score in the table disappears.
   - *Breaks:* reported scores **drop** for non-English datasets, because they were inflated. Plain-English scores do not move at all.
   - *Leaves:* answers made only of emoji or symbols still collide; the English differences from Python (articles, repeated words, empty answers) stay. Those are handled by option 1b.
   - **1b (with option 1):** once M1-b ships the Python-compatible `answer_exact_match` / `f1`, switch our documentation examples and Ensemble's default to them. Existing callers of the old names keep the fixed behaviour.
2. **Full switch to Python's behaviour** for `exact_match` / `f1_score` themselves.
   - *Changes:* everything in option 1, plus English articles ignored ("The Eiffel Tower" = "Eiffel Tower"), repeated words counted, empty-vs-empty F1 becomes 0.0.
   - *Breaks:* **English scores move too**, for every existing caller. Largest behaviour change.
3. **Deprecate with a warning for one minor version, then switch.**
   - *Changes:* nothing now except a warning.
   - *Breaks:* nothing now — but **wrong perfect scores keep being reported for one more release**, knowingly.
4. **Keep and document.**
   - *Breaks:* nothing. Wrong perfect scores stay indefinitely.

## Why option 1

Scoring a wrong answer as perfect is losing the user's information, not a design choice — by our standing rule we fix that, and we declare it. Option 1 is the smallest change that removes it, and it cannot move a single plain-English score. Options 3 and 4 keep a known wrong result in front of users; option 2 changes English results that are merely different from Python, not wrong, which deserves its own decision later.

## For the release note (if option 1)

"Text metrics (`exact_match`, `f1_score`, `contains`, `substring_match`, `bleu_score`) no longer delete non-ASCII letters. Previously, any two answers written only in non-Latin scripts (e.g. Japanese, Russian, Arabic), or differing only in letters like ü/ö/ß, were scored as a perfect match. Scores on such data will drop to their correct values. Plain-ASCII text is unaffected."
