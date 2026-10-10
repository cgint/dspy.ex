# H16 — All library sampling through `Dspy.Random`

Status: **DRAFT (Greta 2026-10-03)** — needs Horst's rulings **R1–R5**. Paper only. Queue H16 (ruled T2, 2026-09-30). Base: `main` at `40c779b` (v0.4.6).
Harness: `plan/research/upstream_golden/mutate_h16.py` on `mutlib.py`, writing to `plan/research/pi_handoffs/h16/mutation_report.json`. `CONTRACT_IDS` is a literal list in the harness (below), enforced. No `kind: any`. Every `also` = observed failures − `expect`. A test killed by a mutation sits in that mutation's `expect` (a different `kind` → a twin ID, the MG3b/MX1b pattern), never in `exempt` or only in `also`.

## Why
The library samples with `:rand.seed(:exsss, …)` followed by `Enum.shuffle`/`Enum.random`/`:rand.uniform`. This has two defects:
1. **It overwrites the caller's process-global random state.** A user who seeded `:rand` for their own reasons loses that state after calling `Trainset.sample/3`, `BootstrapFewShot.compile/3`, and so on.
2. **"Same seed, same result" depends on the Elixir/OTP release.** `Enum.shuffle/1` promises no permutation, which is the B2 class again; see the M1-e contract A2.

M1-e shipped `Dspy.Random`, a pure, CPython-exact generator. H16 routes every remaining site through it.

## Inventory — re-measured on `40c779b` (the queue said 6 sites; there are 15)
`grep -rnE ":rand\.|Enum\.(shuffle|random|take_random)" lib` (excluding `random.ex`):

| # | Site | Public entry |
|---|---|---|
| S1 | `evaluate.ex:908-909` `cross_validate`: `:rand.seed` + `Enum.shuffle` | `Dspy.Evaluate.cross_validate/4` (`shuffle: true`) |
| S2 | `trainset.ex:103-104` `split`: seed + shuffle | `Dspy.Trainset.split/2` |
| S3 | `trainset.ex:144` `sample`: seed, then the strategy | `Dspy.Trainset.sample/3` |
| S3r | `trainset.ex:379` `random_sample`: `Enum.shuffle` (draws from the state S3 seeded) | `Trainset.sample/3`, `strategy: :random` |
| S3d | `trainset.ex:387,393` `diverse_sample`: `Enum.shuffle` ×2 | `Trainset.sample/3`, `strategy: :diverse` |
| S4 | `trainset.ex:184,187` `bootstrap_sample`: seed + `Enum.random` | `Dspy.Trainset.bootstrap_sample/3` |
| S5 | `bootstrap_few_shot.ex:234` `seed_random_if_needed` | `BootstrapFewShot.compile/3` |
| S5c | `bootstrap_few_shot.ex:365,380-381` `generate_candidate_programs`: seed + `:rand.uniform` ×2 | same |
| S5t | `bootstrap_few_shot.ex:420` `take_random_subset`: `Enum.shuffle` | same |
| S6 | `ensemble.ex:339` `split_data`: seed (then `Trainset.split`) | `Teleprompt.Ensemble.compile/3` |
| S6g | `ensemble.ex:416,433` `generate_diverse_configurations`: seed + `:rand.uniform()` (float) | same |
| S6v | `ensemble.ex:441,453` `vary_config`/`vary_parameter`: seed + `Enum.random` | same |

These reach `:rand` **only through `Trainset`**: `LabeledFewShot.compile/3` (`labeled_few_shot.ex:121`), `SIMBA.compile/3` (`simba.ex:274,289,363`) and `MIPROv2.compile/3` (`mipro_v2.ex:265,290,343`). Each gets rows of its own, because each is a public entry.

`test/consumer_contract/**` references none of these (grep, today).

## (a) Contract

### A1. `Dspy.Random` gains two CPython functions (R4)
Pure, with state in and state out, as with the existing ones:
- **`random(state) :: {float, state}`** — CPython `random()`: `a = getrandbits(27)`, `b = getrandbits(26)`, then `(a * 67_108_864 + b) / 9_007_199_254_740_992`. It replaces `:rand.uniform/0`.
- **`choice(state, list) :: {elem, state}`** — CPython `choice`: `list[randbelow(len)]`, and an empty list raises `ArgumentError`. It replaces `Enum.random/1`.
- `:rand.uniform(n)` (an integer in `1..n`) becomes `randbelow(state, n) + 1`.

