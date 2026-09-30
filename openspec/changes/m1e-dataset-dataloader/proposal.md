# M1-e — Dataset and DataLoader (local CSV / JSON only)

Status: **DRAFT, REFRESHED (Greta 2026-09-30), ALL DECISIONS RULED (Horst 2026-09-30).** Needs the team card and both signatures. Paper only. **Blocked on H15** (string-key audit: P1, P2, T4), which lands after M1-d and before M1-e. Order: M1-d → H15 → M1-e → H16.
Queue: `PARITY_QUEUE.md` §M1 rows **U003** (Dataset) and **U002** (DataLoader, local files only). `from_huggingface`, `from_pandas`, `from_parquet`, `from_rm` stay in the M7+ pool.
Base: `main` after the M1-a fix round. NimbleCSV is already a dependency (M1-a). **Carries the M1 exit example** (last row), so it needs M1-d merged first or the row moves to whichever of the two lands last.

Reference, anchored to DSPy **3.4.0** (`../dspy-3.4.0`, tag `3.4.0`):
- `dspy/datasets/dataset.py`: constructor `:13-32` (`train_seed=0`, `eval_seed=0` shared by dev **and** test `:25-27`, sizes `None` = all, `do_shuffle = True` `:30`); `reset_seeds` (`None` keeps the old value) `:34-56`; `train`/`dev`/`test` lazily computed and cached `:58-77`; `_shuffle_and_sample` = `random.Random(seed).shuffle`, then `[:size]`, then one `Example` per row with a random `dspy_uuid` and `dspy_split` `:79-103`; `prepare_by_seed` `:105-139`.
- `dspy/datasets/dataloader.py`: `from_csv` `:63-76` and `from_json` `:91-104` (both through HF `datasets.load_dataset`, fields default to all columns, `with_inputs(*input_keys)`); `sample` = global `random.sample` `:138-150`; `train_test_split` = **global** `random.seed(random_state)` then `random.shuffle`, `int(len * frac)` truncation, validation errors `:152-198`.
- CPython 3.11 `random.Random.shuffle` / `_randbelow_with_getrandbits` / `sample` (read from the interpreter, `inspect.getsource`).
- **Oracle:** `tests/datasets/test_dataset.py` — 3 tests: `reset_seeds` accepts zero `:39-48`, keeps omitted values `:51-61`, `input_keys` via a CSV subclass (pandas, marked `extra`) `:64-74`. Nothing tests the loaders. So loader behaviour below comes from a **probe of upstream 3.4.0**, now committed at `plan/research/m1e-refresh-2026-09-30/ck_loaders.py` with its output `ck_loaders.out` (first run 2026-09-28 from a scratchpad file that did **not** survive the session — re-created and re-run 2026-09-30, all 17 loader observations and the `train_test_split` result identical). It is the seed for the committed generator (R6).

## Why
The M1 exit example starts with "load a CSV with DataLoader", and every tutorial starts from a `Dataset` split. Seeded splits are how results get compared between runs — and between Python and Elixir.

## Refresh 2026-09-30 — what changed since this contract was written

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

### R7 — mutation harness, as the standard now stands
`plan/research/upstream_golden/mutate_m1e.py`, committed: originals held in memory and restored in `try/finally`; **SIGTERM and SIGHUP handlers** that raise `SystemExit` (the H12 gap, so `finally` runs on a pane close); `NOT-APPLICABLE` is a hard failure (exit 1); a base-green check before any mutation; a debris pre-flight; **per-caller reverts** wherever a shared helper exists — `Dspy.Random` is shared by `Dataset.train/1`, `sample/3` and `train_test_split/2`, and one row→Example builder should be shared by `from_csv` and `from_json`, so breaking the helper must redden every caller and reverting one caller must redden only that caller.

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

## (c) Acceptance map (refreshed 2026-09-30)
Tiers: **[T]** ported upstream test · **[G]** golden from the committed generator (R6) · **[–]** contract behaviour. **Shapes** = the input shapes the row must cover; a row that covers fewer is incomplete. **Rows 24–30 must use loader output** — files written to disk and read with `from_csv`/`from_json` — never hand-built atom-keyed examples.

