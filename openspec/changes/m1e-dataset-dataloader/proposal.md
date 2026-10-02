# M1-e — Dataset and DataLoader (local CSV / JSON only)

Status: **DRAFT, REFRESHED TWICE (Greta 2026-09-30; post-H15 2026-10-02). E1–E9, T1–T4 ruled (Horst); new rulings Q1–Q3 needed.** Needs the team card and both signatures. Paper only. **Unblocked:** M1-d shipped v0.4.4, H15 shipped v0.4.5 (`1870d80`). Order now: M1-e → H16.
Queue: `PARITY_QUEUE.md` §M1 rows **U003** (Dataset) and **U002** (DataLoader, local files only). `from_huggingface`, `from_pandas`, `from_parquet`, `from_rm` stay in the M7+ pool.
Base: `main` at `3789ca3` (v0.4.5 + HOW_WE_WORK lessons). NimbleCSV is already a dependency (M1-a). **Carries the M1 exit example** (row 22); M1-d has landed, so the row stays here.

Reference, anchored to DSPy **3.4.0** (`../dspy-3.4.0`, tag `3.4.0`):
- `dspy/datasets/dataset.py`: constructor `:13-32` (`train_seed=0`, `eval_seed=0` shared by dev **and** test `:25-27`, sizes `None` = all, `do_shuffle = True` `:30`); `reset_seeds` (`None` keeps the old value) `:34-56`; `train`/`dev`/`test` lazily computed and cached `:58-77`; `_shuffle_and_sample` = `random.Random(seed).shuffle`, then `[:size]`, then one `Example` per row with a random `dspy_uuid` and `dspy_split` `:79-103`; `prepare_by_seed` `:105-139`.
- `dspy/datasets/dataloader.py`: `from_csv` `:63-76` and `from_json` `:91-104` (both through HF `datasets.load_dataset`, fields default to all columns, `with_inputs(*input_keys)`); `sample` = global `random.sample` `:138-150`; `train_test_split` = **global** `random.seed(random_state)` then `random.shuffle`, `int(len * frac)` truncation, validation errors `:152-198`.
- CPython 3.11 `random.Random.shuffle` / `_randbelow_with_getrandbits` / `sample` (read from the interpreter, `inspect.getsource`).
- **Oracle:** `tests/datasets/test_dataset.py` — 3 tests: `reset_seeds` accepts zero `:39-48`, keeps omitted values `:51-61`, `input_keys` via a CSV subclass (pandas, marked `extra`) `:64-74`. Nothing tests the loaders. So loader behaviour below comes from a **probe of upstream 3.4.0**, now committed at `plan/research/m1e-refresh-2026-09-30/ck_loaders.py` with its output `ck_loaders.out` (first run 2026-09-28 from a scratchpad file that did **not** survive the session — re-created and re-run 2026-09-30, all 17 loader observations and the `train_test_split` result identical). It is the seed for the committed generator (R6).

## Why
The M1 exit example starts with "load a CSV with DataLoader", and every tutorial starts from a `Dataset` split. Seeded splits are how results get compared between runs — and between Python and Elixir.

## Refresh 2026-10-02 — after H15 (read this before the 2026-09-30 refresh below)

**What H15 changed, and what that means here.** Verified on `3789ca3`:
- **P1 and P2 are fixed** (v0.4.5). Every read of a user-supplied `attrs` field now goes through one internal accessor, `Dspy.Attrs`: an atom key finds the atom key first, then its string form. `Example.get/fetch`, `Prediction.get/fetch`, the metrics, demo rendering (Default, JSON and Chat), `Trainset`, `Ensemble`, `MultiChainComparison` and `majority` (T4) all use it.
- **Rows 24, 25, 27 and 28 change role.** They stop being "the bug fix" and become **regression pins on loader output**. H15 proved each site with hand-built string-keyed fixtures; M1-e proves that **what the loaders actually emit**, read back from disk, reaches those sites. Their mutations now target `Dspy.Attrs` and the H15 call sites (Q2).
- **Probe today** (`scratchpad m1e_probe.exs`, CapLM fake): a loader-shaped `Example.new(%{"question" => …, "answer" => …})`
  - `with_inputs([:question])` and `with_inputs(["question"])` both give `inputs = %{"question" => …}`. Input names are normalised to strings (`example.ex:212`), so **row 11's atom-name case already works** and is pinned rather than built.
  - `Predict` forward with the string-keyed inputs → `{:ok, …}`, with the question present in the prompt.
  - `Evaluate` with `answer_exact_match` → **100.0**.
  - **Nothing in the consumer chain needs an M1-e workaround.**
- **Rows that assumed atom keys or worked around the old bug:**
  - row 11's "atom key names not matched to string attrs" mutation now targets shipped code (`normalize_input_key!`), so it is declared as such (MD7b);
  - row 25's old asymmetry note ("Chat green") still holds for the `format_fields` revert, but the shared-accessor break now reddens Chat as well. Both are declared;
  - the 2026-09-30 P1/P2 paragraphs and the T3 "~12 sites" scope are **history**, kept only for the record.
- **Wording fix:** `Dspy.Example` has **no `labels/1`** (verified). E5's rationale is corrected to "would leak into `inputs`/keys, metrics and saved files".
- **New rule for M1-e's own code:** any read of an example field by a fixed key in the new modules (`Dataset`, `DataLoader`) goes through `Dspy.Attrs` or `Example.get/fetch`, never `Map.get(attrs, :k)`. This is pinned statically by row 35. Upstream keys are strings, so the H15 class must not re-enter through the slice that produces string keys at scale.

**What the mechanical checks (H20) change here:**
- **C2:** the harness is `plan/research/upstream_golden/mutate_m1e.py` **on `plan/research/harness/mutlib.py`**. Every acceptance row is a test named `row N…:`, claimed by a declared `Mutation(expect=…, kind=…)`; the section "(c2) Declared mutations" below is normative. An unclaimed row fails the run (C3a). `kind: any` is **not** allowed in this slice.
- **`also` lists are observed, not written ahead** (HOW_WE_WORK, lesson 2026-10-02): start each one empty, run the harness, and copy in exactly the failures it reports outside `expect`. The review checks `also == failed − expect` mechanically.
- **The harness report goes to `plan/research/pi_handoffs/m1e/logs/`, not the repo root.** H15's harness left `mutation_report.json` there.
- **C5, `deviations.json`** (a required artifact per slice, ruled 2026-09-30): `test/fixtures/m1e_deviations.json` lists every fixture case where ours differs from upstream on purpose, as `{case_id, upstream, ours, reason}` (E2, E3, E4, E6 and the E5 uuid). Row 34 asserts that this set **equals** the set of fixture cases where our observed result differs from upstream's. The generator (R6) must give every case a stable `case_id` (Q3).