### A2. Routing rule
Each site:
1. seeds **once** with `Dspy.Random.seed(seed)`;
2. **threads the state** through every draw in that call, with no process dictionary and no `:rand`;
3. keeps its public signature.

`seed: nil` defaults (system time today) become `:crypto.strong_rand_bytes/1` seeds, as with M1-e's E7, so they never touch `:rand`.

### A3. Trainset deprecation (R3)
- `Trainset.split/2` and `Trainset.sample/3` with `strategy: :random` **keep working**, routed through A2, with an `@doc` note: "Prefer `Dspy.DataLoader.train_test_split/2` / `sample/3`."
- **No `@deprecated` attribute in this slice.** Five library modules call Trainset (MIPROv2, BootstrapFewShot, SIMBA, Ensemble, LabeledFewShot), so `@deprecated` would emit compile warnings in them, and CI runs `--warnings-as-errors`.
- The strategies `:diverse`, `:balanced`, `:hard` and `:uncertainty` have **no DataLoader counterpart**, so they are not deprecated.

### A4. Invariants
1. After the slice, `grep -rnE ":rand\.|Enum\.(shuffle|random|take_random)" lib` finds nothing outside `random.ex` (row Z1).
2. No public signature changes.
3. `test/consumer_contract/**`, `mix.exs` and `mix.lock` are unchanged.
4. Existing tests that pinned an **exsss-era selection** are updated **only** with values from the CPython generator, never with Elixir output, and the report lists each one (R1).

## (b) Consumer risk — **every seeded result changes**
This is the inherent cost of fixing B2 (R1). For the same `seed:`, every site now returns a **different** selection than v0.4.6: MT19937 instead of exsss, and Fisher–Yates draws instead of `Enum.shuffle`'s internals.

| Entry | What changes for an existing user who passes a seed |
|---|---|
| `Trainset.split/2`, `sample/3`, `bootstrap_sample/3` | which examples land in each split or sample |
| `Evaluate.cross_validate/4` | fold membership, so per-fold scores change and the mean changes too |
| `LabeledFewShot.compile/3` | **which demos are chosen**, so prompts change |
| `BootstrapFewShot.compile/3` | the order demos are tried in, candidate sizes, chosen demos |
| `Ensemble.compile/3` | the train/val split, member configurations |
| `SIMBA.compile/3`, `MIPROv2.compile/3` | batches and demo candidates |

**Unseeded calls** (the system-time default) were never reproducible, so they carry no reproducibility risk.

**Mitigation:** a RELEASES/COMPATIBILITY note naming every entry above ("seeded selections differ from ≤ v0.4.6; they are now stable across Elixir/OTP releases and, where upstream has a counterpart, equal to Python's"). No compatibility mode: keeping exsss would mean keeping `:rand`, which is the bug itself.

## (c) Acceptance map
Test file `test/dspy/random_everywhere_test.exs` = `acceptance_files`.
- **"State rows"** run the entry with the caller's `:rand` **seeded** (`:rand.seed(:exsss, {1,2,3})`) and assert `:rand.export_seed()` is equal before and after. They also run it with the caller **never seeded** (fresh process via `Task.async`) and assert `:rand.export_seed() == :undefined` after.
- **"Determinism rows"** run the entry twice with the same seed and assert the results are equal.
- Golden values come **only** from `plan/research/upstream_golden/gen_h16_golden.py` (CPython / upstream DSPy 3.4.0 via `uv`), into `test/fixtures/upstream_h16_random_3_4_0.json`.

