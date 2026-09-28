# dspy.ex — where we are (plain overview)

Updated 2026-09-26 by Horst. Details for the team: `PLAN.md`.

## 1. What we are building
An Elixir version of Python DSPy that **behaves like Python DSPy 3.4.0** (the newest release, Sept 2026). Pure Elixir, no Python inside.
Rule for every release: the 5 projects that already use dspy.ex must keep working.

## 2. How far along are we?
- Python DSPy 3.4.0 offers about **135 public features** (classes and functions).
- How many of those dspy.ex already has: **not counted yet.** We are counting now (see 4). Result expected within about half a day.
- Until then, only this is certain: the basics (signatures, Predict, ChainOfThought, adapters, LM calls, evaluation, several optimizers) exist and are tested; 5 features were added this week (table below).

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
| Counting: which of the ~135 features dspy.ex has, partly has, or lacks | gives you the numbers for section 2 and the basis for milestones | Greta + helper agents; Horst checks samples | running |
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
- Nothing right now. Next time you'll be asked: approve the milestones and the list of Python features we deliberately skip (with reasons).

## 7. Standing decisions (yours)
- Python DSPy is the reference: when unsure, do what Python does.
- Pure Elixir: no Python wrapper; anything Python-based needs your approval.
- Jido and LiveView can be added on top later; the library doesn't depend on them.

## Files in this folder
`PLAN.md` detailed plan · `PARITY_QUEUE.md` work list · `STATUS.md` history log · `GAP_ANALYSIS_2026-05.md` old partial analysis (will be replaced by the count).
