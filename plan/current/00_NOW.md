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

## Incident 2026-09-28 (fixed)
- The automatic checks on GitHub (CI) had been **red since v0.3.42** without anyone noticing: one test file didn't compile on the older Elixir version CI uses (1.19), so CI ran no tests at all. Locally (Elixir 1.20) everything was green.
- **Your released library code was not affected** — the library compiles cleanly on 1.19; it was a test-file ordering bug. Fixed; CI is green again, all 453 tests pass on the CI version.
- Also: two of my plan commits accidentally included unfinished team code; removed from main within the hour, nothing released with it.
- Prevention: every release is now checked on the exact CI version first (`scripts/ci_docker.sh`), and CI must be green before a release counts as done.

## H0b-2 status (2026-09-28)
- Evaluation errors/scoring: built, Greta PASS after 2 review rounds, CI-docker green on 1.18 + 1.19. **Held locally until you answer Q2/Q3 below.**
- SEC-2 findings (Horst decided): extras' `hackney` has 4 advisories (1 high) with **no fix reachable** — `httpoison` pins old hackney; `cowlib` has 2 advisories with no fix at all upstream. Decision: replace `httpoison` in extras with `req` (already our core HTTP client) as its own slice; cowlib waits for upstream. Core library is clean.
- Newest Elixir (1.20) in CI: fails on 169 compiler warnings (new type checks) → own cleanup slice before adding it to CI.

## 6. Waiting for you (2 questions — 2026-09-28)
1. ~~Wider reach~~ *Decided by Horst (same decision you made, just 6 places instead of 4).* **Wider reach of "stop after 10 errors" (correction):** I told you it affects 4 optimizers; it is **6** — COPRO and GEPA also run evaluations internally. Same decision, just more places. OK?
2. **Metric returns something that isn't a number or true/false** (e.g. `nil`, text, a map; true/false now count as 1/0 like Python — found and fixed as a bug): we count it as a failed example (score 0). Python has no such check — it crashes later with a type error. Ours is friendlier but *differs from Python*. OK? If **no**, it would raise an error at the first such result (a behaviour change of its own; the in-between "valid 0" state would hide broken metrics, so it won't ship).
3. **Evaluate on an empty list of examples:** Python raises an error; dspy.ex returns 0.0. Recommend: raise like Python (breaks code that evaluates an empty list — none of the 5 projects do). OK?
3. **Saving results to CSV/JSON (M1):** Python crashes when rows have different fields or a value isn't JSON-compatible. Recommend: we don't crash (CSV header = all fields seen; odd values written as text). Or strictly like Python (raise)?
- Already read as yes: NimbleCSV for CSV files (say if not).
- *Decided by you 2026-09-28:* milestones M1→M6 ✓ · Evaluate like Python (failures count 0, stop after 10 errors) ✓ · skip the 10 Python-only features ✓ · minor version per milestone ✓.

## 7. Standing decisions (yours)
- Dependencies, security, toolchain: Horst decides (2026-09-28). Security fixed promptly; newest versions where possible; don't force users onto the newest Elixir without good reason.
- Greta and Horst drive M1→M6 on their own (2026-09-28). You are asked only for: new dependencies, breaking changes, scope decisions, deviations from Python behavior.
- Python DSPy is the reference: when unsure, do what Python does.
- Pure Elixir: no Python wrapper; anything Python-based needs your approval.
- Jido and LiveView can be added on top later; the library doesn't depend on them.

## Files in this folder
`PLAN.md` detailed plan · `PARITY_QUEUE.md` work list · `STATUS.md` history log · `GAP_ANALYSIS_3.4.0.md` the full count · `GAP_ANALYSIS_2026-05.md` old partial analysis (history).