## Refresh 2026-09-30 — what changed since this contract was written (P1/P2/T3 parts: history, fixed by H15)

M1-e's loaders **manufacture string-keyed data at scale**. Since 2026-09-28 three separate defects came from exactly that shape (M1-a BB2: string keys did not collide; M1-c BD1: a fix handled atom keys only; and the two below). So this refresh re-checks every shipped consumer against **loader-shaped input**, measured at `b20a8c5`, not read from contracts. Evidence scripts: `plan/research/m1e-refresh-2026-09-30/`.

### P1, P2 — prerequisites: two live bugs in shipped code, one class (atom-only field lookup on `attrs`)
- **P1 (M1-b metrics, shipped since v0.4.1).** `Dspy.Metrics.answer_exact_match/2,3` and `answer_passage_match/2` read fields with `Map.fetch(attrs, :answer)` / `(:context)` (`fetch_field!/2`, `fetch_context!/2` in `lib/dspy/metrics.ex`). A string-keyed example — every example `from_csv`/`from_json` will ever produce — raises `"example[:answer] is missing"`, although `Access.get(example, :answer)` returns the value. In `Evaluate` every loaded example therefore scores `failure_score` and the run aborts at `max_errors`. **Loud, not silent.** My M1-b contract never listed the string-key shape.
- **P2 (demo rendering, shipped long before M1).** `Dspy.Signature.format_example/3` (`lib/dspy/signature.ex:470-480`) reads demo fields with `Map.get(example.attrs || example, field.name, "")` — atom-only **with a silent `""` default**. It is used by the **Default adapter and the JSONAdapter** (4 of 5 consumers). A string-keyed demo is rendered with **empty values**; nothing raises. `ChatAdapter` is correct (it uses `Dspy.Example.get/2`). Probe: `demo_probe*.exs` — atom-keyed demo in the prompt `true`; string-keyed `false` for Default and JSON, `true` for Chat. **Silent** — `LabeledFewShot`/`BootstrapFewShot` over a loaded trainset would optimise with empty demos and report nothing.
- **Scope:** 27 `Map.get/fetch/has_key?` calls on `attrs` in `lib/`; 15 are inside `example.ex`/`prediction.ex` (where the fallback is implemented); **~12 call sites** to audit (`trainset.ex` 4, `metrics.ex` 4, `ensemble.ex` 2, `signature.ex` 1, `multi_chain_comparison.ex` 1), plus pattern-matched `%{attrs: %{answer: _}}` heads (not counted). → **T3**: one audit slice before M1-e.

### R1 — key type, stated as a contract rule
Loaders emit **string keys only** (upstream keys are strings; no atoms from file data — B2). No mixing: a loaded example never carries both `"k"` and `:k`. Every shipped consumer must be **tested with loader output**, not with hand-built atom-keyed fixtures — acceptance rows 24–30 (the consumer matrix).

### R2 — read/write coherence, made concrete against the shipped `save_as_csv`/`save_as_json`
Measured (`rt_probe.exs`): an `Evaluate` over string-keyed examples containing a comma, quotes, a newline, a `nil` and a `""`, with one failing example, saved and re-parsed under A4's load rules:

| Value / shape | CSV round trip | JSON round trip |
|---|---|---|
| comma, `"` escape, embedded newline | identical | identical |
| metric `1.0` | `"1.0"` (a string — E2) | `1.0` |
| `nil` | `nil` | `nil` |
| `""` | **`nil`** — CSV cannot tell `""` from missing | `""` |
| a key present in other rows but absent in this one (a failed row has no prediction keys) | **present, `nil`** — CSV has no "absent" | **present, `nil`** — A4's union-of-keys rule (upstream parity) |

So "identical data" is not literally achievable; the contract states the exact equivalence instead (row 20a/20b). "If load and save disagree, one of them is wrong" is decided by those rows: every difference must be one of the three declared losses above, nothing else.

### R3 — the CSV value-type ruling (E2) re-examined against M1-b
- **Holds for the standard metrics.** A CSV label `"2"` against an LM answer `"2"`: `answer_exact_match` matches — once P1 is fixed. Upstream's pandas inference would have made the label the integer `2`, and upstream's own `answer_exact_match` raises `"Invalid answer type"` on it (`metrics.py:312-317`). Strings are what make the standard metric work.
- **JSON keeps JSON types** — a JSON label `2` makes `answer_exact_match` raise `ArgumentError` in ours and `ValueError` upstream. Parity; declared; row 29.
- **New concern, not covered by E2's reasoning:** a user-written metric `example["answer"] == pred.answer` with a **typed** output field (`:integer`) compares `"2"` with `2` → `false` → the example **silently scores 0**. Upstream's inferred integer would compare equal. E2 fixes one silent failure and leaves this one. → **T1**.

### R4 — seeded sampling (A2 stands; new evidence)
A2's CPython-MT19937 design (E1, ruled) is unchanged. New: **shipped code already samples the B2 way** — **6 `:rand.seed(:exsss, …)` calls** followed by `Enum.shuffle`/`Enum.random` (`lib/dspy/evaluate.ex:908`, `lib/dspy/trainset.ex:103,144,184`, `lib/dspy/teleprompt/bootstrap_few_shot.ex:234,365`), each result depending on the Elixir release and each **mutating the caller's own `:rand` state**; plus **4 unseeded** `Enum.shuffle`/`Enum.random` calls (`trainset.ex:187,377,385,391`). M1-e must not add another (row 4 pins that). And `Dspy.Trainset` (`split/2`, `sample/3`, …) already overlaps `DataLoader.train_test_split/2`/`sample/3`; only `trainset.ex` itself and one test reference it. → **T2**.

### R5 — today's rules applied to the acceptance map
Every row now names the **shapes** it covers; every mutation was checked for "does it change the result on at least one input, for the reason it claims". Harness requirements (R7) carry the standard as it stands after H12.

### R6 — COMPATIBILITY settled against a generated oracle, not memory
A committed generator `plan/research/upstream_golden/gen_m1e_golden.py` (seeded from `ck_loaders.py`) writes `test/fixtures/upstream_m1e_3_4_0.json`: every A4 CSV and JSON row (input file content → upstream result) **and** the MT19937 / `shuffle` / `sample` / `train_test_split` vectors of rows 1–3, 8, 21. Every loader claim in COMPATIBILITY cites a fixture row. The review re-runs the generator and diffs.