| # | Tier | Scenario | Shapes | Mutation that must turn it RED (and why it shows) |
|---|---|---|---|---|
| 1 | G | Generator: first five `uint32` equal CPython's (seed 0 starts `3626764237`) | seeds `0, 1, 42, 2023, 2**32, 2**64+3, −5`: zero, small, multi-word, negative | wrong `init_by_array` word order (shows at `2**32`, `2**64+3`); no `abs` (shows at `−5`) |
| 2 | G | Shuffle permutations equal CPython's; seed 0, n 10 → `[7,8,1,5,3,4,2,0,9,6]` | n ∈ `{0, 1, 2, 10, 100, 1000}`, including powers of two | `Enum.shuffle` after `:rand.seed` (no CPython permutation); `bit_length(n − 1)` (shows at n = 2 and powers of two); loop running upward |
| 3 | G | Sample equals CPython's: `sample(0..9, 3, seed: 0)` → `[6,9,0]`, `sample(0..99, 3, seed: 0)` → `[49,97,53]` | pool branch; set branch; k = 6 around the `setsize` boundary | one branch only (the other branch's rows fail) |
| 4 | – | The caller's `:rand` state (`:rand.export_seed/0`) is identical before and after `train/1`, `sample/3`, `train_test_split/2` | caller **seeded** beforehand; caller **never seeded** (`:undefined`) | seeding via `:rand.seed/2` (changes the state in both shapes) |
| 5 | T | `reset_seeds` accepts zero for every key (`test_reset_seeds_accepts_zero`) | all six keys | none natural in Elixir (`0` is truthy; this upstream test guards a *Python* bug) — ported as the oracle; row 5b holds the Elixir trap |
| 5b | – | `reset_seeds(ds, train_size: nil)` keeps the old size | explicit `nil`; key absent | `Keyword.get(opts, :train_size, ds.train_size)` (explicit `nil` then means "all") |
| 6 | T | `reset_seeds(train_seed: 1)` keeps every other value, both eval seeds included | one key given | resetting omitted keys to defaults |
| 7 | – | dev and test share `eval_seed`: with `eval_seed: 7` and identical rows, identical orders | non-zero seed | a separate `test_seed` defaulting to 0 (only visible with a non-zero seed) |
| 8 | G | `train/1`, `train_seed: 0`, `train_size: 7` over rows 0..9 → `[7,8,1,5,3,4,2]`, equal to upstream `train_test_split(random_state=0)` | – | sampling before shuffling |
| 9 | – | Sizes | `nil` → all; `0` → `[]`; larger → all; negative → `ArgumentError` | Python-style negative slicing |
| 10 | – | `shuffle: false` keeps row order | – | flag ignored |
| 11 | T | `input_keys` → inputs are exactly those keys (`test_input_keys`, without pandas) | key names given as strings **and** as atoms, against string-keyed rows | `input_keys` ignored; atom key names not matched to string attrs |
| 12 | – | `train/1` twice → `==` lists | – | adding a random `dspy_uuid` |
| 13 | – | `prepare_by_seed` → 5 disjoint eval slices, 5 train sets; too little dev data → `ArgumentError` | – | eval slices not offset |
| 14 | G | **CSV rows of A4**, one test each, expected values from the fixture | BOM; blank line; CRLF and LF; embedded newline and `""` escape; empty and quoted-empty cell; short row; surrounding whitespace; `fields:` subset order; unknown field | per shape: BOM kept; `[""]` kept as a row; `""` kept as `""`; `String.trim`; subset in file order |
| 15 | – | Long row → `ArgumentError` naming the line (E3) | extra field in row 2 and in the last row | accepting and dropping the extra field |
| 16 | – | Duplicate header → `ArgumentError` naming the column (E4) | – | last duplicate wins |
| 17 | – | Values stay strings (E2) | `"2"`, `"1.5"`, `"True"`, `"0x10"` | any type inference |
| 18 | – | String keys, no atom created: a never-seen header name built at runtime still makes `String.to_existing_atom/1` raise afterwards | CSV header; JSON key; nested JSON key | `String.to_atom` on keys |
| 19 | G | **JSON rows of A4**, expected values from the fixture | array; JSONL; union of keys → `nil`; nested kept; `null`; non-object record raises naming its index | per shape |
| 20a | – | **CSV round trip with the shipped `save_as_csv`** (R2): `Evaluate` over **loaded** string-keyed examples containing a comma, quotes, a newline, a `nil` and a `""`, with one failing example → `save_as_csv` → `from_csv`. For every saved row `r` and loaded row `l`: `keys(l)` = the header, and `l[k] == c(r[k])` with `c(binary) = binary`, `c(nil) = nil`, `c("") = nil`, `c(number) = to_string(number)`, `c(absent) = nil`. **No other difference is allowed.** | quoting ×3; `nil`; `""`; absent key (failed row); number (metric) | loader and saver disagree on quoting or line endings; `""` loaded as `""` (a fourth difference); a number re-typed on load |
| 20b | – | **JSON round trip with the shipped `save_as_json`**: same data. `l[k] == r[k]` for every key of `r`; a key absent from `r` but present in another row → `nil` (union rule, upstream parity); `""` stays `""`; numbers stay numbers | same shapes as 20a | union rule dropped; `""` turned into `nil`; numbers turned into strings |
| 21 | – | `train_test_split`: `0.75` over 10 → 7/3 (truncation); int `3` → 3/7; sizes exceeding n → `ArgumentError`; `train_size: 1.0` → `ArgumentError` | float; int; overflow; 1.0 | rounding instead of truncating (shows at 0.75 × 10) |
| 22 | – | **M1 exit example:** `from_csv` → `Dataset` → `evaluate` a ChainOfThought with `SemanticF1.metric/1`, `max_errors: 2`, one failing example, `save_as_json`, re-load with `from_json` — needs **M1-d and H15** | loader output end to end | – |
| 24 | – | **Consumer: metrics (P1).** A CSV with string answers → `Evaluate` with `&Dspy.Metrics.answer_exact_match/2` → `scores` equal to the same data built with atom keys | string vs atom keys, same values | a metric reading `Map.fetch(attrs, :answer)` (every loaded example fails) |
| 25 | – | **Consumer: demos (P2).** A CSV trainset → `LabeledFewShot.compile` → the Predict request contains every demo field value, and equals the atom-keyed equivalent, **for Default, JSONAdapter and ChatAdapter** | 3 adapters × string keys | `format_example` reading `Map.get(attrs, field.name, "")` (Default and JSON red, Chat green — the per-adapter asymmetry proves each adapter is covered) |
| 26 | – | **Consumer: save writers.** Loaded examples whose `"answer"` collides with the prediction's `:answer` → saved rows carry `example_answer`/`pred_answer`, no duplicate column, both CSV and JSON | string example × atom prediction | collision compared by term instead of `to_string` |
| 27 | – | **Consumer: `majority`** with loader-shaped completions (string-keyed maps from `from_json`) → per **T4** | string-keyed maps | per T4 |
| 28 | – | **Consumer: M1-d judges** (once M1-d lands) — `SemanticF1.metric/1` on a loaded example scores equal to the atom-keyed one | string vs atom keys | a judge reading `Map.fetch(attrs, :response)` |
| 29 | – | **JSON numeric label**: `from_json` with `{"answer": 2}` + `answer_exact_match` → `ArgumentError` (upstream `ValueError`), declared | integer label; float label | silently turning labels into strings |
| 30 | – | **T1 (ruled yes):** `from_csv(path, types: %{"answer" => :integer})` → integers via the H12 `NumberParser`; `"80%"` in a typed column → `ArgumentError` naming line and column; untyped columns stay strings | typed / untyped; strict reject | a lenient parse (`Integer.parse` prefix) accepting `"80%"` |
| 31 | – | **R6:** the committed generator re-runs and its fixture equals the committed one (apart from metadata) | – | – |
| 32 | – | **R7:** the committed harness: 0 survivors, 0 `NOT-APPLICABLE`; run twice with an edit in between (the second run tests the edit); SIGTERM and SIGHUP restore the tree | – | – |
| 33 | – | Full suite + consumer canary green; `git diff test/` additions only | – | – |

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