| # | Row (test name prefix) | Entry | Claimed by |
|---|---|---|---|
| 1 | `row 1: cross_validate leaves :rand untouched` | `Evaluate.cross_validate/4`, `shuffle: true, seed: 3` | MR1 |
| 1g | `row 1g: cross_validate fold order equals CPython Random(seed).shuffle` (golden) | same | MR1, MS3 |
| 2 | `row 2: Trainset.split leaves :rand untouched` | `Trainset.split/2` | MR2 |
| 2g | `row 2g: Trainset.split order equals CPython Random(seed).shuffle, then our ratio cut` (golden) | same | MR2, MS3 |
| 3 | `row 3: Trainset.sample leaves :rand untouched, every strategy` | `:random`, `:diverse`, `:balanced`, `:hard`, `:uncertainty` | MR3, MR3r, MR3d |
| 3g | `row 3g: Trainset.sample(:random, seed) equals CPython Random(seed).sample(trainset, n)` (golden) | same | MR3r, MS4 |
| 4 | `row 4: bootstrap_sample leaves :rand untouched` | `Trainset.bootstrap_sample/3` | MR4 |
| 4g | `row 4g: bootstrap_sample equals CPython [choice(...) for _ in range(n)] with Random(seed)` (golden) | same | MR4, MS2 |
| 5 | `row 5: BootstrapFewShot.compile leaves :rand untouched` | scripted LM | MR5, MR5c, MR5t |
| 5d | `row 5d: BootstrapFewShot.compile twice with the same seed gives equal demos` | same | MR5t (only if observed; else exempt with reason "no determinism break without :rand") — see V2 |
| 6 | `row 6: Ensemble.compile leaves :rand untouched` | scripted programs | MR6, MR6g, MR6v |
| 6d | `row 6d: Ensemble.compile twice, same seed → equal member configurations` | same | MR6g |
| 7 | `row 7: LabeledFewShot.compile leaves :rand untouched` | `seed: 5` | MR3, MR3r |
| 7g | `row 7g: LabeledFewShot.compile(seed: 0, k: 3) demos equal upstream LabeledFewShot.compile` (upstream `vanilla.py:17-21`: `Random(0).sample(trainset, min(k, n))`) | **only if R2 = yes** | MR3r, MS4 |
| 8 | `row 8: SIMBA.compile leaves :rand untouched` | scripted LM | MR3 |
| 9 | `row 9: MIPROv2.compile leaves :rand untouched` | scripted LM | MR2, MR3d |
| 10g | `row 10g: Dspy.Random.random/1 equals CPython random() — seeds 0, 1, 42, 2**40+5, first 5 floats, bit-exact` | `Dspy.Random` | MS1 |
| 11g | `row 11g: Dspy.Random.choice/2 equals CPython choice — n ∈ {1, 2, 7, 64, 65}`; empty list raises | `Dspy.Random` | MS2 |
| Z1 | static, **exempt**: the A4.1 grep finds nothing | — | exempt ("static; run in review") |
| Z2 | static, **exempt**: the full suite and `test/consumer_contract` are green, and consumer contracts are unchanged | — | exempt ("gate") |

## (d) Declared mutations — `CONTRACT_IDS`
- **Caller reverts:** put back exactly the `40c779b` code of that site, i.e. `:rand.seed` + `Enum.*`/`:rand.uniform`.
- **Shared breaks:** break the shared `Dspy.Random` function every routed site uses.

```python
CONTRACT_IDS = ["MR1","MR2","MR3","MR3r","MR3d","MR4","MR5","MR5c","MR5t","MR6","MR6g","MR6v","MS1","MS2","MS3","MS4"]
```

