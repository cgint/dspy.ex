# M1-b — Upstream answer metrics: answer_exact_match (frac, answer lists), answer_passage_match, EM/F1, public normalize_text

Status: **DRAFT (Greta 2026-09-28)** — needs Horst's calls on F1–F9 below, then the team card and both signatures. Paper only.
Queue: `PARITY_QUEUE.md` §M1 rows **U010** (answer_exact_match), **U011** (answer_passage_match), **U012** (normalize_text).
Base: `main` at `bb7991d` (v0.3.48 + M1-a in flight). Existing module: `lib/dspy/metrics.ex`.

Reference, re-anchored to DSPy **3.4.0** (`../dspy-3.4.0`, tag `3.4.0`):
- `dspy/evaluate/metrics.py`: TODO "should move internally" `:1`; `EM` `:11-36`; `F1` `:39-60`; `normalize_text` `:87-123`; `em_score` `:126-141`; `f1_score` `:144-180` (both-empty diagnostic `:169-171`, zero overlap returns int `0` `:173-174`); `_passage_match` `:259-270`; `_answer_match` `:273-282`; `answer_exact_match` `:285-317`; `answer_passage_match` `:320-348`.
- `dspy/dsp/utils/dpr.py`: `Tokens.words(uncased=True)` `:45-54`; `SimpleTokenizer` `:151-196` (`ALPHA_NUM = [\p{L}\p{N}\p{M}]+`, `NON_WS = [^\p{Z}\p{C}]`); `has_answer` `:198-206`; `DPR_tokenize` / `DPR_normalize` `:231-236` (NFD first).
- Public exports: `dspy/evaluate/__init__.py:3-9` = `EM`, `normalize_text`, `answer_exact_match`, `answer_passage_match`. `F1` is module-level only, **not** re-exported.
- **Oracle:** `tests/evaluate/test_metrics.py` — **only 3 cases, all `answer_exact_match`** (string `:8-15`, list `:18-25`, no match `:28-35`). Nothing for `frac`, `answer_passage_match`, `EM`, `F1` or `normalize_text`. `tests/examples/test_baleen.py:82` calls `answer_exact_match_str`, which does not exist in 3.4.0 — a dead test, **not** an oracle.

## Why
Upstream's standard QA metrics are the default vocabulary of DSPy tutorials and of upstream's own Evaluate tests (`tests/evaluate/test_evaluate.py` uses `answer_exact_match` as the metric throughout). Ours has `Dspy.Metrics.exact_match/3` and `f1_score/3`, which are **not** these functions: different signature, different normalisation, set-based F1 (see F7).

## (a) Contract

### A1. Where it lives, and the public surface (see F2)
All new functions go in **`Dspy.Metrics`** (our metrics module), documented as the equivalents of `dspy.evaluate.*`. One name each, no aliases in `Dspy.Evaluate`.

```elixir
@spec normalize_text(String.t()) :: String.t()
@spec em(String.t(), [String.t()]) :: boolean()
@spec f1(String.t(), [String.t()]) :: float()
@spec answer_exact_match(Example.t(), Prediction.t(), keyword()) :: boolean()   # opts: frac: number (default 1.0)
@spec answer_passage_match(Example.t(), Prediction.t()) :: boolean()
```

Names: `em/2` and `f1/2` (upstream `EM`, `F1`). Upstream's pairwise `em_score`/`f1_score` stay **private** — our public `f1_score/2,3` already exists with other semantics, so the upstream names cannot be reused.

### A2. Return types and what `nil` means (Horst's question 1)
No function in this slice returns `nil`, and none accepts `nil` as a value. Every "no" is `false` or `0.0`; every bad input **raises**. Nothing relies on truthiness.

| Function | Returns | Upstream returns | Bad input → |
|---|---|---|---|
| `normalize_text/1` | `String.t()` (possibly `""`) | `str` | non-binary → `FunctionClauseError` (upstream `TypeError` in `unicodedata.normalize`) |
| `em/2` | `true \| false` | `bool` (`max` of bools) | answers not a list, or `[]` → `ArgumentError` (upstream `ValueError` `:33-34`, and `max()` of empty) |
| `f1/2` | `float` in `[0.0, 1.0]`, **always a float** | `float`, or int `0` on no overlap `:173-174` | as `em/2` |
| `answer_exact_match/3` | `true \| false` | `bool` | see A4 |
| `answer_passage_match/2` | `true \| false` | `bool` | see A4 |

