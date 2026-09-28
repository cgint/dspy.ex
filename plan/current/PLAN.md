# PLAN — dspy.ex to Python DSPy 3.4.0 parity

Status: **DRAFT v1 (Horst, 2026-09-26) — awaiting Greta's critique; not yet agreed.**
Detail level: enough to steer and measure; slices get their own contracts (Clarity Gate) when they start.

## 1. Target
Behavioral parity with **Python DSPy 3.4.0** (tag `3.4.0`, 2026-09-24; reference worktree `../dspy-3.4.0`) for everything that is **public and user-facing**, implemented natively in Elixir.
- Python DSPy is the reference: same behavior unless an item is explicitly marked *not applicable* with a reason.
- Not v2 first: dspy.ex is built on the 3.x API; v2 is obsolete.
- Constraint: every release keeps the 5 consumer projects compiling (canary) and the 33 consumer-contract tests green.

## 2. Scope rules (what counts as an item)
- **In**: public classes/functions users call or configure: signatures, predictors/modules, adapters, LM client surface, evaluation, optimizers (teleprompters), retrieval, streaming, utilities (inspect_history, save/load, usage, callbacks, caching), settings/context.
- **Not applicable** (with reason, counted separately): Python-only mechanics (pickle/cloudpickle, LiteLLM internals, Deno/PythonInterpreter sandbox, async-vs-sync duplication, packaging).
- **Open (decide in inventory)**: `experimental/`, `datasets/`, GEPA (external dependency), streaming.

## 3. Measure of progress
One inventory `plan/current/GAP_ANALYSIS_3.4.0.md`: every in-scope item → `done` / `partial` / `missing` / `n/a`, with upstream file ref and dspy.ex file/test ref.
Headline numbers (per area + total) go to `00_NOW.md`. `done` requires a test that pins the behavior.

## 3b. How we prioritize (user guidance 2026-09-26)
Priorities come from **two maps side by side**: where dspy.ex stands today, and where Python DSPy's milestones are (what each 3.x release added: 3.0 → 3.1 → 3.2 → 3.3 → 3.4).
- Rank items by **user value ÷ effort**. Low-hanging fruit with real value goes first; don't chase a hard, far target while easy wins sit unused.
- Every step must leave a **usable system**: each milestone is a coherent release that works end to end and stays compatible with the consumers.
- Set **dspy.ex milestones** (M1, M2, ...) as usable bundles, each defined by what a user can do afterwards. Map each to the DSPy release whose features it covers. "Parity with 3.4.0" is the end point, not the first milestone.
- The inventory therefore records per item: status, **user value**, **effort (S/M/L)**, **which DSPy release introduced it**, and dependencies.

## 4. Phases
| Phase | Content | Exit |
|---|---|---|
| A. Foundations (now) | H0 context propagation, H0b crash/timeout hardening | released, canary green |
| B. Inventory | Full 3.4.0 inventory (Greta's scouts per area, Horst verifies samples) | numbers in 00_NOW, Greta+Horst agree |
| C. Re-plan | dspy.ex milestones M1..Mn defined (usable bundles, value÷effort order), queue rebuilt per milestone | Greta+Horst agree, user agrees milestones |
| D. Execute | Slices through HOW_WE_WORK (contract → team → verify → outside review → release) | per slice |
| E. Keep up | Re-inventory at each upstream release (delta only) | recurring |

## 5. Current position
Phase A. Released this campaign: v0.3.40–v0.3.43 (context, BestOfN, Parallel, MultiChainComparison). H0 in final fixes. Total-parity % unknown until phase B.

## 6. Open decisions
| # | Question | Who | Status |
|---|---|---|---|
| 1 | Scope of `experimental/`, `datasets/`, GEPA, streaming | Horst+Greta propose, user decides | open |
| 2 | Order of phase B vs H0b (parallel is possible: B is read-only) | Horst+Greta | proposal: parallel |

## 7. How this plan is maintained
- Horst owns it; Greta reviews every material change; the user is told of changes via 00_NOW.
- Self-check at each phase exit: what did we assume that turned out wrong? Record it here.