### R7 — mutation harness (superseded 2026-10-02 by C2, see the post-H15 refresh)
`mutate_m1e.py` on `mutlib.py`. The library supplies, so the slice does not hand-write them: in-memory restore, the SIGTERM/SIGHUP handlers, the debris pre-flight, the base-green check, and the NOT-APPLICABLE/AMBIGUOUS/INVALID hard failures. Still the slice's job: **per-caller reverts** wherever a shared helper exists, and **breaking each shared helper**:
- `Dspy.Random` is shared by `Dataset.train/1`, `DataLoader.sample/3` and `train_test_split/2`;
- one row→Example builder is shared by `from_csv` and `from_json`.

Breaking a helper must redden every caller's row, and reverting one caller must redden only that caller's row.

## (a) Contract

### A1. Signatures
```elixir
Dspy.Dataset.new(opts) :: %Dspy.Dataset{}
#   train: [map | Example.t()] | nil, dev: … | nil, test: … | nil    # raw rows (upstream _train/_dev/_test)
#   train_seed: 0, train_size: nil, eval_seed: 0, dev_size: nil, test_size: nil,
#   input_keys: [], shuffle: true                                      # upstream do_shuffle
Dspy.Dataset.train(ds) :: [Example.t()]          # also dev/1, test/1
Dspy.Dataset.reset_seeds(ds, opts) :: %Dspy.Dataset{}   # a key that is absent keeps its value
Dspy.Dataset.prepare_by_seed(ds, opts) :: %{train_sets: [[Example.t()]], eval_sets: [[Example.t()]]}
#   train_seeds: [1,2,3,4,5], train_size: 16, dev_size: 1000, divide_eval_per_seed: true, eval_seed: 2023

Dspy.DataLoader.from_csv(path, fields: nil, input_keys: [])  :: [Example.t()]
Dspy.DataLoader.from_json(path, fields: nil, input_keys: []) :: [Example.t()]
Dspy.DataLoader.train_test_split(examples, train_size: 0.75, test_size: nil, seed: nil) :: %{train: [...], test: [...]}
Dspy.DataLoader.sample(examples, n, seed: nil) :: [Example.t()]

Dspy.Random   # internal (@moduledoc false): the generator of A2, a pure value, no process state
```
Module functions, not a stateful loader: upstream's `DataLoader()` carries no state.

### A2. Seeded randomness (Horst's question 1)

**What Elixir/OTP guarantee — checked in the installed docs, not assumed:**
- `Enum.shuffle/1` "uses Erlang's `:rand` module" and takes no state argument, so it can only use the `:rand` state stored **in the calling process's dictionary**. Seeding it means `:rand.seed/2`, which **mutates the caller's own random state** — a side effect on the user's process.
- `:rand` documents that a seeded sequence is reproducible for the same algorithm and seed, but the *default* algorithm is only "`exsss` … since OTP 22" — release-dependent by wording.
- `Enum.shuffle/1`'s documentation makes **no promise about which permutation** it returns for a given `:rand` state. How it consumes random numbers is an implementation detail of the Elixir release.
- **Conclusion: nothing guarantees that `Enum.shuffle` with a seed gives the same order across Elixir or OTP versions.** Leaning on it would be B2 again — correct today by accident of the runtime.

**What we do instead: our own generator, specified exactly, and chosen to equal CPython's.**
- **MT19937** (Matsumoto–Nishimura, 624-word state, standard tempering), seeded exactly as CPython seeds from an integer: `s = abs(seed)`; key = `s` split into 32-bit words, least-significant first (`[0]` for 0); `init_by_array(key)`.
- `getrandbits(k)`, `1 ≤ k ≤ 32` = `genrand_uint32() >>> (32 − k)`.
- `randbelow(n)` = `k = bit_length(n)` — **of `n`, not `n − 1`** — then draw `getrandbits(k)` until `< n`.
- `shuffle(xs)`: for `i` from `len − 1` down to `1`: `j = randbelow(i + 1)`; swap `i` and `j`.
- `sample(xs, k)`: CPython's algorithm including its two branches (pool vs set, chosen by `setsize = 21 + 4 ** ceil(log(3k, 4))` for `k > 5`, computed in IEEE doubles as CPython does).
- Only integer seeds (anything else → `ArgumentError`).
- **Guarantee we give:** the same integer seed yields the same order on every Elixir and OTP version. It is pure integer arithmetic over a list — no `:rand`, no process dictionary, no map iteration order — and it is pinned by golden vectors.
- **Bonus we get:** the same seed gives **the same split as Python DSPy**. Verified by probe: `Random(0).shuffle(range(10))` = `[7,8,1,5,3,4,2,0,9,6]`, and upstream `train_test_split(…, train_size=0.7, random_state=0)` = train `[7,8,1,5,3,4,2]`, test `[0,9,6]`. Honest limit: Python only promises reproducibility of `random()` across versions; `shuffle`'s algorithm has not changed since 3.2 but is not promised. Our side is fixed by our vectors either way.

### A3. Dataset behaviour
- `train/1` = rows of the `train` split → `shuffle` with `train_seed` (when `shuffle: true`) → first `train_size` → `Example`s; same for `dev`/`test`, which **both use `eval_seed`** (upstream `:25-27`).
- Size: `nil` → all; `0` → `[]`; larger than the split → all. **Negative → `ArgumentError`** (E6).
- A row that is a map becomes `Example.new(row)`; an `%Example{}` is kept. `input_keys` non-empty → `with_inputs(input_keys)`.
- Pure: the same dataset returns equal lists on every call (no caching needed, because no random uuid — E5).
- `reset_seeds/2`: only keys **present** in `opts` change; `0` is a value, not "unset" (oracle `:39-61`); `eval_seed` sets both dev and test seeds. (Upstream cannot tell "omitted" from `None`, so an explicit `nil` also keeps the old value — parity, pinned.)
- A split that was never given (`nil`) → `ArgumentError` on access (upstream `AttributeError`); an empty list is a valid empty split.
- `prepare_by_seed/2`: upstream `:105-139` — one eval set from `dev` with `eval_seed`, one train set per train seed, eval slices of `dev_size / length(train_seeds)` when dividing; a length mismatch → `ArgumentError` (upstream `assert`).

### A4. Loader rules (Horst's question 2) — and how they line up with M1-a's `save_as_csv`