Why booleans are safe here and were not in the `run_metric` mess: since H0b-2, `run_metric` maps `true`/`false` to `1.0`/`0.0` before any consumer sees them (`lib/dspy/teleprompt.ex`, `normalize_score/1`), and Evaluate sums booleans the same way (upstream `evaluate.py:183`). A boolean is a number to every consumer. The problem last time was a metric returning *neither* — this slice never does.

### A3. Behaviour (bit-for-bit upstream 3.4.0)
- **`normalize_text/1`** (`:108-123`): Unicode **NFD** (decompose only — accents are **not** stripped), then lowercase, then remove **ASCII** punctuation only (Python `string.punctuation` = ``!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~``; Unicode punctuation such as `—` or `“` is **kept**), then replace whole-word `a|an|the` with a space (`\b(a|an|the)\b`, Unicode-aware word boundaries), then collapse all whitespace to single spaces and trim. Order matters and is exactly this.
- **`em/2`**: `true` if `normalize_text(pred) == normalize_text(ans)` for any answer.
- **`f1/2`**: max over answers of token F1. Tokens = `normalize_text(s) |> String.split()`. Overlap is a **multiset** intersection (Python `Counter & Counter`): a token counts `min(count_pred, count_gold)` times. No overlap → `0.0`. Both sides empty → `0.0` (upstream prints a diagnostic line to stdout `:169-171`; we emit nothing — declared, F6).
- **`answer_exact_match/3`** (`:273-282`, `:312-317`): reads `example[:answer]` and `pred[:answer]`. A binary answer is treated as `[answer]`. `frac >= 1.0` → `em/2`; otherwise `f1/2 >= frac` (inclusive).
- **`answer_passage_match/2`** (`:259-270`, `:343-348`): reads `example[:answer]` (binary or list) and `pred[:context]` (list of binaries). `true` if any passage contains any answer, where both are `normalize_text`-ed, then DPR-tokenized (NFD, tokens by `[\p{L}\p{N}\p{M}]+|[^\p{Z}\p{C}]`, lowercased), and an answer matches when its token list appears as a **contiguous token run** in the passage's token list. Empty context → `false`.

