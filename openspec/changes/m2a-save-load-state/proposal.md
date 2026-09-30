# M2-a — Save and load program state (JSON)

Status: **DRAFT (Greta 2026-09-29)** — needs Horst's rulings on **D1–D4** before signing (D2 is a scope question the slicing dropped). Paper only.
Base: `main` at `8390cfb`. Findings this rests on: `plan/research/m2/2026-09-29-m2-findings.md` (F-1…F-5, every cite re-checked against the 3.4.0 source).
Queue: `PARITY_QUEUE.md` §M2 — S113 (load), S054 facet (named predictors), S038 facet (dump/load_state).

Reference, anchored to DSPy **3.4.0** (`../dspy-3.4.0`):
- `primitives/base_module.py`: `named_parameters` `:24-66` (paths: a Predict alone is `"self"`; attribute `name`; nested `name.sub`; list `name[i]`; dict `name['key']`; each object once, by identity; pre-compiled sub-modules skipped); `dump_state` `:157-158` = `{path: predictor_state}`; `load_state` `:160-172` (trial run on a deep copy, then apply; reads `state[name]` for every path); `save` `:172-249` (`.json` → orjson `:229-234`, `metadata = {"dependency_versions": …}` `:198-202,230-231`; `.pkl` and `save_program=True` → cloudpickle `:204-218,241-247`); `load` `:251-287` (**`dependency_versions[key]` for every key in the file → `KeyError` on a key upstream does not know**; mismatch → warning only).
- `predict/predict.py`: `UNSAFE_LM_STATE_KEYS = {"api_base","base_url","model_list"}` `:25`; `_sanitize_lm_state` `:28-43` (drop them with a warning unless `allow_unsafe_lm_state`); `dump_state` `:74-97` (`traces`, `train`, `demos` as dicts, `signature`, optional `fields`, `lm`); `load_state` `:99-125` (reads `state["signature"]` and `state["lm"]` **directly**; every other key → `setattr`).
- `signatures/signature.py`: `dump_state` `:524-535` (`instructions` + per field `{prefix, description}` — **no names**); `load_state` `:537-545` (**positional** `zip(…, strict=False)`).
- `clients/base_lm.py`: `dump_state` `:217-237` (class marker, `model`, `model_type`, `cache`, `num_retries`, kwargs minus `api_key`).
- `utils/saving.py`: `get_dependency_versions` `:17-25` (`python`, `dspy`, `cloudpickle`).
- **Oracle tests:** `tests/predict/test_predict.py` — `test_lm_after_dump_and_load_state` `:66`, `test_instructions_…` `:148`, `test_demos_…` `:156`, `test_typed_demos_…` `:187`, `test_signature_fields_…` `:284`, `test_lm_field_…` `:309`, `test_load_ignores_serialized_endpoint_override_by_default` `:332`, `…_with_opt_in` `:356`, plus the LM-class tests `:95-129`; `tests/utils/test_saving.py` — `test_save_predict` `:10`, `test_save_custom_model` `:23`, `test_save_model_with_custom_signature` `:40`, `test_save_compiled_model` `:61`, `test_load_with_version_mismatch` `:85`, `test_json_file_loading_works_without_permission` `:166`. The three pickle tests (`:136`, `:150`, and the pickle half of others) are **n/a** (D3).

Facts about our side (read at `8390cfb`):
- `Dspy.Predict` is `defstruct [:signature, :examples, :max_retries, :max_output_retries, :adapter, :callbacks]` — **no `lm`, no `config`** (`predict.ex:11`). → D2.
- Every module implements `parameters/1` by hand; **nothing walks sub-modules**, and names are flat (`"predict.examples"` from both Predict and ChainOfThought, `predict.ex:46`, `chain_of_thought.ex:78`). → A2.
- `Dspy.Signature` is a runtime struct `[:name, :input_fields, :output_fields, :instructions]` — per-instance instructions work today via `"predict.instructions"`.
- Upstream 3.4.0 adapters **never read a field's `prefix`** (only a commented-out line in `predict/retry.py:19`): prefix is inert data we can carry without rendering.

## Why
"Optimize once, save, load later or elsewhere and get the same behaviour" is the M2 promise. Upstream's documented path is the JSON state file; pickle is only for whole-program save (n/a, D3).

## (a) Contract

