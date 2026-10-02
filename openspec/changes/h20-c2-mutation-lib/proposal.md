# H20-C2 — Shared mutation library with declared expectations

Status: **LOCKED (Greta 2026-09-30; rulings G1–G3 = YES, Horst 2026-10-02).** The design is accepted and committed (`plan/research/2026-09-30-mechanical-checks.md`, `803e584`, queue H20). This is the contract for the tooling slice. **Built first when workers return; the M1-d fix round then runs on it** (Horst 2026-09-30). Paper only.
Scope: **C2 and C3a only.** C5 (`deviations.json`), C1a, C3b and C4 are separate H20 sub-slices. The perturbed-atom-table idea is a separate spike.
Migration: older harnesses (M1-b, M1-c, H12, `mutate_m1e` when written) move to the library **when they are next touched**; **M1-d adopts it in its fix round.**

## Why
Three of five M1-d findings repeated rules that were already written in HOW_WE_WORK. Each harness is a copy, so fixes such as the H14 SIGTERM handlers do not carry over from one slice's harness to the next. A harness that decides "killed" by matching a regex on console text counted an ENFILE crash as a kill, and could not tell that M1-d's M1 was killed by row 1 and not by the row 15 it claimed.

**The honest limit, kept in the contract on purpose:** this library makes every mutation's expectations **reviewable**. It cannot make them **right**. Row 9b could still be "killed" by its other assertion (`e.reason != nil`) while its `raw_answer` line stays vacuous. C2 does not replace thinking about what a test proves.

## (a) Contract

### A1. Files (all committed)
- `plan/research/harness/mutlib.py` — the library. Python 3 standard library only, run with plain `python3`. It is a developer tool: nothing in `lib/` or CI's `mix test` depends on it.
- `plan/research/harness/mut_formatter.exs` — an ExUnit formatter that writes one JSON record per test to the path in `DSPY_MUT_REPORT`.
- `test/test_helper.exs` — **one conditional line**: when `DSPY_MUT_REPORT` is set, require the formatter and add it with `ExUnit.configure(formatters: …)`. When the variable is unset, the suite behaves exactly as today.
- `plan/research/harness/selftest/` — a minimal mix project with no dependencies (a few functions and tests) that the library's own self-tests mutate.
- `plan/research/harness/test_mutlib.py` — self-tests (A6), run with `python3 -m unittest`.
- `plan/research/harness/meta_mutate.py` — mutates `mutlib.py` itself and runs the self-tests (A6).

### A2. Declaring a mutation
```python
Mutation(
    id="M3", file="lib/dspy/evaluate/semantic_f1.ex",
    old="…exact unique text…", new="…",
    expect=["row 7b: …", "row 7c: …"],   # exact ExUnit test names (without the "test " prefix)
    also=[],                              # tests allowed to fail as collateral
    kind="assertion",                     # "assertion" | "raise:<Module>" | "any"
    why="upper clamp: 1.5 must not pass through",
)
Harness(mutations=[…], test_files=[…], acceptance_files=[…], exempt={"row 33: …": "suite-level row"}).run()
```
- `old` must occur **exactly once** in `file`. Zero occurrences gives NOT-APPLICABLE; more than one gives AMBIGUOUS. Both are hard failures.
- `expect` must not be empty.
- `kind` is compared with the recorded failure of **each** `expect` test. `assertion` means the error is `ExUnit.AssertionError`. `raise:X` means the error struct is `X`, so the test failed because the code raised an unexpected `X`.

### A3. Formatter record (one JSON line per test)
`{"name": "<test name>", "module": "<test module>", "file": "<path>", "state": "passed"|"failed"|"skipped"|"excluded"|"invalid", "error": "<struct module or kind>"}`, plus a final `{"suite_finished": true, "run_us": …}` line. **A missing or truncated final line means the run is INVALID.**

### A4. Verdict per mutation (the table in the design, now normative)
Checked in this order. The first match wins.

| # | Condition | Verdict | Hard fail? |
|---|---|---|---|
| V1 | `old` not found / found more than once | NOT-APPLICABLE / AMBIGUOUS | yes |
| V2 | no final `suite_finished` record, or non-zero exit with no `failed` or `invalid` record (compile error, ENFILE, VM crash) | INVALID | yes |
| V3 | any `invalid` record (a `setup_all` failed) | INVALID | yes |
| V4 | some `expect` test is `passed`, or is absent from the records | SURVIVED-TARGET | yes |
| V5 | some `expect` test failed with an error that does not match `kind` | WRONG-REASON | yes |
| V6 | some `failed` test outside `expect ∪ also` | BLUNT | yes |
| V7 | otherwise | KILLED | no |

