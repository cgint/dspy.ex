# dspy.ex — where we are (plain overview)

Updated 2026-09-26 by Horst. Details for the team: `PLAN.md`.

## 1. What we are building
An Elixir version of Python DSPy that **behaves like Python DSPy 3.4.0** (the newest release, Sept 2026). Pure Elixir, no Python inside.
Rule for every release: the 5 projects that already use dspy.ex must keep working.

## 2. How far along are we?
Python DSPy 3.4.0 has **160 public features**. Of those, 10 are Python-only (we would skip them — needs your OK, see 6), leaving **150 that count**.

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
The milestones themselves will be proposed after the count (step 4) — you approve them.

## 4. What is happening right now
| What | Why | Who | Status |
|---|---|---|---|
| Milestone proposal M1–M6 | so every step delivers something useful | Greta + Horst agreed; waiting for you | waiting for you |
| Crash/timeout hardening (H0b-1): a crash in one parallel piece no longer takes down the caller | stability, prerequisite for M1 | contract signed; team Katrin+Lukas+Mara building (tests first) | in progress |
| Making parallel work crash-safe (a crash or timeout in one background task must not take the whole program down) | reliability of optimizers and evaluation | Greta prepares, then a worker team | preparing |

## 5. Done this week
| Version | What users get |
|---|---|
| v0.3.40 | `Dspy.context`: temporarily change settings (e.g. which LM) for one block of code |
| v0.3.41 | `Dspy.BestOfN`: try a program up to N times, keep the best answer |
| v0.3.42 | `Dspy.Parallel`: run many programs/inputs at once |
| v0.3.43 | `Dspy.MultiChainComparison`: compare several reasoning attempts, pick the best |
| v0.3.44 | Settings from `Dspy.context` now also apply inside background work (evaluation, optimizers, tools) |

## 6. Waiting for you
- **Approve the 10 features we'd skip as Python-only** (reply OK or name any to keep):
  - `OldField`, `OldInputField`, `OldOutputField`, `infer_prefix` — deprecated leftovers in Python itself
  - `DSPyError` — Python's base exception class; Elixir uses `{:error, reason}` instead (we revisit this with the LM error types)
  - `disable_litellm_logging`, `enable_litellm_logging` — switches for LiteLLM, a Python library we don't use
  - `asyncify`, `syncify` — Python async plumbing; Elixir processes cover this
  - `dspy.utils.experimental` — a Python decorator for marking experimental code
- **Approve the milestone order** M1→M6 (see `GAP_ANALYSIS_3.4.0.md` §Phase C v2; each milestone = one sentence "after this you can…").
- **Evaluate changes by your "like Python" rule — object if not:** failed examples count as score 0 in the average (scores can drop); evaluation stops after 10 errors (also inside optimizers, so an optimization with ≥10 failing runs stops).

## 7. Standing decisions (yours)
- Python DSPy is the reference: when unsure, do what Python does.
- Pure Elixir: no Python wrapper; anything Python-based needs your approval.
- Jido and LiveView can be added on top later; the library doesn't depend on them.

## Files in this folder
`PLAN.md` detailed plan · `PARITY_QUEUE.md` work list · `STATUS.md` history log · `GAP_ANALYSIS_3.4.0.md` the full count · `GAP_ANALYSIS_2026-05.md` old partial analysis (history).