| Id | File | Change | `expect` | `kind` |
|---|---|---|---|---|
| MR1 | `evaluate.ex` | revert S1 | 1, 1g | assertion |
| MR2 | `trainset.ex` | revert S2 | 2, 2g, 9 | assertion |
| MR3 | `trainset.ex` | revert S3's seeding (`:rand.seed` at the top of `sample/3`) | 3, 7, 8 | assertion |
| MR3r | `trainset.ex` | revert S3r (`Enum.shuffle |> Enum.take`) | 3, 3g, 7 (+7g if R2) | assertion |
| MR3d | `trainset.ex` | revert S3d (both `Enum.shuffle`) | 3, 9 | assertion |
| MR4 | `trainset.ex` | revert S4 | 4, 4g | assertion |
| MR5 | `bootstrap_few_shot.ex` | revert S5 | 5 | assertion |
| MR5c | `bootstrap_few_shot.ex` | revert S5c | 5 | assertion |
| MR5t | `bootstrap_few_shot.ex` | revert S5t | 5 (+5d per V2) | assertion |
| MR6 | `ensemble.ex` | revert S6 | 6 | assertion |
| MR6g | `ensemble.ex` | revert S6g | 6, 6d | assertion |
| MR6v | `ensemble.ex` | revert S6v | 6 | assertion |
| MS1 | `random.ex` | **shared:** `random/1` uses `getrandbits(26)` for `a` | 10g, and every row whose site uses `random/1` (observe) | assertion |
| MS2 | `random.ex` | **shared:** `choice/2` uses `randbelow(len - 1)` | 11g, 4g | assertion |
| MS3 | `random.ex` | **shared:** `shuffle/2` loop off by one (stops at `i = 2`) | 1g, 2g (+ every shuffle-based golden, observe) | assertion |
| MS4 | `random.ex` | **shared:** `sample/3` always takes the pool branch, then use a set-branch input in 3g/7g (n > setsize) | 3g (+7g) | assertion |

Twin IDs (`…b`, a different `kind`) are added **only** where a run shows a kill of another kind, and the report states it.

## (e) Pre-mortem
1. **The "untouched" helper draws from `:rand` itself.** That was M1-e's first row-4 bug. → Compare `export_seed/0` only.
2. **The "never seeded" shape run in the test process,** which ExUnit or earlier tests may already have seeded. → Run it in a fresh `Task`.
3. **Updating old seeded expectations with Elixir output** "because it changed anyway". → A4.4: CPython generator only, and the report lists each update.
4. **Threading forgotten:** reseeding per draw with the same seed gives the same index every time. → The determinism and golden rows (3g, 4g with n > 1, distinct values) catch it.
5. **Adding `@deprecated`** turns CI red through five internal callers. → A3.
6. **`random/1` computed in floats as `a / 2**27 + …`,** which isn't bit-exact. → Row 10g compares exact floats from CPython (`repr`).

## Verify-first (controller, before code)
- **V1:** list every existing test that asserts a seeded selection from these entries (`grep -rn "seed:" test/` cross-checked against the entries). These change under R1; report them before touching any.
- **V2:** whether BootstrapFewShot's determinism row can be broken by any revert. If none can, row 5d is exempt with that reason, rather than claimed falsely.
- **V3:** that SIMBA's and MIPROv2's scripted runs actually reach the sampling sites (S3, S2/S3d) with the options used.

## Rulings needed (Horst)
- **R1 — Accept that every seeded selection changes,** declared in RELEASES/COMPATIBILITY, with no exsss compatibility mode. *Recommended:* yes; it is the fix itself. **This is the consumer-risk ruling:** LabeledFewShot/BootstrapFewShot users with fixed seeds will see different demos after upgrading.
- **R2 — LabeledFewShot parity with upstream:** with `seed: 0` and `:random`, demos equal upstream's `Random(0).sample(trainset, k)` (row 7g). Should the **default** seed also become `0`, upstream's fixed `Random(0)`, instead of system time? *Recommended:* yes, declared. It makes the default deterministic, as upstream is. It is a second behaviour change, because unseeded runs stop varying, so you may prefer to keep the system-time default and only pin parity at `seed: 0`.
- **R3 — Deprecation as an `@doc` note only;** the formal `@deprecated` waits for a follow-up that moves the five internal callers off Trainset. Only `split` and `sample(:random)` are pointed at DataLoader. *Recommended.*
- **R4 — `Dspy.Random` gains `random/1` and `choice/2`** (CPython-golden), so `:rand.uniform` and `Enum.random` have exact replacements. *Recommended.*
- **R5 — No upstream parity for BootstrapFewShot, Ensemble or SIMBA in this slice.** Their sampling structure differs from upstream's (e.g. upstream Bootstrap's `Random(0).shuffle(validation)`, and `Hasher`-seeded choice), so porting their algorithms is its own slice. H16 guarantees state-safety plus determinism there, and CPython-exact draws. *Recommended.*
