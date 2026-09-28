# NOW — dspy.ex at a glance (for humans)

Updated: 2026-09-26 by Horst. Kept current at every slice acceptance/release. One page, no history (history → `STATUS.md`).

## Goal
Native Elixir port of Python DSPy (the behavioral reference). No Python wrapper. Every release keeps the 5 consumer projects compiling (consumer canary).

## Done (latest)
| Tag | What |
|---|---|
| v0.3.40 | `Dspy.context/2` (scoped settings overrides) |
| v0.3.41 | `Dspy.BestOfN` + rollout-aware LM cache |
| v0.3.42 | `Dspy.Parallel` |
| v0.3.43 | `Dspy.MultiChainComparison` |

## In progress
| Slice | State | Owner |
|---|---|---|
| H0 caller context into all 13 spawn sites | all sites tested + mutation-proven, gates green; **awaiting Greta's outside verdict** → v0.3.44 | Judith's team |
| H0b crash/timeout hardening at spawn sites | groundwork (Greta's scouts) → Clarity Gate → launch after H0 | Greta / Horst |

## Next (order)
1. P4 program `save/load` · 2. P5 `inspect_history` · 3. Gap analysis vs Python DSPy **3.4.0** (last one is May, 210 upstream commits behind) — *needs your go* (updates `../dspy` reference checkout).

## Waiting for you
- Go for the 3.4.0 gap analysis?

## Decisions (standing)
- Python DSPy is the behavioral reference (no usage merge-back from child processes).
- Native port only; any Python-backed piece needs your approval. Jido/LiveView = optional layers on top.

## Where things live
Queue: `PARITY_QUEUE.md` · History log: `STATUS.md` · How we work: `HOW_WE_WORK.md` · File index: `README.md`
