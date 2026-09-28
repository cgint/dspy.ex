# dspy.ex — where we are (plain overview)

Updated 2026-09-26 by Horst. Details for the team: `PLAN.md`.

## 1. What we are building
An Elixir version of Python DSPy that **behaves like Python DSPy 3.4.0** (the newest release, Sept 2026). Pure Elixir, no Python inside.
Rule for every release: the 5 projects that already use dspy.ex must keep working.

## 2. How far along are we?
Python DSPy 3.4.0 has **160 public features**. Of those, 10 are Python-only (we would skip them — needs your OK, see 6), leaving **150 that count**.

| Status | Count | Meaning |
|---|---|---|
| done | 18 | same behavior as Python, pinned by a test |
| done, Elixir-style | 19 | same capability, shaped the Elixir way |
| partial | 22 | exists, but options or behaviors are missing |
| missing | 91 | not there |

**→ 37 of 150 done (25%); about 32% if partials count half.**
- **Core is strong, breadth is weak:** the important everyday features (signatures, Predict, ChainOfThought, adapters, LM calls) are done or partial — none missing. Most of the 91 missing are less-used extras (special optimizers, metrics, helpers).
- **By DSPy release:** of features that existed in DSPy 2.6 we have 28 of 79; of those added in 3.0–3.4 only 9 of 81. The newer DSPy gets, the further behind we are.
- Checked by: 6 helper agents + a checker (which caught 18 over-optimistic ratings) + Greta + Horst (11 random rows verified by hand).
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
| Turning the count into milestones (what to build first) | so every step delivers something useful | Greta + Horst, then you approve | drafting |
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
- Coming soon: the milestone proposal (Greta and I agree it first).

## 7. Standing decisions (yours)
- Python DSPy is the reference: when unsure, do what Python does.
- Pure Elixir: no Python wrapper; anything Python-based needs your approval.
- Jido and LiveView can be added on top later; the library doesn't depend on them.

## Files in this folder
`PLAN.md` detailed plan · `PARITY_QUEUE.md` work list · `STATUS.md` history log · `GAP_ANALYSIS_3.4.0.md` the full count · `GAP_ANALYSIS_2026-05.md` old partial analysis (history).