### A5. Whole-run rules
- **Pre-flight:** before snapshotting, the library applies each mutation's `new` text in reverse, as a search: if any `new` text is already present in its file, the tree carries debris, and the run refuses to start. This replaces the hand-written, per-slice debris regexes.
- **Base green:** the unmutated run must have `suite_finished`, zero `failed`, and zero `invalid`. Otherwise it is a hard fail before any mutation.
- **Restore:** originals are held in memory and restored in `try/finally`. SIGTERM and SIGHUP handlers raise `SystemExit` so that the `finally` runs. After the run, a byte-for-byte comparison of every mutated file with its snapshot must be equal; otherwise hard fail.
- **Coverage (C3a):** every test in `acceptance_files` must appear in some mutation's `expect`, or in `exempt`. A test in neither is **UNCLAIMED**, a hard fail, and is named. `exempt` entries are printed in every report.
- **Reconciliation:** the report states the counts defined / applied / KILLED / each failure verdict. The exit code is 0 only if every mutation is KILLED and nothing is UNCLAIMED.
- **Report:** a human table plus `mutation_report.json`. For each mutation it lists the tests that failed and their error, so a reviewer can check "for its reason" without re-running.

### A6. The library tested by its own medicine
`test_mutlib.py` drives `Harness` against `selftest/`. For each verdict it uses a mutation built to produce exactly that verdict. `meta_mutate.py` applies the **harness mutations** listed in the acceptance map to `mutlib.py`, one at a time. It runs `test_mutlib.py` for each, and fails unless every harness mutation turns its named self-test red. `mutlib.py` gets the same in-memory restore and signal handlers as the library it tests.

## (c) Acceptance map
Each row names the **harness mutation (HM)** that must turn it red. The selftest project is `selftest/`, with functions `add/2`, `clamp01/1` and `f1/2`, and tests named `t_add`, `t_clamp_hi`, `t_clamp_lo`, `t_f1`, `t_raise`, and `t_vacuous` (asserts `x == nil or is_binary(x)`).

| # | Scenario (selftest) | Shapes | Harness mutation (HM) that must turn it red |
|---|---|---|---|
| 1 | Mutation of `clamp01`'s upper bound, `expect: [t_clamp_hi]` → KILLED | normal kill | HM1: V7 never reached (everything reported as SURVIVED) — sanity |
| 2 | Mutation `expect: [t_clamp_hi]` that only breaks `t_clamp_lo` → **SURVIVED-TARGET**, not KILLED | killed by the wrong test | HM2: "killed if any test failed" (the old harness rule) |
| 3 | Mutation `expect: [t_clamp_hi, t_clamp_lo]` that breaks only `t_clamp_hi` → SURVIVED-TARGET | several expects, one missed | HM3: `any` instead of `all` over `expect` |
| 4 | Mutation `expect: [t_f1]` whose `new` text is a compile error → **INVALID** | compile error | HM4: non-zero exit counted as a kill |
| 5 | Formatter report truncated (the formatter is killed mid-run through a test hook in `selftest`) → INVALID | ENFILE / VM crash stand-in | HM5: missing `suite_finished` accepted |
| 6 | `setup_all` raising in one selftest module → INVALID | invalid record | HM6: `invalid` records ignored |
| 7 | Mutation breaking `add/2`, used by every test, `expect: [t_add]` → **BLUNT** | mass failure | HM7: V6 check removed |
| 8 | Same as 7 with the collateral tests in `also` → KILLED | declared collateral | HM8: `also` ignored |
| 9 | `expect: [t_raise]`, `kind: "raise:ArgumentError"`, and the mutation makes it raise `KeyError` → **WRONG-REASON** | wrong exception | HM9: `kind` check removed |
| 10 | `kind: "assertion"` and the test fails by assertion → KILLED | assertion kind | HM10: `assertion` matched against the wrong struct name |
| 11 | `old` absent → NOT-APPLICABLE; `old` twice → AMBIGUOUS; both exit non-zero | 0 and 2 occurrences | HM11a: NOT-APPLICABLE counted as skipped; HM11b: first occurrence used silently |
| 12 | `expect` name with a typo (not in the records) → SURVIVED-TARGET, naming the unknown test | absent test | HM12: an absent test counted as "not passed" and therefore killed |
| 13 | Acceptance test `t_vacuous` claimed by no mutation → **UNCLAIMED**, named; with `exempt` → passes and is printed | unclaimed; exempt | HM13a: coverage check removed; HM13b: `exempt` not printed |
| 14 | **Row 9b shape, declared limit:** a mutation `expect: [t_vacuous]` that changes the value `t_vacuous` checks → SURVIVED-TARGET (vacuity exposed); a second mutation that breaks the test's *other* assertion → KILLED | the honest limit, pinned as a documented, passing case | HM14: none. This row documents what C2 cannot catch; it must stay green and its test says so |
| 15 | Base red (a selftest failing before any mutation) → hard fail, no mutation applied | red base | HM15: base-green check skipped |
| 16 | A debris file (a `new` text already present) → refuses to start | leftover | HM16: pre-flight removed |
| 17 | SIGTERM to the harness mid-mutation → every file byte-equal to its snapshot afterwards; same for SIGHUP | two signals | HM17a: SIGTERM handler removed; HM17b: SIGHUP handler removed |
| 18 | Exception inside a mutation's run (the test runner is replaced by a raising stub) → files restored | exception path | HM18: restore moved out of `finally` |
| 19 | Post-run byte comparison: the restore is sabotaged by a test hook that writes one byte → hard fail | silent bad restore | HM19: post-run comparison removed |
| 20 | Report counts: defined = applied + NOT-APPLICABLE + AMBIGUOUS; exit code 0 only for all-KILLED | reconciliation | HM20: exit 0 while an INVALID exists |
| 21 | `DSPY_MUT_REPORT` unset → `mix test` output and exit code of the real suite are unchanged (run the full suite both ways and compare the counts) | formatter off | HM21: formatter added unconditionally (the doubled console output shows it) |
| 22 | `meta_mutate.py`: every HM1–HM21 turns its named row red; 0 survivors; the meta-harness itself uses the in-memory restore | the medicine applied to itself | a meta-mutation that leaves `mutlib.py` altered after the run → the byte comparison fails |
| 23 | **Adoption:** the M1-d fix round rewrites `mutate_m1d.py` on the library. The expected verdicts for the current tree are M1 → SURVIVED-TARGET for row 15 (M1 claims rows 1 and 15, and only row 1 kills it), and UNCLAIMED rows 9b and 12 until they are fixed | real slice | — (proven by the M1-d fix round, not here) |