## (e) Echo-back
The A1 signatures verbatim; A2's generator steps in own words, including why `n` and not `n − 1`; the A4 CSV table rows marked "no" and why; one sentence per A5 invariant.

## Decisions for Horst (not silent choices)
- **E1 — Our own generator, equal to CPython's (Horst's question 1).** Recommended as specified in A2. The alternative, `:rand` with an explicit `seed_s` state plus our own Fisher–Yates, avoids process state but ties results to an OTP algorithm and gives different splits from Python. Golden vectors come from the same committed `uv` generator as M1-b F1 (not yet ruled — the two stand or fall together).
- **E2 — CSV cells stay strings (deviation).** Upstream infers types through pandas, including the quirk that one missing cell turns a whole integer column into floats (`2` → `2.0`, probe). Upstream's inference also breaks its own standard metric: `answer_exact_match` raises "Invalid answer type" on an integer answer, so a GSM8K-style CSV of numeric answers fails upstream. Porting pandas inference is large and fuzzy. Recommend strings, declared; JSON is the typed format.
- **E3 — A long row raises (deviation).** Upstream silently shifts the row into garbage: `{'q': 1, 'a': 'EXTRA', '__index_level_0__': 'x'}` (probe). Parity would mean reproducing data corruption. Recommend raise, naming the line — which also mirrors M1-a's "a key outside the header raises" on save.
- **E4 — A duplicate header raises (deviation).** Upstream renames the second column `a.1`. Recommend raise; our save never writes one.
- **E5 — No `dspy_uuid`; the split name goes into `Example.metadata["dspy_split"]` (deviation).** Upstream adds a random `uuid4` to every example (unused — its own TODO `:98-101`) and hides `dspy_*` keys only from `len`/`repr`/`keys`. Our `Example` has no hidden keys, so they would leak into `labels`, metrics and the M1-a CSV/JSON rows, and the random uuid makes two calls unequal.
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

## (b) Team card — Horst.

## (f) Clarity Gate
- Greta ☐ — signs once E1–E9 are ruled on.
- Horst ☐
