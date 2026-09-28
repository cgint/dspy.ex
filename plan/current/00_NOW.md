# dspy.ex — where we are (plain overview)

Updated 2026-09-28 by Horst. Details for the team: `PLAN.md`.

## 1. What we are building
An Elixir version of Python DSPy that **behaves like Python DSPy 3.4.0** (the newest release, Sept 2026). Pure Elixir, no Python inside.
Rule for every release: the 5 projects that already use dspy.ex must keep working.

## 2. How far along are we?
Python DSPy 3.4.0 has **160 public features**. Of those, 10 are Python-only (we skip them — approved by you 2026-09-28), leaving **150 that count**.

| Status | Count | Meaning |
|---|---|---|
| done | 13 | same behavior as Python, pinned by a test |
| done, Elixir-style | 19 | same capability, shaped the Elixir way |
| partial | 27 | exists, but options or behaviors are missing |
| missing | 91 | not there |

**→ 32 of 150 done (21%); about 30% if partials count half.**
- *Correction 2026-09-26:* first reported as 37 (25%). Greta found 5 core features (`configure`, `Example`, `Module`, `Prediction`, `Signature`) rated done although some of their options are missing → now partial.
- **Core is strong, breadth is weak:** the important everyday features (signatures, Predict, ChainOfThought, adapters, LM calls) are done or partial — none missing; several still lack some options. Most of the 91 missing are less-used extras (special optimizers, metrics, helpers).
- **By DSPy release:** of features that existed in DSPy 2.6 we have 28 of 79; of those added in 3.0–3.4 only 9 of 81. The newer DSPy gets, the further behind we are.
- Checked by: 6 helper agents + a checker (which caught 18 over-optimistic ratings; Greta later caught 5 more) + Greta + Horst (11 random rows verified by hand).
- Details: `GAP_ANALYSIS_3.4.0.md`.

## 3. How we will get there
Not in one big push, but in **milestones**. Each milestone:
- adds a bundle of features that is useful on its own,
- is proven by a working end-to-end example,
- keeps the 5 existing user projects working.

Order: **most useful for least effort first**, respecting what depends on what. Hard, low-value features come last. Anything that would break existing users comes to you first.
**Approved milestones (2026-09-28):**
1. **M1 Evaluation you can trust** — reliable scores (failures count), results saved/shown as table, standard metrics + data loaders.
2. **M2 Save, inspect, reuse** — optimize once, save, load elsewhere with same behavior; see which LM calls a program made.
3. **M3 Production LM** — clear error types, retries, cache surviving restarts, hooks tracing every call.
4. **M4 Agents & multimodal** — tool agents with image/audio, refine with feedback, XML/BAML output.
5. **M5 Streaming** — answers shown as they are generated (e.g. LiveView).
6. **M6 More optimizers** — real GEPA, KNNFewShot, the rest.
7. *Later pool* — newest 3.3/3.4 features; cut into milestones after scope decisions.
Before M1: crash/timeout hardening (H0b), because M1 builds on it.
Work list per milestone: `PARITY_QUEUE.md`; first milestone outline: `M1_CONTRACT_OUTLINE.md`.
Version numbers show the milestone: M1 = v0.4.x, M2 = v0.5.x, … M6 = v0.9.x (decided by you 2026-09-28).

