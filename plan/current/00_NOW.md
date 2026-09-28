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
| Crash/timeout hardening (H0b-1): a crash in one parallel piece no longer takes down the caller | stability, prerequisite for M1 | contract signed; team Katrin+Lukas+Mara building (tests first) | in progress |

## 5. Done this week
| Version | What users get |
|---|---|
| v0.3.40 | `Dspy.context`: temporarily change settings (e.g. which LM) for one block of code |
| v0.3.41 | `Dspy.BestOfN`: try a program up to N times, keep the best answer |
| v0.3.42 | `Dspy.Parallel`: run many programs/inputs at once |
| v0.3.43 | `Dspy.MultiChainComparison`: compare several reasoning attempts, pick the best |
| v0.3.44 | Settings from `Dspy.context` now also apply inside background work (evaluation, optimizers, tools) |

## 6. Waiting for you
- **For M1 (not urgent, before M1 starts):** reading CSV datasets needs a CSV parser. Option 1: add the small standard library **NimbleCSV** (by Dashbit, same authors as tools we already use) — a new dependency needs your OK. Option 2: write our own small reader (more code to maintain, easy to get quoting wrong). I recommend option 1. *(Your "ok" 2026-09-28 read as approval of NimbleCSV — say if not.)*
- *Decided by you 2026-09-28:* milestone order M1→M6 (later pool cut after scope decisions) ✓ · Evaluate like Python (failures count 0, stop after 10 errors, also in optimizers) ✓ · skip the 10 Python-only features ✓.

## 7. Standing decisions (yours)
- Greta and Horst drive M1→M6 on their own (2026-09-28). You are asked only for: new dependencies, breaking changes, scope decisions, deviations from Python behavior.
- Python DSPy is the reference: when unsure, do what Python does.
- Pure Elixir: no Python wrapper; anything Python-based needs your approval.
- Jido and LiveView can be added on top later; the library doesn't depend on them.

## Files in this folder
`PLAN.md` detailed plan · `PARITY_QUEUE.md` work list · `STATUS.md` history log · `GAP_ANALYSIS_3.4.0.md` the full count · `GAP_ANALYSIS_2026-05.md` old partial analysis (history).