**Keys: strings, always.** Upstream's keys are strings too. Our `Example` already reads a string key through an atom (`example.ex:165-178`), and signatures accept string-keyed inputs (`signature.ex:201-204`). **Loaders never create atoms from file data** (the B2 lesson — the atom table is VM-global and its order leaked into our CSV columns). `fields:` may be given as atoms or strings, matched by `to_string`.

**CSV** — RFC 4180 through the same `NimbleCSV.RFC4180` module M1-a writes with:

| Input | Upstream 3.4.0 (probe) | Ours | Parity? |
|---|---|---|---|
| Header | first record = column names | same; required | yes |
| Quoted field, `""` escape, comma inside quotes | parsed | parsed (NimbleCSV, verified) | yes |
| Embedded newline inside quotes | kept (`'l1\nl2'`) | kept | yes |
| CRLF and LF line endings | both | both (verified; M1-a writes CRLF) | yes |
| Leading UTF-8 BOM | stripped | **stripped explicitly** (NimbleCSV keeps it in the first header — verified) | yes |
| Blank line | skipped | **skipped explicitly** (NimbleCSV returns it as `[""]` — verified) | yes |
| Empty cell, or quoted `""` | `None` | `nil` | yes |
| Short row (fewer fields) | missing cells `None` | missing cells `nil` | yes |
| **Long row (more fields)** | **silently corrupts the row**: `{'q': 1, 'a': 'EXTRA', '__index_level_0__': 'x'}` | **`ArgumentError` naming the line** | **no — E3** |
| **Duplicate header** | renamed `a.1` | **`ArgumentError` naming the column** | **no — E4** |
| **Cell types** | inferred per column (`"2"` → `2`, `"True"` → `True`; a missing cell turns the column into floats: `2` → `2.0`) | **every cell is a string** | **no — E2** |
| Surrounding whitespace | kept | kept | yes |
| `fields:` subset | in the given order | same | yes |
| Unknown field in `fields:` | `KeyError` | `ArgumentError` naming it | yes |
| File not UTF-8 | (pandas error) | `ArgumentError` | – |

**Coherence with `save_as_csv` (M1-a):**
- Both sides use `NimbleCSV.RFC4180`. The save writes a full row for every example and raises rather than writing a key outside the header, so it **never writes a long row**. With the string-key collision fix, it also never writes a duplicate header. So **the loader never rejects our own output.**
- The ragged rules are symmetric. *Extra* is an error both ways (save: a key outside the header; load: a field outside the header). *Missing* is empty both ways (save writes `""`; load reads `nil`).
- **Round trip:** for rows whose values are non-empty strings, `from_csv(file written by save_as_csv)` returns the same key/value pairs (string keys). Declared losses, inherent to CSV: `nil` and `""` both come back as `nil`, and numbers come back as strings (JSON is the typed format).

**JSON:**

