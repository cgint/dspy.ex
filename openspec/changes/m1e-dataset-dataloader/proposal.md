# M1-e — Dataset and DataLoader (local CSV / JSON only)

Status: **DRAFT (Greta 2026-09-28)** — needs Horst's calls on E1–E9, then the team card and both signatures. Paper only.
Queue: `PARITY_QUEUE.md` §M1 rows **U003** (Dataset) and **U002** (DataLoader, local files only). `from_huggingface`, `from_pandas`, `from_parquet`, `from_rm` stay in the M7+ pool.
Base: `main` after the M1-a fix round. NimbleCSV is already a dependency (M1-a). **Carries the M1 exit example** (last row), so it needs M1-d merged first or the row moves to whichever of the two lands last.

Reference, anchored to DSPy **3.4.0** (`../dspy-3.4.0`, tag `3.4.0`):
- `dspy/datasets/dataset.py`: constructor `:13-32` (`train_seed=0`, `eval_seed=0` shared by dev **and** test `:25-27`, sizes `None` = all, `do_shuffle = True` `:30`); `reset_seeds` (`None` keeps the old value) `:34-56`; `train`/`dev`/`test` lazily computed and cached `:58-77`; `_shuffle_and_sample` = `random.Random(seed).shuffle`, then `[:size]`, then one `Example` per row with a random `dspy_uuid` and `dspy_split` `:79-103`; `prepare_by_seed` `:105-139`.
- `dspy/datasets/dataloader.py`: `from_csv` `:63-76` and `from_json` `:91-104` (both through HF `datasets.load_dataset`, fields default to all columns, `with_inputs(*input_keys)`); `sample` = global `random.sample` `:138-150`; `train_test_split` = **global** `random.seed(random_state)` then `random.shuffle`, `int(len * frac)` truncation, validation errors `:152-198`.
- CPython 3.11 `random.Random.shuffle` / `_randbelow_with_getrandbits` / `sample` (read from the interpreter, `inspect.getsource`).
- **Oracle:** `tests/datasets/test_dataset.py` — 3 tests: `reset_seeds` accepts zero `:39-48`, keeps omitted values `:51-61`, `input_keys` via a CSV subclass (pandas, marked `extra`) `:64-74`. Nothing tests the loaders. So loader behaviour below comes from a **probe of upstream 3.4.0** (`scratchpad/ck_loaders.py`, run 2026-09-28; the generator in E1 re-runs it for the golden file).

## Why
The M1 exit example starts with "load a CSV with DataLoader", and every tutorial starts from a `Dataset` split. Seeded splits are how results get compared between runs — and between Python and Elixir.

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

## (c) Acceptance map
Tiers: **[T]** ported upstream test · **[G]** golden from running CPython / upstream 3.4.0 · **[–]** contract behaviour.