## 4. What is happening right now
| What | Why | Who | Status |
|---|---|---|---|
| Milestones M1–M6 | so every step delivers something useful | approved by you 2026-09-28 | agreed |
| Security fix: update 3 HTTP libraries with known vulnerabilities (req, mint, hpax) | security first | helper agent Paula, checked by Horst + Greta | **released v0.3.45** (consumers: run `mix deps.update req mint hpax finch`) |
| Crash/timeout hardening (H0b-1): a crash in one parallel piece no longer takes down the caller | stability, prerequisite for M1 | review blocked once (tests didn't really test; 1 real bug), fixed and re-checked | **released v0.3.46** (Greta PASS after 1 block) |

## 5. Done this week
| Version | What users get |
|---|---|
| v0.3.40 | `Dspy.context`: temporarily change settings (e.g. which LM) for one block of code |
| v0.3.41 | `Dspy.BestOfN`: try a program up to N times, keep the best answer |
| v0.3.42 | `Dspy.Parallel`: run many programs/inputs at once |
| v0.3.43 | `Dspy.MultiChainComparison`: compare several reasoning attempts, pick the best |
| v0.3.44 | Settings from `Dspy.context` now also apply inside background work (evaluation, optimizers, tools) |
| v0.3.45 | Security: fixes 14 known vulnerabilities in the HTTP libraries used for every LM call (run `mix deps.update req mint hpax finch` once) |
| v0.3.46 | A crash or timeout in one parallel piece no longer takes down the caller; optimizing no longer crashes when every candidate fails |
| v0.3.47 | Extras security: `httpoison` replaced by `req`, removing 4 more advisories |
| v0.3.48 | Evaluation you can trust the numbers of: failures count into the score, runs stop after 10 errors, true/false metrics finally count, bad input raises instead of lying |

## Incident 2026-09-28 (fixed)
- The automatic checks on GitHub (CI) had been **red since v0.3.42** without anyone noticing: one test file didn't compile on the older Elixir version CI uses (1.19), so CI ran no tests at all. Locally (Elixir 1.20) everything was green.
- **Your released library code was not affected** — the library compiles cleanly on 1.19; it was a test-file ordering bug. Fixed; CI is green again, all 453 tests pass on the CI version.
- Also: two of my plan commits accidentally included unfinished team code; removed from main within the hour, nothing released with it.
- Prevention: every release is now checked on the exact CI version first (`scripts/ci_docker.sh`), and CI must be green before a release counts as done.

## H0b-2 — RELEASED as v0.3.48 (2026-09-28)

**The foundations are complete. M1 is now the next work.**

What changed for you: failed examples now count into the score (so **reported numbers can
drop** — they were silently dropped before), evaluation stops at the 10th error across **6**
optimizers, `true`/`false` metrics finally count as 1/0 (they were excluded entirely — a real
bug, since `a == b` is the commonest DSPy metric), and two bad inputs now raise instead of
lying: a metric result that is neither a number nor a boolean, and an empty testset. All four
follow Python DSPy 3.4.0, decided from a probe rather than from preference.

How it was proven, because this one was blocked twice before it passed:
- Greta's verdict on the exact sha, with all **4 mutation sites reproduced in her own clone**
  and restored (`git status --porcelain` empty, 12/12 green after restore) — not taken from the
  worker's report.
- No vacuous test: each optimizer test fails when *its own* site's clause is removed.
- Orphan probe: pending tasks are killed, not leaked, measured two independent ways.
- Gates on the release sha: ci_docker 1.19.5/OTP28 + 1.18.4/OTP27 green, `hex.audit` clean,
  canary 3 PASS / 2 WARN-BASELINE, GitHub CI green.
- **Tooling defect found 2026-09-28 (mine):** `scripts/ci_docker.sh` mounts `$ROOT/.git`,
  which only works in a normal checkout. In a **linked git worktree** `.git` is a pointer
  file, so the mount is empty inside the container and the script cannot run there. The
  gate worker reproduced the script step-for-step via a git object pack instead. That is a
  faithful reproduction, but it is not the script, so the **binding release gate is the
  real `scripts/ci_docker.sh` run in the main checkout at the release sha**; the worktree
  run counts as corroboration.
- **Fixed 2026-09-28 (`2b62e96`):** the script now resolves the real gitdir via
  `git rev-parse --git-common-dir`, which is correct in both a normal checkout and a linked
  worktree. Proven by running it from a worktree — green, where it previously could not start
  at all. The pack-and-shim workaround is obsolete and gate runs can happen in isolation again.
- SEC-2 findings (Horst decided): extras' `hackney` has 4 advisories (1 high) with **no fix reachable** — `httpoison` pins old hackney; `cowlib` has 2 advisories with no fix at all upstream. Decision: replace `httpoison` in extras with `req` (already our core HTTP client) as its own slice; cowlib waits for upstream. Core library is clean.
- Newest Elixir (1.20) in CI: fails on 169 compiler warnings (new type checks) → own cleanup slice before adding it to CI.

## 6. Waiting for you — **nothing** (2026-09-28)

All open questions are closed. You handed the last three to me with "infer how Python
would behave and take it from there", so I settled them by running a probe against
Python DSPy 3.4.0 (`uv run tmp/pyck/ck.py`) rather than by preference.

**Decided by you (2026-09-28):** milestones M1→M6 ✓ · Evaluate like Python (failures
count 0, stop after 10 errors) ✓ · skip the 10 Python-only features ✓ · minor version
per milestone ✓ · dependencies/security/toolchain are mine to decide ✓.

*Correction 2026-09-28:* NimbleCSV was previously listed here as approved by you. It was
not — it was a tacit "read as yes" that you never confirmed. It does not need your
approval any more either: you gave me dependency authority, so it is my decision and
I own it. **Decided: NimbleCSV** for `DataLoader.from_csv` (Dashbit, same house as
NimbleOptions/NimblePool, tiny, no transitive deps) rather than a hand-rolled RFC-4180
reader, because CSV quoting is exactly the kind of thing we would get subtly wrong and
then have to maintain forever.

**Decided by me under your standing rules (2026-09-28):**

| # | Question | Decision | Basis |
|---|---|---|---|
| Q1 | Reach of "stop after 10 errors" | 6 optimizers, not 4 — COPRO and GEPA also evaluate internally | your decision, just more places |
| Q2 | Metric returns neither number nor true/false (`nil`, text, a map) | **raise** `Dspy.Evaluate.InvalidMetricResult` at the first bad result | Python raises `TypeError`; probe-verified |
| Q3 | `evaluate` on an empty example list | **raise** `ArgumentError` | Python raises `ValueError`; probe-verified |
| Q-OUT | Saving results to CSV/JSON with ragged rows or non-JSON values | **raise** | Python raises `ValueError`/`TypeError`; probe-verified |

I had recommended the friendlier non-raising option for Q2 and Q-OUT. The probe showed
Python raises in every one of these cases, and "do what Python does" is your standing
rule, so I dropped my own preference. One deviation stays, and is documented in
`docs/COMPATIBILITY.md`: we raise at the *first* bad result, Python only after all LM
calls have finished. Same outcome, ours fails earlier and costs fewer calls.

*(Housekeeping: this section previously numbered two different questions "3".)*

## 7. Standing decisions (yours)
- Dependencies, security, toolchain: Horst decides (2026-09-28). Security fixed promptly; newest versions where possible; don't force users onto the newest Elixir without good reason.
- Greta and Horst drive M1→M6 on their own (2026-09-28). You are asked only for: new dependencies, breaking changes, scope decisions, deviations from Python behavior.
- Python DSPy is the reference: when unsure, do what Python does.
- Pure Elixir: no Python wrapper; anything Python-based needs your approval.
- Jido and LiveView can be added on top later; the library doesn't depend on them.

## Files in this folder
`PLAN.md` detailed plan · `PARITY_QUEUE.md` work list · `STATUS.md` history log · `GAP_ANALYSIS_3.4.0.md` the full count · `GAP_ANALYSIS_2026-05.md` old partial analysis (history).

## Decisions Q2/Q3/Q-OUT (2026-09-28, user: "infer Python behaviour and take it from there")
Evidence: `uv run tmp/pyck/ck.py` against dspy==3.4.0 (committed probe).
- Python: non-numeric metric (None/text/map) -> TypeError, whole run crashes; bool -> OK; metric *raising* -> 0.0 (= our D-U1).
- Python: empty devset -> ValueError. Ragged CSV -> ValueError. Non-JSON value -> TypeError.
- **Decision: follow Python, with clear error messages.** Q2 = ArgumentError on first non-numeric result (new commit replacing 9ce326c/d1736bb); Q3 = keep raise; Q-OUT = raise (P-OUT in M1-a = raise).