| Input | Upstream (probe) | Ours |
|---|---|---|
| A JSON array of objects (what M1-a's `save_as_json` writes) | read | read |
| JSON Lines, one object per line | read | read; blank lines skipped. Array vs JSONL decided by the first non-whitespace byte (`[` = array) |
| Keys missing in some records | filled with `None` (union of keys) | filled with `nil` (union of keys) |
| Nested objects / lists | kept | kept (string keys all the way down) |
| `null` | `None` | `nil` |
| A record that is not an object | raises (`TypeError`) | `ArgumentError` naming the record index / line |
| Types | JSON types kept | JSON types kept |

Coherence: `from_json(file written by save_as_json)` returns the same rows, keys as strings, values with their JSON types.

### A5. Invariants
1. No `:rand`, no `Enum.shuffle`/`Enum.random`/`Enum.take_random`, no process-dictionary state, no map iteration order anywhere in sampling.
2. No `String.to_atom`/`List.to_atom` on file data.
3. No network, no new dependency (NimbleCSV and Jason are already in).
4. `Dspy.Evaluate`, M1-a save rules, `test/consumer_contract/**`, `mix.exs`: unchanged.
5. `Dataset` and the loaders are pure functions of their inputs (plus the file contents).

### A6. Forbidden
`Enum.shuffle` with `:rand.seed` (the obvious implementation — see pre-mortem 1); `k = bit_length(n - 1)` in `randbelow`; mutating the caller's `:rand` state; creating atoms from headers or JSON keys; silently renaming a duplicate header; silently accepting a long row; pandas-style type inference (E2); a random `dspy_uuid` field (E5).

### A7. Non-goals
`from_huggingface`, `from_pandas`, `from_parquet`, `from_rm` (M7+ pool); string or bytes seeds (CPython hashes them with SHA-512); the `counts=` argument of `sample`; a dedup concept for examples (upstream's own TODO).

## (c) Acceptance map (refreshed 2026-10-02, C2 form)
**Tiers:** **[T]** ported upstream test · **[G]** golden from the committed generator (R6) · **[–]** contract behaviour.
**Shapes** = the input shapes a row must cover; a row that covers fewer is incomplete.
**Rows 20–30 use loader output:** files written to disk and read with `from_csv`/`from_json`, never hand-built examples.
**Claimed by** = the mutation ids from (c2) that have this row in `expect`.

Test file: `test/dspy/dataset_dataloader_test.exs` = `acceptance_files`. Rows 31–33 and 35 are static checks, listed in `exempt` with the reasons printed.

| # | Tier | Row (test name prefix `row N:`) | Shapes | Claimed by |
|---|---|---|---|---|
| 1 | G | Generator: first five `uint32` equal CPython's (seed 0 starts `3626764237`) | seeds `0, 1, 42, 2023, 2**32, 2**64+3, −5` | MG1, MG2 |
| 2 | G | `shuffle` permutations equal CPython's; seed 0, n 10 → `[7,8,1,5,3,4,2,0,9,6]` | n ∈ `{0,1,2,10,100,1000}` | MG3, MG4 |
| 3 | G | Generator `sample` equals CPython's (`[6,9,0]`, `[49,97,53]`) | pool branch; set branch; k = 6 at the `setsize` boundary | MG5, MG6, MG3 |
| 3b | G | **`DataLoader.sample(examples, 3, seed: 0)`** returns the rows CPython's `sample` picks | public entry, loaded examples | MC2, MG3 |
| 4a | – | `Dataset.train/1` leaves the caller's `:rand` state unchanged | caller seeded; caller never seeded | MC1 |
| 4b | – | same for `DataLoader.sample/3`, including `seed: nil` (E7) | seeded; unseeded; `seed: nil` | MC2, MC4 |
| 4c | – | same for `train_test_split/2`, including `seed: nil` | seeded; unseeded; `seed: nil` | MC3 |
| 5 | T | `reset_seeds` accepts zero for every key | all six keys | **exempt**: "oracle port; `0` is truthy in Elixir, so no natural mutation (row 5b holds the Elixir trap)" |
| 5b | – | `reset_seeds(ds, train_size: nil)` keeps the old size | explicit `nil`; key absent | MD1 |
| 6 | T | `reset_seeds(train_seed: 1)` keeps every other value, both eval seeds included | one key given | MD2 |
| 7 | – | dev and test share `eval_seed` (non-zero seed) | `eval_seed: 7` | MD3 |
| 8 | G | `train/1`, seed 0, size 7 over rows 0..9 → `[7,8,1,5,3,4,2]` | – | MD4, MC1, MG3 |
| 9 | – | Sizes: `nil` → all; `0` → `[]`; larger → all; negative → `ArgumentError` | four sizes | MD5 |
| 10 | – | `shuffle: false` keeps row order | – | MD6 |
| 11 | T | `input_keys` → inputs exactly those keys, against **string-keyed loaded rows** | names as strings; names as atoms | MD7, MD7b |
| 12 | – | `train/1` twice → `==` lists | – | MD8 |
| 12b | – | the split name is in `metadata["dspy_split"]`, and in no attrs key (E5) | train, dev, test | MD8b |
| 13 | – | `prepare_by_seed` → 5 disjoint eval slices, 5 train sets; too little dev data → `ArgumentError` | – | MD9 |
| 14a–14j | G | **CSV rows of A4**, one test each, expected values from the fixture | 14a BOM · 14b blank line · 14c CRLF/LF · 14d embedded newline + `""` escape · 14e empty + quoted-empty cell · 14f short row · 14g whitespace · 14h `fields:` order · 14i unknown field · 14j `input_keys` on `from_csv` | ML1 (a), ML2 (b), ML0 (c, d), ML3 (e), ML4 (f), ML5 (g), ML6 (h), ML6b (i), MB1 (j) |
| 15 | – | Long row → `ArgumentError` naming the line (E3) | extra field in row 2 and in the last row | ML7 |
| 16 | – | Duplicate header → `ArgumentError` naming the column (E4) | – | ML8 |
| 17 | – | CSV values stay strings (E2) | `"2"`, `"1.5"`, `"True"`, `"0x10"` | ML9 |
| 18 | – | No atom created: a never-seen header name built at runtime still makes `String.to_existing_atom/1` raise | CSV header; JSON key; nested JSON key | ML10 |
| 19a–19g | G | **JSON rows of A4**, expected values from the fixture | 19a array · 19b JSONL + blank lines · 19c union of keys → `nil` · 19d nested kept · 19e `null` · 19f non-object raises naming its index · 19g `input_keys` on `from_json` | MJ2b (a), MJ2 (b), MJ1 (c), MJ3 (d), MJ0 (e), MJ4 (f), MB2 (g) |
| 20a | – | CSV round trip with the shipped `save_as_csv` under the exact per-value map `c` (unchanged from 2026-09-30) | quoting ×3; `nil`; `""`; absent key; number | ML3, ML9 |
| 20b | – | JSON round trip with the shipped `save_as_json` | same shapes | MJ1, MJ5 |
| 21 | – | `train_test_split` sizes: `0.75` of 10 → 7/3; int `3` → 3/7; overflow → `ArgumentError`; `1.0` → `ArgumentError` | float; int; overflow; 1.0 | MT1 |
| 21b | G | `train_test_split(rows 0..9, train_size: 0.7, seed: 0)` → train `[7,8,1,5,3,4,2]`, test `[0,9,6]` (upstream probe) | – | MC3, MG3 |
| 22 | – | **M1 exit example:** `from_csv` → `Dataset` → `evaluate` ChainOfThought with `SemanticF1.metric/1`, `max_errors: 2`, one failing example → `save_as_json` → `from_json` | loader output end to end | MX1 |
| 24 | – | **Consumer, metrics:** a loaded CSV → `Evaluate` with `answer_exact_match` → scores equal to the same data with atom keys | string vs atom keys | MX1, MP1 |
| 25a | – | **Consumer, demos, Default:** loaded trainset → `LabeledFewShot.compile` → the request contains every demo value, byte-equal to the atom-keyed request | – | MX1, MX2 |
| 25b | – | same for JSONAdapter | – | MX1, MX2 |
| 25c | – | same for ChatAdapter (green under MX2: Chat never used `format_fields`) | – | MX1 |
| 26 | – | **Consumer, save writers:** loaded `"answer"` vs prediction `:answer` → `example_answer`/`pred_answer`, no duplicate column, CSV and JSON | string example × atom prediction | MV1 |
| 27 | – | **Consumer, `majority`** over string-keyed maps from `from_json` = atom-keyed result; a map with both forms raises | string maps; both forms | MX3, MX3b |
| 28 | – | **Consumer, M1-d judge:** `SemanticF1.metric/1` on a loaded example gives the same score as on an atom-keyed one, **and the judge's request contains the loaded question and response** | string vs atom keys | MX1 (see verify-first V1) |
| 29 | – | JSON numeric label `{"answer": 2}` + `answer_exact_match` → `ArgumentError` (parity: upstream `ValueError`) | integer; float | MJ5 |
| 30 | – | T1: `from_csv(path, types: %{"answer" => :integer})` → integers via the H12 `NumberParser`; `"80%"` → `ArgumentError` naming line and column; untyped columns stay strings | typed; untyped; strict reject | MT2, MT3 |
| 30c | – | T1 docs: the `from_csv` docstring names the silent-0 pitfall **and** `types:` | – | MT4 |
| 31 | – | R6: the generator re-runs and its fixture equals the committed one (metadata aside) | – | **exempt** (static; run in review) |
| 32 | – | The harness: 0 failures of any verdict, 0 UNCLAIMED, `also` lists observed | – | **exempt** (it is the harness itself) |
| 33 | – | Full suite + consumer canary green; `git diff test/` additions only; `test/consumer_contract/**` unchanged | – | **exempt** (gate) |
| 34 | – | **C5:** the case ids in `m1e_deviations.json` **equal** the fixture cases where our observed result differs from upstream's | E2, E3, E4, E6, E5 uuid | MC5 |
| 35 | – | Static: the new `lib/dspy/dataset.ex` and `lib/dspy/data_loader.ex` contain no `Map.get/fetch(…attrs…, :atom)` and no `String.to_atom`/`List.to_atom` | – | **exempt** (static grep, printed) |

## (c2) Declared mutations (normative)
- Each mutation: one `old` → `new` edit, `expect` = the rows above, and `kind`.
- **Every `also` list starts empty** and is filled only from observed failures.
- **Direction 1, revert each caller** of every shared helper (`Dspy.Random`, the row builder, and `Dspy.Attrs` via the H15 sites).
- **Direction 2, break each shared helper.**

| Id | File | Change | `expect` | `kind` |
|---|---|---|---|---|
| MG1 | `random.ex` | `init_by_array` key words most-significant first | 1 | assertion |
| MG2 | `random.ex` | seed used without `abs` | 1 | assertion |
| MG3 | `random.ex` | **shared break:** `randbelow` uses `bit_length(n − 1)` | 2, 3, 3b, 8, 21b | assertion |
| MG4 | `random.ex` | shuffle loop runs upward | 2 | assertion |
| MG5 | `random.ex` | `sample` always takes the pool branch | 3 | assertion |
| MG6 | `random.ex` | `sample` always takes the set branch | 3 | assertion |
| MC1 | `dataset.ex` | **caller revert:** `train/1` shuffles with `:rand.seed` + `Enum.shuffle` | 4a, 8 | assertion |
| MC2 | `data_loader.ex` | **caller revert:** `sample/3` uses `:rand.seed` + `Enum.take_random` | 3b, 4b | assertion |
| MC3 | `data_loader.ex` | **caller revert:** `train_test_split/2` uses `:rand.seed` + `Enum.shuffle` | 4c, 21b | assertion |
| MC4 | `data_loader.ex` | `seed: nil` falls back to the process `:rand` state (pre-mortem 11) | 4b | assertion |
| MD1 | `dataset.ex` | `reset_seeds` uses `Keyword.get(opts, k, old)` | 5b | assertion |
| MD2 | `dataset.ex` | `reset_seeds` resets omitted keys to defaults | 6 | assertion |
| MD3 | `dataset.ex` | test split uses its own seed, defaulting to 0 | 7 | assertion |
| MD4 | `dataset.ex` | take `size` before shuffling | 8 | assertion |
| MD5 | `dataset.ex` | negative size → `Enum.take(rows, n)` (drops from the end) | 9 | assertion |
| MD6 | `dataset.ex` | `shuffle:` flag ignored | 10 | assertion |
| MD7 | `dataset.ex` | `input_keys` not applied | 11 | assertion |
| MD7b | `example.ex` (shipped) | `normalize_input_key!` keeps atoms as atoms | 11 | assertion |
| MD8 | `dataset.ex` | adds `metadata["dspy_uuid"]` from `:crypto` | 12 | assertion |
| MD8b | `dataset.ex` | split name written into attrs `"dspy_split"` | 12b | assertion |
| MD9 | `dataset.ex` | eval slices not offset | 13 | assertion |
| ML0 | `data_loader.ex` | CSV parsed with `String.split(…, "\n")` + `String.split(…, ",")` instead of NimbleCSV | 14c, 14d | assertion |
| ML1 | `data_loader.ex` | BOM not stripped | 14a | assertion |
| ML2 | `data_loader.ex` | blank lines kept as rows | 14b | assertion |
| ML3 | `data_loader.ex` | `""` kept as `""` | 14e, 20a | assertion |
| ML4 | `data_loader.ex` | missing cells absent instead of `nil` | 14f | assertion |
| ML5 | `data_loader.ex` | cells `String.trim`med | 14g | assertion |
| ML6 | `data_loader.ex` | `fields:` subset returned in file order | 14h | assertion |
| ML6b | `data_loader.ex` | unknown field in `fields:` ignored | 14i | assertion |
| ML7 | `data_loader.ex` | long row: extra field dropped | 15 | assertion |
| ML8 | `data_loader.ex` | duplicate header: last one wins | 16 | assertion |
| ML9 | `data_loader.ex` | integer-looking cells → `String.to_integer` | 17, 20a | assertion |
| ML10 | `data_loader.ex` | keys via `String.to_atom` | 18 | assertion |
| MB1 | `data_loader.ex` | **caller revert:** `from_csv` builds `Example.new/1` itself, without the shared builder (no `input_keys`) | 14j | assertion |
| MB2 | `data_loader.ex` | **caller revert:** the same in `from_json` | 19g | assertion |
| MB3 | `data_loader.ex` | **shared break:** the builder ignores `input_keys` | 14j, 19g, 11 if `Dataset` uses the builder (observe) | assertion |
| MJ0 | `data_loader.ex` | `null` → `""` | 19e | assertion |
| MJ1 | `data_loader.ex` | union-of-keys fill dropped | 19c, 20b | assertion |
| MJ2 | `data_loader.ex` | input always parsed as a JSON array (JSONL fails) | 19b | assertion |
| MJ2b | `data_loader.ex` | input always parsed as JSONL (an array fails) | 19a | assertion |
| MJ3 | `data_loader.ex` | nested objects flattened to strings | 19d | assertion |
| MJ4 | `data_loader.ex` | non-object record skipped | 19f | assertion |
| MJ5 | `data_loader.ex` | JSON numbers → strings | 20b, 29 | assertion |
| MT1 | `data_loader.ex` | `round` instead of truncation | 21 | assertion |
| MT2 | `data_loader.ex` | `types:` parse via `Integer.parse` prefix (accepts `"80%"`) | 30 | assertion |
| MT3 | `data_loader.ex` | `types:` ignored | 30 | assertion |
| MT4 | `data_loader.ex` | pitfall sentence removed from the `from_csv` docstring | 30c | assertion |
| MC5 | `test/fixtures/m1e_deviations.json` | drop the E3 entry | 34 | assertion |
| MX1 | `attrs.ex` (shipped) | **shared break:** string fallback removed | 22, 24, 25a, 25b, 25c, 28 | assertion |
| MX2 | `signature.ex` (shipped) | **caller revert:** `format_fields` back to `Map.get(attrs, field.name, "")` | 25a, 25b | assertion |
| MX3 | `majority.ex` (shipped) | **caller revert:** map clause back to `Map.has_key?(map, field)` | 27 | `raise:ArgumentError` |
| MX3b | `majority.ex` (shipped) | dual-key check removed | 27 | assertion |
| MP1 | `metrics.ex` (shipped) | **caller revert:** `fetch_field!` back to `Map.fetch(attrs, :answer)` | 24 | assertion (Evaluate turns the raise into `failure_score`, verified in H15) |
| MV1 | `evaluate.ex` (shipped) | save collision compared by term, not `to_string` | 26 | assertion |

**Row 27 kind:** under MX1, row 27 also raises inside `majority`. It goes into MX1's `also` **only if observed**, and MX1's `kind` stays `assertion`. If C2 then reports WRONG-REASON for MX1, the row-27 test is split so that each half is claimed by exactly one kind; `kind: any` is not used.

## (d) Pre-mortem
1. **`:rand.seed(:exsss, seed)` + `Enum.shuffle`.** Deterministic on the worker's machine, so any "same seed → same order" test passes — and it mutates the caller's RNG. → Row 2 (golden CPython permutations, which `Enum.shuffle` cannot match) and row 4.
2. **`bit_length(n - 1)`**, the "obvious" optimisation. Differs from CPython whenever `n` is a power of two. → Row 2 includes `n = 2` and the powers of two inside the 1000-element shuffle.
3. **Transcribes the Python fix instead of the Elixir risk.** Upstream's "accepts zero" test guards Python's `or`; in Elixir `0` is truthy, so that bug cannot happen. The Elixir risk is the opposite: `Keyword.get(opts, :k, old)` turns an explicit `nil` into "reset to all", where upstream keeps the old value. → Row 5b.
4. **Returns NimbleCSV rows as they come:** BOM in the first key, blank lines as one-field rows, long rows accepted. → Rows 14–16.
5. **`String.to_atom` on headers** "so examples look like the ones in the tests". → Row 18.
6. **Copies upstream's `dspy_uuid`**, breaking equality between two calls. → Row 12.
7. **O(n²) shuffle** by swapping in a list. Row 2 at n = 1000 still passes, so this is a performance guard only: an `:array`/tuple-based swap is expected, and Clemens checks it.
8. **Consumers tested with hand-built atom-keyed examples** (how P1 and P2 shipped). → Rows 24–28 must read loader output from disk.
9. **Round-trip test compares with `==` after normalising both sides** (for example `""`→`nil` on both), which hides a fourth, undeclared loss. → Rows 20a/20b state the exact per-value map; nothing may be normalised outside it.
10. **Row→Example builder shared by CSV and JSON, reverted once in the harness** → one caller's rows go untested. → R7 per-caller reverts.
11. **A `:rand` fallback "for `seed: nil`"** re-introduces caller-state mutation. → Row 4 includes the unseeded shape.

12. **`also` written ahead of the run** (H15, lesson 2026-10-02). → (c2): every `also` starts empty; the review checks `also == failed − expect`.
13. **A consumer row that passes without reaching the string path**, e.g. row 28 if the judge's fake LM returns the same scripted score whatever the prompt says. → Row 28 asserts the loaded values are **in the judge's request**; MX1 must turn it red (V1).

## Verify-first (controller, before any code)
- **V1:** that MX1 turns row 28 red. If the scripted DummyLM scores identically with blank judge inputs, the prompt assertion is what makes it red; prove it on the base tree with a throwaway edit, and report the failing line.
- **V2:** that `LabeledFewShot.compile` with a loaded trainset reaches the Default/JSON demo path (rows 25a/b) and not a different renderer.
- **V3:** that the R6 generator can emit stable `case_id`s for every A4 row (needed by row 34).

## (e) Echo-back
The A1 signatures verbatim; A2's generator steps in own words, including why `n` and not `n − 1`; the A4 CSV table rows marked "no" and why; one sentence per A5 invariant.

## Decisions for Horst (not silent choices)
- **E1 — Our own generator, equal to CPython's (Horst's question 1).** Recommended as specified in A2. The alternative, `:rand` with an explicit `seed_s` state plus our own Fisher–Yates, avoids process state but ties results to an OTP algorithm and gives different splits from Python. Golden vectors come from the same committed `uv` generator as M1-b F1 (not yet ruled — the two stand or fall together).
- **E2 — CSV cells stay strings (deviation).** Upstream infers types through pandas, including the quirk that one missing cell turns a whole integer column into floats (`2` → `2.0`, probe). Upstream's inference also breaks its own standard metric: `answer_exact_match` raises "Invalid answer type" on an integer answer, so a GSM8K-style CSV of numeric answers fails upstream. Porting pandas inference is large and fuzzy. Recommend strings, declared; JSON is the typed format.
- **E3 — A long row raises (deviation).** Upstream silently shifts the row into garbage: `{'q': 1, 'a': 'EXTRA', '__index_level_0__': 'x'}` (probe). Parity would mean reproducing data corruption. Recommend raise, naming the line — which also mirrors M1-a's "a key outside the header raises" on save.
- **E4 — A duplicate header raises (deviation).** Upstream renames the second column `a.1`. Recommend raise; our save never writes one.
- **E5 — No `dspy_uuid`; the split name goes into `Example.metadata["dspy_split"]` (deviation).** Upstream adds a random `uuid4` to every example (unused — its own TODO `:98-101`) and hides `dspy_*` keys only from `len`/`repr`/`keys`. Our `Example` has no hidden keys, so they would leak into `inputs`/keys, metrics and the M1-a CSV/JSON rows, and the random uuid makes two calls unequal.
- **E6 — Negative sizes raise (deviation).** Python slicing would drop elements from the end.
- **E7 — `seed: nil` in `sample`/`train_test_split`:** a fresh seed from `:crypto.strong_rand_bytes/1` — not reproducible, as upstream, but **never** touching the caller's `:rand` state. Upstream's `train_test_split` calls the *global* `random.seed(random_state)`, changing every later random call in the process; not emulated.
- **E8 — `sample` included.** It shares the generator and costs one function. Can be split off if you want M1-e smaller.
- **E9 — M1 exit example lives here (row 22)** and needs M1-d. If M1-e lands first, row 22 moves to M1-d.

- **T1 — Typed labels from CSV (new, R3).** E2 leaves a silent 0 for user metrics that compare a typed output (`:integer`) with a string label. Options: (a) opt-in `types: %{"col" => :integer | :float}` on `from_csv`, parsed with the H12 strict `NumberParser`, raising on a bad cell (row 30); (b) keep strings and only document the trap. **Recommend (a)** — small, strict, opt-in, reuses shipped code; the default stays E2.
- **T2 — `Dspy.Trainset` and the 10 `:rand` sites (new, R4).** Recommend: M1-e ships `Dspy.Random` only for its own functions; a separate follow-up slice migrates `evaluate.ex`, `trainset.ex`, `bootstrap_few_shot.ex` to it (changes seeded results in those modules → COMPATIBILITY note), and decides whether `Dspy.Trainset.split/sample` are deprecated in favour of DataLoader. Not in M1-e scope.
- **T3 — String-key audit slice before M1-e (P1, P2).** Fix `metrics.ex` `fetch_field!/fetch_context!` (loud) and `signature.ex:480` (silent `""`) to read through `Dspy.Example.get`/Access, and audit the ~12 call sites, each with a string-keyed test. **Recommend: its own slice, merged before M1-e starts**, because P2 already affects anyone passing string-keyed demos today (for example demos loaded by M2-a).
- **T4 — `majority` with string-keyed maps.** Currently atom-only, declared (M1-c). Loader output makes string-keyed completions normal. Recommend: accept string keys via the same lookup as T3, and keep "both `"k"` and `:k` present" raising. Needs your call because it reverses a declared M1-c boundary.

### RULED 2026-09-28 (Horst)
**Governing principle** (now in `plan/HOW_WE_WORK.md`): *we match upstream, except where upstream silently corrupts or loses data — there we raise, and we declare it.* Raising is stricter than upstream, not friendlier, so it does not weaken the parity rule of P-OUT and B1. The test for each case: is upstream making a design choice (match it), or losing the user's data (raise)?

- **E1 — AGREED, generator RULED (M1-b F1):** our own generator, specified as CPython's MT19937 + `shuffle`/`sample` (A2), pinned by golden vectors from the committed `uv` generator under `plan/research/upstream_golden/`. **Python is a fixture-generation tool, not a runtime dependency:** nothing in `lib/` or `mix test` runs it, CI needs no Python, and the committed fixtures are the test input.
- **E2 — RULED WITH GRETA: CSV values stay strings, declared; JSON is the typed format.** Upstream's pandas inference corrupts: one missing cell turns a whole integer column into floats (`2` → `2.0`, probe), and the inference breaks upstream's own `answer_exact_match` on numeric answers.
- **E3 — RULED WITH GRETA: a CSV row with an extra field raises, naming the line.** Upstream scrambles the row into a different shape (`{'q': 1, 'a': 'EXTRA', '__index_level_0__': 'x'}`, probe). Mirrors M1-a's "a key outside the header raises" on save.
- **E4 — RULED WITH GRETA: a duplicate column name raises, naming the column.** Upstream renames it `a.1`, so data lands under a key nobody asked for. Our save never writes one.
- **E5 — AGREED: drop `dspy_uuid`; record the split in `Example.metadata["dspy_split"]`; declare it** in `docs/COMPATIBILITY.md`. A random field upstream never reads makes two identical loads compare unequal and would leak into `labels`, metrics and saved files.
- The four deviations E2–E5 go into `docs/COMPATIBILITY.md` with the upstream probe evidence, under the governing principle.
- E6–E9: ruled 2026-09-30, see below.

### RULED 2026-09-30 (Horst)
- **T3 — YES, booked as queue H15**, its own slice. **Order: M1-d → H15 → M1-e**; one lib-editing team at a time, so H15 does not interrupt M1-d, and it lands before M1-e with no exceptions. Scope: P1, P2 and the ~12 other call sites, with **every shape fixed through one canonical accessor** (the `Prediction.fetch/2` / `Example.get/2` atom→string fallback), not 12 separate fixes. Rows 24, 25 and 28 depend on H15.
- **T4 — YES, folded into H15.** This reverses the M1-c atom-only boundary. H15 updates the COMPATIBILITY entry and removes the now-wrong atom-keys hint. Row 27: `majority` over string-keyed maps from `from_json` gives the same result as atom-keyed maps; a map carrying both `"k"` and `:k` still raises.
- **T1 — YES:** opt-in `types:` on `from_csv`, using the H12 strict `NumberParser` (row 30); E2 stays the default. **In addition, declare the pitfall prominently in `docs/COMPATIBILITY.md` AND in the `from_csv` docstring:** a user metric comparing a typed `:integer`/`:number` output with a CSV string label **scores 0 silently**, where upstream would compare equal; name `types:` as the remedy. Acceptance: a doctest/docs check that the `from_csv` docstring names both the pitfall and `types:`.
- **T2 — YES, a separate slice after M1-e, booked as queue H16.** It is a real bug: the seeded `:rand` calls silently change the caller's random state. M1-e must not add another (row 4).
- **E6 — AGREED:** negative sizes raise; deviation declared (dropping from the end is data loss).
- **E7 — AGREED:** `seed: nil` → a fresh `:crypto.strong_rand_bytes/1` seed, never the caller's `:rand` state.
- **E8 — AGREED:** `sample` stays in.
- **E9 — Row 22 stays in M1-e.** It moves with whichever of M1-d and M1-e lands second, and M1-d lands first.

### Rulings needed 2026-10-02 (Greta → Horst)
- **Q1 — User rows that hold both `:k` and `"k"` in `Dataset.new(train: …)`.** Loaders never produce them (R1). For user-built rows, I recommend **pass-through**: `Example.new/1` as today, so reads follow the accessor's atom-wins rule (H15 R2). Declare it in the moduledoc. The alternative is to raise like `majority`, but that is stricter than `Example` itself and outside this slice.
- **Q2 — M1-e's harness mutates shipped H15 code** (MX1–MX3, MP1, MV1 and MD7b). This re-proves those sites, this time with **loader output from disk**, which H15's hand-built fixtures never used. I recommend yes: these are 7 of the 54 mutations, and they are the only proof that P1/P2 cannot come back through the loaders.
- **Q3 — scope of `m1e_deviations.json`.** I recommend **only fixture-observable deviations** (E2, E3, E4, E6, and E5's uuid). E7 (upstream reseeds the global RNG) cannot be seen in a fixture, so it stays prose in COMPATIBILITY.

## (b) Team card — Horst.

## (f) Clarity Gate
- Greta ☐ — signs once E1–E9 are ruled on.
- Horst ☐

## Rulings (Horst, 2026-10-02)
Q1 YES (both-form rows pass through, atom wins, declared in moduledoc) · Q2 YES (harness may mutate shipped H15 code — the only proof loaded data cannot bring P1/P2 back) · Q3 YES (deviations.json covers fixture-visible deviations; E7 stays prose). **LOCKED.**