### A4. Errors (all `ArgumentError` naming the offending field/value unless stated)
- `example` or `pred` has no `:answer` (for passage match: `pred` has no `:context`). **No silent `""` default** — the legacy `get_field_value/2` default must not be reused.
- `example[:answer]` is neither a binary nor a non-empty list of binaries (upstream `ValueError` `:317`, `:348`).
- `pred[:answer]` is not a binary (upstream crashes with `TypeError`).
- `pred[:context]` is not a list (F5: upstream would iterate a string's characters).
- `frac` is not a number.

In Evaluate these raises become a failed example scoring `failure_score` — exactly upstream (`process_item` raises → `None` → `failure_score`, `evaluate.py:181`). The metric itself never rescues.

### A5. Invariants
1. **Every existing `Dspy.Metrics` function is unchanged**: `exact_match/2,3`, `f1_score/2,3`, `accuracy`, `contains`, `substring_match`, `bleu_score`, `numeric_accuracy`, `create_metric`, `combine_metrics`. `test/metrics_test.exs` has **zero diff**. Reason: `exact_match/2` and `f1_score/2` are the default metrics of `bootstrap_few_shot.ex:13`, `ensemble.ex:520`, `mipro_v2.ex:18` and `copro.ex:22`; changing them silently changes four optimizers.
2. The existing **private** `normalize_text/1` (`metrics.ex:307-315`) keeps its behaviour and is **renamed** (e.g. `legacy_normalize/1`) so the new public `normalize_text/1` does not collide with it. Its callers are updated to the new name only.
3. No new dependency. NFD via OTP `:unicode.characters_to_nfd_binary/1`; regexes via `Regex` with the `u` flag.
4. `test/consumer_contract/**`, `mix.exs`, `mix.lock`: unchanged.
5. H0b-2 / v0.3.48 semantics untouched (`run_metric`, Evaluate scoring, `InvalidMetricResult`).

### A6. Forbidden
Reusing or editing the legacy private normaliser for the new functions; `[[:punct:]]`, `\p{P}` or `[^\w\s]` for punctuation; any regex without the `u` flag in `normalize_text` or the DPR tokenizer; `MapSet` for token overlap; returning `1.0` for both-empty F1; defaulting a missing field to `""`; `rescue` inside a metric; a `trace` parameter (F4); substring (`String.contains?`) matching in passage match.

### A7. Non-goals
`HotPotF1` / `hotpot_f1_score` / `precision_score` (module-level only, not exported, not queued); `locate_answers`, `strip_accents`; changing the legacy metrics (F7) or `create_metric` (F8); changing `run_metric`'s arity dispatch (F4).

## (c) Acceptance map
Oracle tiers: **[T]** ported upstream test · **[D]** upstream docstring example (upstream-authored, runnable) · **[G]** golden vector generated by running upstream 3.4.0 (F1). Nothing is hand-derived and called parity.

| # | Tier | Scenario | Mutation that must turn it RED |
|---|---|---|---|
| 1 | T | `answer: "2"`, pred `"2"` → `true` (`test_answer_exact_match_string`) | always `false` |
| 2 | T | `answer: ["2","two"]`, pred `"2"` → `true` (`test_answer_exact_match_list`) | binary-only dispatch (list raises) |
| 3 | T | `answer: "2"`, pred `"3"` → `false` (`test_answer_exact_match_no_match`) | always `true` |
| 4 | G | `answer: ["2","two"]`, pred `"two"` → `true` (row 2 cannot tell "any answer" from "first answer") | compare against `hd(answers)` only |
| 5 | D | `em("The Eiffel Tower", ["Eiffel Tower","Louvre"])` true; `em("paris", ["Paris"])` true; `em("paris", ["Paris, France"])` false (`:27-30`) | no article removal (legacy normaliser) |
| 6 | D | `Float.round(f1("Eiffel Tower is in Paris", ["Paris"]), 2) == 0.33` (`:54`) | precision divided by the answer's token count instead of the prediction's (→ 1.0) |
| 7 | D | `normalize_text("The,  Eiffel  Tower!") == "eiffel tower"` (`:105`) | legacy normaliser |
| 8 | D | `answer: ["Eiffel Tower","Louvre"]`, pred `"The Eiffel Tower"`: `frac: 1.0` → true, `frac: 0.5` → true (`:305-309`) | legacy normaliser on the EM path (keeps `the` → false). Not a `frac` test: both calls are true even if `frac` is ignored — `frac` is pinned by row 12 |
| 9 | D | `answer: "Eiffel Tower"`, `context: ["The Eiffel Tower is in Paris.", "..."]` → true (`:337-340`) | always `false` |
| 10 | G | `normalize_text` golden table: articles as words vs inside words (`"banana"`, `"theater"`), each ASCII punctuation char, Unicode punctuation kept (`—`, `“ ”`), accented input NFC vs NFD giving equal output, tabs/newlines, non-ASCII letters kept (`"Straße"`, `"café"`) | each of: `\p{P}`; no `u` flag; missing NFD; legacy normaliser |
| 11 | G | `f1` golden table incl. repeated tokens (`"the cat cat"` vs `"cat"`), both empty → `0.0`, and `f1("cat dog", ["cat bird"]) == 0.5` | `MapSet` overlap; both-empty `1.0` |
| 12 | – | `frac` boundaries: pred `"cat dog"`, answer `"cat bird"` (F1 = 0.5 exactly) with `frac: 0.5` → true; `frac: 1.5` on an exact-match pair takes the EM path (→ true; the F1 path would give `1.0 >= 1.5` → false); `frac: 0.0` on a zero-overlap pair → true (F3, parity quirk pinned) | `>` instead of `>=`; `frac == 1.0` instead of `>= 1.0` |
| 13 | – | A4 errors: missing `:answer` on example / pred; integer answer; `[]` answers; `nil` pred answer; binary `context`; non-number `frac` — each `ArgumentError` naming the field | legacy `""` default; a `rescue` returning `false` |
| 14 | G | `answer_passage_match` golden table: multi-token answer across a passage; `"art"` vs passage `"party"` → false (token, not substring); punctuation-adjacent match (`"Paris."`); empty context → false; list of answers where only the last matches | `String.contains?`; answers not DPR-tokenized |
| 15 | – | **Public entry:** `Dspy.Evaluate.evaluate(program, set, &Dspy.Metrics.answer_exact_match/2)` → `scores` `[1.0, 0.0, …]`; and with `&Dspy.Metrics.answer_exact_match(&1, &2, frac: 0.5)` | metric returns `"true"`/`"false"` strings (Evaluate then raises `InvalidMetricResult`) |
| 16 | – | Return types: the three boolean functions return exactly `true`/`false` (`is_boolean/1`); `f1` returns a float for a zero-overlap pair (`0.0`, not `0`) | returning `1`/`0` ints |
| 17 | – | **Legacy pin:** `Dspy.Metrics.exact_match(ex("The cat"), pred("cat")) == 0.0` (legacy normaliser keeps articles) and `test/metrics_test.exs` zero diff | legacy normaliser replaced by the upstream one |
| 18 | – | Full suite + consumer canary green; `git diff test/` additions only | – |
| 19 | T | **F9 switch-over:** the M1-a tests ported from upstream `test_evaluate.py` that used a stand-in metric are re-pointed to `&Dspy.Metrics.answer_exact_match/2`, and the table/CSV metric column comes out named `answer_exact_match` (upstream `test_evaluate.py:103-111`). The only permitted edit to existing tests in this slice; Ilse names the files | revert the switch-over, or a metric-name derivation that yields anything other than `answer_exact_match` |

## (d) Pre-mortem — how a cheap worker passes the tests and misses the intent
1. **Reuses the legacy private normaliser.** The 3 upstream tests (`"2"` vs `"2"`/`"3"`) pass with *any* normaliser. → Rows 5, 7, 10 kill it.
2. **"Fixes" the legacy normaliser in place** so there is only one. Everything new passes, and four optimizers' default metric silently changes. → A5.1/A5.2, row 17.
3. **Copies the legacy `f1_score` body** (MapSet, both-empty `1.0`). → Row 11.
4. **Uses `\p{P}` or `[[:punct:]]`** because it "looks more correct". Upstream strips ASCII only. → Row 10.
5. **Substring passage match** (`String.contains?`) — passes the docstring case. → Row 14 (`"art"`/`"party"`).
6. **Adds `trace` as the 3rd positional parameter** to mirror upstream; then `frac` goes into position 4, and `&answer_exact_match/3` is fed to Evaluate, where `run_metric` calls arity-1 (`teleprompt.ex:158-164`) → every example silently fails. → F4, row 15.
7. **Only ports the [T] rows** and calls it parity. → Every [G] row is required; Clemens checks the golden file is generated, not typed.

## (e) Echo-back before the first edit
The A1 signatures verbatim; the A2 return-type table in own words; the A3 `normalize_text` step order; the A4 error list; one sentence per A5 invariant; which rows are [G] and where the golden file comes from.

## Decisions for Horst (not silent choices)
- **F1 — Oracle strategy (needs your call, touches toolchain).** The upstream oracle is 3 cases. I propose **golden vectors generated by running upstream 3.4.0**: a committed script `scripts/gen_metrics_golden.py` (run manually with `uv run`, pinned `dspy==3.4.0`, same mechanism as `tmp/pyck/ck.py`) writes `test/fixtures/upstream_metrics_3_4_0.json`; the ExUnit tests read the JSON. CI never runs Python; no new mix dependency. The alternative — hand-deriving expected values by reading upstream code — is exactly "invent our own and call it parity". I recommend the script.
- **F2 — `normalize_text` public? (your question 2).** Recommendation: **public, as `Dspy.Metrics.normalize_text/1`, with a frozen contract**: "equal to DSPy 3.4.0 `dspy.evaluate.normalize_text` for every binary; it will never be 'improved' — a better normaliser gets a new name". Reasons: upstream exports it (`evaluate/__init__.py:7`) and its own test passes it explicitly (`test_aggregation.py:26`); users need it to build custom metrics consistent with `em`; and M1-c's default depends on it. The commitment is cheap because we promise *parity*, not quality, and parity is the only reason anyone would call it. Against: upstream itself says these "should move internally" (`metrics.py:1`), and the behaviour is English-centric (English articles, ASCII punctuation). Alternative: keep it private, mark U012 "internal", port `test_majority_with_normalize` via the default normaliser. Namespace: `Dspy.Metrics`, not `Dspy.Evaluate` — `Dspy.Evaluate` is the evaluator, not a text utility; one name, no alias (same logic as G1 in M1-a).
- **F3 — `frac: 0.0` is always true** (`F1 >= 0`). Upstream quirk. I recommend **keep (parity), pin it** (row 12) and document it; reject only non-numbers.
- **F4 — No `trace` parameter.** Upstream's `trace=None` exists for its optimizer protocol; ours never passes a trace, and `run_metric` treats any non-2-arity function as arity 1 (`teleprompt.ex:158-164`), so a 3-arity metric silently fails every example. We expose `/2` plus `opts`. `frac` users write `&answer_exact_match(&1, &2, frac: 0.8)`. Declared deviation. The `run_metric` arity rule itself is a separate latent trap (any user arity-3 metric fails silently) — log it; out of scope here.
- **F5 — `pred[:context]` must be a list.** Upstream iterates a string character by character and returns a meaningless answer. I recommend **raise** (stricter than upstream, declared). Also a **size note**: U011 needs the DPR tokenizer port (~40 lines plus golden rows) — M, not S as the queue says.
- **F6 — Both-empty F1 diagnostic.** Upstream prints to stdout. We print nothing. Declared.
- **F7 — Legacy metrics diverge from upstream and are optimizer defaults.** `Dspy.Metrics.exact_match`/`f1_score`: no NFD or article removal; `[^\w\s]` **without** the `u` flag strips every non-ASCII letter (`"Straße"` → `"strae"`); set-based F1; both-empty `1.0`. Upstream optimizers have no default metric. **Not in this slice.** It needs a decision (switch defaults to the new functions? deprecate?) and is a behaviour change for optimizer users. Log it as a queued item.
- **F8 — `create_metric/2` rescues everything and coerces non-numbers to `0.0`** (`metrics.ex:245-247`) — the exact anti-pattern H0b-2 removed from `run_metric`. Out of scope; log it.
- **F9 — Coupling with M1-a.** Upstream's Evaluate tests use `answer_exact_match` as the metric, and `test_evaluate.py:103-111` expects the table column to be named `answer_exact_match`. M1-a is porting those tests now with some stand-in metric. Please ask Ilse what stand-in she used. M1-b then adds one row: re-point the ported M1-a tests to the real `&Dspy.Metrics.answer_exact_match/2` and confirm the column name comes out as `answer_exact_match` (M1-a's `metric_name` via `Function.info/2`).