| # | Tier | Scenario | Mutation that must turn it RED |
|---|---|---|---|
| 1 | G | **Generator:** first five `uint32` for seeds `0, 1, 42, 2023, 2**32, 2**64+3, −5` equal CPython's (seed 0 starts `3626764237`) | wrong `init_by_array` word order, or no `abs` |
| 2 | G | **Shuffle:** permutations for those seeds × n in `{0, 1, 2, 10, 100, 1000}` equal CPython's; seed 0, n 10 → `[7,8,1,5,3,4,2,0,9,6]` | **`Enum.shuffle` after `:rand.seed(:exsss, seed)`**; `bit_length(n - 1)`; loop running up instead of down |
| 3 | G | **Sample:** `sample(0..9, 3, seed: 0)` → `[6,9,0]` (pool branch); `sample(0..99, 3, seed: 0)` → `[49,97,53]` (set branch); plus golden cases at `k = 6` around the `setsize` boundary | one branch only |
| 4 | – | **No process state:** the caller's `:rand` state (`:rand.export_seed/0`) is identical before and after `train/1`, `sample/3` and `train_test_split/2` | seeding via `:rand.seed/2` |
| 5 | T | `reset_seeds` accepts zero for every key (`test_reset_seeds_accepts_zero`) | none natural in Elixir: `0` is truthy, so `\|\|` keeps it (this upstream test guards a *Python* bug). Ported as the oracle; the Elixir trap is row 5b |
| 5b | – | `reset_seeds(ds, train_size: nil)` **keeps** the old size (upstream: `None` means keep) | `Keyword.get(opts, :train_size, ds.train_size)` — an explicit `nil` then resets to "all" |
| 6 | T | `reset_seeds(train_seed: 1)` keeps every other value, including `eval_seed` for dev **and** test (`test_reset_seeds_keeps_existing_values_when_omitted`) | reset every omitted key to its default |
| 7 | – | `dev/1` and `test/1` use the same `eval_seed`: with `eval_seed: 7` and identical rows they return identical orders | a separate `test_seed` defaulting to 0 (needs the non-zero seed to show) |
| 8 | G | `train/1` with `train_seed: 0`, `train_size: 7` over rows 0..9 → ids `[7,8,1,5,3,4,2]` — the same as upstream `train_test_split(random_state=0)` (probe) | sampling before shuffling |
| 9 | – | Sizes: `nil` → all; `0` → `[]`; larger than the split → all; negative → `ArgumentError` | Python-style negative slicing |
| 10 | – | `shuffle: false` keeps row order | flag ignored |
| 11 | T | `input_keys: ["content", "question"]` → every example's inputs are exactly those keys (`test_input_keys`, without pandas) | `input_keys` ignored |
| 12 | – | `train/1` called twice returns `==` lists (no random uuid) | adding `dspy_uuid` |
| 13 | – | `prepare_by_seed` with 5 seeds, `dev_size: 10` → 5 eval slices of 2 disjoint examples, 5 train sets of `train_size`; too little dev data → `ArgumentError` | eval slices not offset (all equal) |
| 14 | G | **CSV rows of A4, one test each:** BOM stripped; blank line skipped; CRLF+LF; embedded newline and `""` escape; empty and quoted-empty → `nil`; short row → `nil`s; whitespace kept; `fields:` subset order; unknown field raises | per row: BOM kept; `[""]` kept as a row; `""` kept as `""`; `String.trim` |
| 15 | – | **Long row → `ArgumentError` naming the line** (E3) | accept and drop the extra field |
| 16 | – | **Duplicate header → `ArgumentError` naming the column** (E4) | last duplicate wins |
| 17 | – | **Values stay strings:** `"2"`, `"1.5"`, `"True"` come back as those strings (E2) | any type inference |
| 18 | – | **Keys are strings, and no atom is created:** after loading a CSV whose header is a never-seen name built at runtime, `String.to_existing_atom(that_name)` still raises `ArgumentError`. (Not `atom_count`: code loading changes it, which would make the test flaky.) | `String.to_atom` on headers |
| 19 | G | **JSON rows of A4:** array; JSONL; union of keys with `nil`; nested kept; `null` → `nil`; non-object record raises naming its index | per row |
| 20 | – | **Round trip with M1-a:** rows with non-empty string values → `save_as_csv` → `from_csv` gives the same pairs; → `save_as_json` → `from_json` gives the same rows with JSON types | loader and saver disagree on line endings or quoting |
| 21 | – | `train_test_split`: float `0.75` over 10 → 7/3 (truncation of 7.5; rounding would give 8); int `3` → 3/7; `train_size + test_size > n` → `ArgumentError`; `train_size: 1.0` → `ArgumentError` (upstream: a float must be strictly between 0 and 1) | rounding instead of truncating |
| 22 | – | **M1 exit example (public entry):** `from_csv` → `Dataset` → `evaluate` a ChainOfThought program with `SemanticF1.metric/1`, `max_errors: 2`, one failing example, `save_as_json` → `failures == 1`, `failure_score` counted, a `%Dspy.Evaluate.Result{}`, and the JSON file re-loads with `from_json` | – |
| 23 | – | Full suite + consumer canary green; `git diff test/` additions only | – |