## (d) Pre-mortem
1. **Matching test names by substring**, so `row 7` also matches `row 7b`. → Names are compared exactly; row 12 covers a near-miss.
2. **The formatter only records failures**, so "absent" and "passed" look the same. → A3 records every test; V4 treats absent as SURVIVED-TARGET; row 12.
3. **Treating `kind: any` as the default.** It would silently remove the reason check. → `kind` is required; `any` must be written out, and the report counts how many mutations use `any`.
4. **A test hook left in `selftest/`** that could reach the real suite. → The selftest is its own mix project, outside `lib/` and `test/`.
5. **Tuning BLUNT away** by pouring half the suite into `also`. → The report prints the size of `also` for each mutation. This is left to review, not a gate (the honest limit again).

## Decisions for Horst
- **G1 — `test/test_helper.exs` gets one conditional line.** The alternative, a separate `mix` alias, means a second test entry point that can drift. I recommend the line, because it is a no-op when the variable is unset (row 21).
- **G2 — WRONG-REASON is a hard fail**, not a warning. Recommended: "fails for its reason" is the rule we are mechanising.
- **G3 — Python for the library.** It matches every existing harness and the generators. The alternative is an Elixir mix task, which would put it in the project's own language, but would be a rewrite that adds nothing the slice needs. I recommend Python.

## Verified 2026-09-30 (Greta, scratch mix project, Elixir 1.20.4 / OTP 29)
- A formatter module required and added with `ExUnit.configure(formatters: [...])` in `test_helper.exs` **after** `ExUnit.start/1` **is used for the run**, and with the variable unset the default output is unchanged.
- State shapes observed: passed → `nil`; failed (assertion and raise alike) → `{:failed, [{kind, reason, stack}]}`; a test in a module whose `setup_all` raised → `{:invalid, %ExUnit.TestModule{}}` (a struct, **not** a module atom); then a `{:suite_finished, _}` event.
- Still to confirm while coding: the `reason` term for an assertion is `%ExUnit.AssertionError{}`, and for a raise it is the exception struct. That is the documented shape, but it was not printed in this probe.

## Rulings (Horst, 2026-10-02)
G1 YES — one conditional line in `test/test_helper.exs`. G2 YES — WRONG-REASON is a hard failure. G3 YES — the library stays Python. The contract is locked; changes need a new ruling.