### A1. Public API
```elixir
Dspy.Module.save(program, path)                 :: :ok | {:error, term()}          # path must end in ".json"
Dspy.Module.load(program, path, opts \\ [])      :: {:ok, program} | {:error, term()}
Dspy.Module.dump_state(program)                 :: map()                            # string keys, JSON-encodable
Dspy.Module.load_state(program, state, opts \\ []) :: {:ok, program} | {:error, term()}
Dspy.Module.named_predictors(program)           :: [{path :: String.t(), predictor}]
#   opts: allow_unsafe_lm_state: false
```
`load`/`load_state` **return a new program**; the argument is never changed (upstream's "trial run on a deep copy" `:170-172` comes free with immutable values). Errors are `{:error, reason}` tuples, in the style of `apply_parameters/2`; a malformed *file* (bad JSON, wrong extension) is `{:error, …}` too, never a crash.

### A2. Named predictor paths (upstream `named_parameters` `:24-66`)
`named_predictors/1` walks struct fields recursively, in **field-name order** (sorted — map order must never decide anything, B2 lesson):
| Found | Path |
|---|---|
| the program itself is a predictor (`Predict`) | `"self"` |
| a field holding a predictor | `"<field>"` |
| a field holding a module | `"<field>.<sub path>"` |
| a list | `"<field>[<i>]"` (then `.<sub>` for a module) |
| a map | `"<field>['<key>']"` (key via `to_string`) |
`Dspy.ChainOfThought` reports its predictor at `"predict"` — upstream's CoT is a Module wrapping `self.predict` — so a bare CoT dumps `{"predict": …}` and a CoT in field `cot` dumps `{"cot.predict": …}`, exactly as upstream. Divergences, declared: no identity de-duplication (two equal structs at two paths are two entries — Elixir has no object identity); no "pre-compiled sub-module is frozen" rule (we have no `_compiled` flag) — D4.

### A3. What one predictor's state contains (upstream `predict.py:74-97`)
```json
{"traces": [], "train": [],
 "demos": [ {"question": "…", "answer": "…"} ],
 "signature": {"instructions": "…",
               "fields": [ {"name": "question", "prefix": "Question:", "description": "…"}, … ]},
 "lm": null}
```
- `demos`: each demo's fields as a JSON object with string keys (upstream `demo.toDict()`), in signature order is not required (objects are unordered).
- `signature.fields`: **every field, inputs then outputs, in signature order**, each with upstream's two keys **plus `"name"`**, which upstream's loader ignores (it reads `prefix`/`description` by key, `:541-543`). `prefix` is carried as opaque data: a loaded prefix is preserved; for a field never loaded we write `"<name>:"`. It is never rendered (upstream adapters don't render it either).
- `traces`, `train`: always written as `[]` (we have no such fields); non-empty on load → ignored with a warning (A5).
- `lm`: per **D2**. Never contains `api_key`.
- Not saved, as upstream: structure, `config`, `adapter`, `max_retries`, `max_output_retries`, `callbacks` (code-owned).

### A4. File envelope and interop with Python (D1 = yes)
```json
{"<path>": <predictor state>, …,
 "metadata": {"dependency_versions": {},
              "dspy_ex": {"dspy_ex": "0.x.y", "elixir": "1.19.5", "otp": "28"}}}
```
- **`metadata.dependency_versions` MUST be an empty object.** Upstream's loader does `dependency_versions[key]` for every key in it (`base_module.py:276-287`) — any key it does not know (`elixir`, `otp`, `dspy_ex`) raises `KeyError` and Python cannot load the file at all. Our versions go under `metadata.dspy_ex`, which upstream never reads.
- Must always be present for upstream to load it: `metadata.dependency_versions`, `signature` and `lm` in every predictor state, and one entry per upstream path.
- Reading a Python-written file: its `dependency_versions` (`python`, `dspy`, `cloudpickle`) are recognised as "written by Python DSPy" → one info log, no comparison.

### A5. Load rules — raise versus warn, by the corrupt-or-lose principle
| Situation | Upstream | Ours | Why |
|---|---|---|---|
| A path in the program is missing from the file | `KeyError` | `{:error, {:missing_state, path}}` | parity |
| A path in the file is not in the program | ignored | ignored + **warning** | Horst ruling F-4: file untouched, nothing lost; declared |
| Unknown key inside a predictor state | `setattr` | ignored + **warning** | F-4, declared |
| Field names in the file (our files) don't match the signature's (set, order) | n/a | `{:error, {:signature_mismatch, path, details}}` | **F-1: upstream relabels by position silently → we refuse** |
| No names (Python files), field **count** differs | silently truncates (`strict=False`) | `{:error, {:signature_mismatch, …}}` | F-1 |
| No names, same count | positional | positional (the only information there is) | parity, declared |
| `.pkl` or no `.json` suffix | pickle / `ValueError` | `{:error, {:unsupported_format, …}}` naming `.json` | D3 |
| Invalid JSON / not an object | orjson error | `{:error, {:invalid_state_file, …}}` | – |
| `api_base` / `base_url` / `model_list` in `lm` | dropped + warning unless opted in | same (`allow_unsafe_lm_state: true`) | parity |
| `metadata.dspy_ex` versions differ from ours | (n/a) | warning only | F-5, parity with upstream's warn-only |
| Loaded demo has string keys | dicts | `Dspy.Example` with **string keys** — no atom creation from file data | BB2/B2 lessons |

### A6. Invariants
1. Loading never creates atoms from file data (paths, field names, demo keys, LM class names); lookups use `String.to_existing_atom/1` or an explicit allowlist.
2. `save → load` on the same program gives `dump_state` equal to the original (upstream's own assertion, `test_saving.py:177`).
3. **The rendered prompt after load equals the prompt before save** for the same inputs — the real "behaves the same" check, since demos come back with string keys.
4. H0/H0b-2/M1 semantics, `test/consumer_contract/**`, `mix.exs`: unchanged. No new dependency (Jason).
5. `save` writes the whole file in one `File.write!/2` after encoding in memory (M1-a 10d rule: no partial file).

### A7. Forbidden
Pickle or `:erlang.term_to_binary` for the state file; `String.to_atom`/`List.to_atom` on file data; deciding path order or field order from map iteration; positional restore of our own files (they carry names); silently truncating on a field-count mismatch; mutating the caller's program; writing any key into `metadata.dependency_versions`.

### A8. Non-goals
Whole-program save (`save_program=True`), `dspy.load(dir)`, `.pkl` state (D3); `config` round trip (not saved upstream either); `Settings` save/load (S004, separate row).

## (c) Acceptance map
Tiers: **[T]** ported upstream test · **[X]** cross-language fixture from the committed generator (Python writes, we read; we write, Python reads) · **[–]** contract behaviour. **Shapes** = which of the relevant shapes the row covers.

| # | Tier | Scenario | Shapes | Mutation that must turn it RED |
|---|---|---|---|---|
| 1 | T | Predict: instructions round-trip (`test_instructions_after_dump_and_load_state`) | Predict alone (`"self"`) | instructions not restored |
| 2 | T | Predict: demos round-trip (`test_demos_…`) | demos with atom keys → loaded with string keys | demos dropped on load |
| 3 | T | Signature fields: descriptions round-trip (`test_signature_fields_…`); the test changes an **output** field's description too, otherwise the mutation cannot show | inputs and outputs | descriptions restored to inputs only |
| 4 | – | **Rendered prompt equal after load** (A6.3) for a Predict with 2 demos | atom-keyed demos before, string-keyed after | loaded demos not rendered (string keys unread) |
| 5 | X | **Load a Python-written file** for: a bare Predict (`self`), a CoT (`predict`), a custom module with a predictor field, a list of predictors (`[0]`,`[1]`) and a map of predictors (`['a']`) — resulting `dump_state` equals the Python file's predictor states. **Every predictor in the fixture carries distinct instructions**, otherwise a path swap is invisible | all five path shapes | list paths named `[1]` ↔ `[0]` swapped; map key via `inspect/1` (`['a']` vs `[':a']`) |
| 6 | X | **Python loads our file** (the generator loads our committed fixture with upstream `load` and re-dumps) — no exception, same instructions/demos/descriptions | same five shapes | any key written into `dependency_versions` (Python `KeyError`); `lm` or `signature` key omitted |
| 7 | – | Our file: field names reordered in the file → `{:error, {:signature_mismatch, …}}` | names present | positional restore of named files |
| 8 | X | Python file with one field fewer than our signature → `{:error, {:signature_mismatch, …}}` | no names, count differs | `Enum.zip` truncation (upstream `strict=False`) |
| 9 | – | Path in program missing from file → `{:error, {:missing_state, "cot.predict"}}`; extra path in file → loads, warning logged | missing / extra | extra path raising; missing path defaulting silently |
| 10 | – | Unknown key in a predictor state, non-empty `traces` → loads, warning logged | unknown key / known-but-unsupported | raising on unknown keys |
| 11 | T | `lm` with `api_base` / `base_url` / `model_list` dropped with a warning by default, kept with `allow_unsafe_lm_state: true` (`test_load_ignores_serialized_endpoint_override_by_default`, `…_with_opt_in`) | each of the 3 keys | sanitisation skipped |
| 12 | – | `.pkl` path, no suffix, invalid JSON, a JSON array → `{:error, …}` naming the problem; the program is unchanged | 4 shapes | raise instead of `{:error, _}` |
| 13 | – | No atoms created: load a file whose paths, field names and demo keys are never-seen names built at runtime; `String.to_existing_atom/1` still raises for each afterwards | paths / fields / demo keys | `String.to_atom` anywhere in the load path |
| 14 | T | Version mismatch in `metadata.dspy_ex` → warning, load succeeds (`test_load_with_version_mismatch`) | ours / Python-written | raising on mismatch |
| 15 | – | A multi-path file whose **second** path is bad returns `{:error, _}` — never `{:ok, program}` with only the first path applied. (The caller's value can't change in Elixir whatever the code does, so "argument untouched" would be an invisible row; the real risk is a half-loaded success.) | first path OK, second bad | returning `{:ok, partially_loaded}` after skipping the bad path |
| 16 | – | `save` then `load` round trip: `dump_state` equal (upstream `test_saving.py:177`) for all five path shapes | all | any field dropped from dump |
| 17 | – | `save` writes no partial file when encoding fails (a PID in a demo) | – | `File.open` before encoding |
| 18 | – | Full suite + consumer canary green; `git diff test/` additions only; the cross-language generator re-runs and its fixtures equal the committed ones | – | – |

## (d) Pre-mortem
1. **Only tests Elixir → Elixir.** Every round trip passes while Python cannot read our file (the `dependency_versions` `KeyError`) or we mis-name paths. → Rows 5 and 6, both directions, generated.
2. **Walks `Map.from_struct/1` in map order.** Paths and field order then depend on the runtime (B2). → A2 sorted order; row 5 with list/map shapes.
3. **Restores fields by position because upstream does.** Passes every same-signature test; silently mislabels after a signature edit. → Rows 7 and 8.
4. **Loaded demos keep string keys that our adapter does not read**, so the loaded program prompts without demos — every `dump_state` equality passes. → Row 4 compares rendered prompts, not state.
5. **`String.to_atom` on field names** "because signatures use atoms". → Row 13.
6. **Only the reported path shape** (a bare Predict). → Row 5 requires all five; row 16 too.

## (e) Echo-back
A1 signatures verbatim; the A2 path table; the A4 `dependency_versions` rule and why; the A5 table's four "ours ≠ upstream" rows and the reason for each; one sentence per A6 invariant.

## Decisions for Horst
- **D1 — Interop with Python files (my M2 findings decision #1, not yet ruled).** This contract assumes **yes**: read and write upstream's JSON shape, with rows 5–6 proving both directions via the committed generator. If **no**, drop rows 5, 6, 8 and A4's upstream constraints, and paths become ours to name.
- **D2 — Where a loaded `lm` goes (scope gap).** Upstream saves a per-predictor LM; our `Predict` has **no `lm` field** (and no `config`). The M2 findings put "Predict `config`/`set_lm`" first; the new slicing dropped it. Options:
  - **(a)** add a `lm` field to `Predict` in this slice, used when set and falling back to Settings — small, but it touches the LM request path (an invariant area, needs my co-sign);
  - **(b)** a separate slice before M2-a;
  - **(c)** always write `"lm": null`, and on load a non-null `lm` → ignore with a warning. That *drops file data*: a Python program with a per-predictor LM would load and quietly use the global LM — the corrupt-or-lose principle says don't. I recommend **(b)**, and if not (b) then (a). And if an `lm` is restored: upstream's class marker is a *Python* class path; mapping `dspy.clients.lm.LM` onto our default LM needs a model-string translation (`openai/gpt-4o-mini` in LiteLLM form vs our provider's form) — a separate question I'd rather see ruled with (b).
- **D3 — Pickle: not applicable.** `save_program=True`, `.pkl` state and `dspy.load(dir)` serialise Python objects. Recommend declaring them n/a in COMPATIBILITY; a `.pkl` path returns an error pointing at `.json`.
- **D4 — Two `named_parameters` rules we cannot port:** identity de-duplication (no object identity on the BEAM) and freezing pre-compiled sub-modules (no `_compiled` flag). Recommend: declare both.

## (b) Team card — Horst.

## (f) Clarity Gate
- Greta ☐ — signs once D1–D4 are ruled.
- Horst ☐