## (d) Pre-mortem
1. **`:rand.seed(:exsss, seed)` + `Enum.shuffle`.** Deterministic on the worker's machine, so any "same seed → same order" test passes — and it mutates the caller's RNG. → Row 2 (golden CPython permutations, which `Enum.shuffle` cannot match) and row 4.
2. **`bit_length(n - 1)`**, the "obvious" optimisation. Differs from CPython whenever `n` is a power of two. → Row 2 includes `n = 2` and the powers of two inside the 1000-element shuffle.
3. **Transcribes the Python fix instead of the Elixir risk.** Upstream's "accepts zero" test guards Python's `or`; in Elixir `0` is truthy, so that bug cannot happen. The Elixir risk is the opposite: `Keyword.get(opts, :k, old)` turns an explicit `nil` into "reset to all", where upstream keeps the old value. → Row 5b.
4. **Returns NimbleCSV rows as they come:** BOM in the first key, blank lines as one-field rows, long rows accepted. → Rows 14–16.
5. **`String.to_atom` on headers** "so examples look like the ones in the tests". → Row 18.
6. **Copies upstream's `dspy_uuid`**, breaking equality between two calls. → Row 12.
7. **O(n²) shuffle** by swapping in a list. Row 2 at n = 1000 still passes, so this is a performance guard only: an `:array`/tuple-based swap is expected, and Clemens checks it.

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

### RULED 2026-10-01 (Horst)
**Governing principle** (now in `plan/HOW_WE_WORK.md`): *we match upstream, except where upstream silently corrupts or loses data — there we raise, and we declare it.* Raising is stricter than upstream, not friendlier, so it does not weaken the parity rule of P-OUT and B1. The test for each case: is upstream making a design choice (match it), or losing the user's data (raise)?

- **E1 — AGREED, generator RULED (M1-b F1):** our own generator, specified as CPython's MT19937 + `shuffle`/`sample` (A2), pinned by golden vectors from the committed `uv` generator under `plan/research/upstream_golden/`. **Python is a fixture-generation tool, not a runtime dependency:** nothing in `lib/` or `mix test` runs it, CI needs no Python, and the committed fixtures are the test input.
- **E2 — RULED WITH GRETA: CSV values stay strings, declared; JSON is the typed format.** Upstream's pandas inference corrupts: one missing cell turns a whole integer column into floats (`2` → `2.0`, probe), and the inference breaks upstream's own `answer_exact_match` on numeric answers.
- **E3 — RULED WITH GRETA: a CSV row with an extra field raises, naming the line.** Upstream scrambles the row into a different shape (`{'q': 1, 'a': 'EXTRA', '__index_level_0__': 'x'}`, probe). Mirrors M1-a's "a key outside the header raises" on save.
- **E4 — RULED WITH GRETA: a duplicate column name raises, naming the column.** Upstream renames it `a.1`, so data lands under a key nobody asked for. Our save never writes one.
- **E5 — AGREED: drop `dspy_uuid`; record the split in `Example.metadata["dspy_split"]`; declare it** in `docs/COMPATIBILITY.md`. A random field upstream never reads makes two identical loads compare unequal and would leak into `labels`, metrics and saved files.
- The four deviations E2–E5 go into `docs/COMPATIBILITY.md` with the upstream probe evidence, under the governing principle.
- **Still OPEN:** E6 (negative sizes raise), E7 (`seed: nil` → a fresh `:crypto` seed, never the caller's `:rand` state), E8 (`sample` included), E9 (the M1 exit example lives here if M1-e lands after M1-d).

## (b) Team card — Horst.

## (f) Clarity Gate
- Greta ☐ — signs once E1–E9 are ruled on.
- Horst ☐