### RULED 2026-09-28 (Horst)
- **F3 — AGREED: keep upstream.** `frac: 0.0` is always true; pinned by row 12 and documented.
- **F5 — AGREED: raise on a binary `context`.** Horst's reading, recorded so nobody "fixes" it toward Python later: this is **not a real deviation**. In Python a `str` is iterable, so upstream silently scores each *character* as a passage — duck-typing producing garbage. In Elixir a binary is not enumerable, so raising is the natural typed behaviour; we only make the message clear. Declared in `docs/COMPATIBILITY.md` with this reasoning. U011 sized **M**.
- **F6 — AGREED:** the stdout diagnostic for both-empty F1 is dropped.
- **F8 — AGREED, booked:** `create_metric/2` swallowing is queue item **H5** in `plan/current/PARITY_QUEUE.md` (before M6). Out of scope here.
- **F9 — routed to Ilse** (she owns the M1-a tree). Row 19 below stays as the mechanism.
- **F1 — RULED YES (Horst 2026-09-28): commit the generator under `plan/research/`, not `tmp/`.** Location: `plan/research/upstream_golden/gen_metrics_golden.py` (a `uv` script pinned to `dspy==3.4.0`), writing `test/fixtures/upstream_metrics_3_4_0.json`. A generator that produces our oracle fixtures must be reproducible by the next person; an uncommitted script is a fixture nobody can regenerate. **Python here is a TOOL for generating fixtures, not a runtime dependency of the library:** nothing in `lib/` or in `mix test` runs Python, CI never needs a Python interpreter, and the committed JSON is the test input. Reviewers: this does not touch the no-Python-runtime rule. The same generator directory serves M1-c, M1-d and M1-e (and H12).
- **Still OPEN — not covered by a ruling yet, needed before either signature:** **F2** (`normalize_text` public in `Dspy.Metrics`, frozen to 3.4.0), **F4** (no `trace` parameter; `frac` via opts — see also queue **H13**, the trace protocol), **F7** (legacy `exact_match`/`f1_score` untouched in this slice).

## (b) Team card — Horst.

## (f) Clarity Gate
- Greta ☐ — signs once F1–F9 are ruled on.
- Horst ☐
