# NOW — dspy.ex at a glance (for humans)

Updated: 2026-09-26 by Horst. Kept current at every slice acceptance/release. One page, no history (history → `STATUS.md`).

## Target & position (see PLAN.md)
- Target: behavioral parity with **Python DSPy 3.4.0**, native Elixir. Plan: `PLAN.md` (DRAFT v1, under Greta's review).
- Remaining count / % done: **unknown until the 3.4.0 inventory (phase B)** — the May analysis was only a delta, not a full inventory.
- Current phase: A (foundations: H0, H0b).

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
- Nothing right now — PLAN.md v1 is being reviewed with Greta; you get the agreed version.

## Decisions (standing)
- Python DSPy is the behavioral reference (no usage merge-back from child processes).
- Native port only; any Python-backed piece needs your approval. Jido/LiveView = optional layers on top.

## Where things live
All in `plan/current/`: queue `PARITY_QUEUE.md` · status/history `STATUS.md` · gap analysis vs upstream `GAP_ANALYSIS_2026-05.md` (May, stale-ish).
Process: `plan/HOW_WE_WORK.md` · everything else: `plan/README.md`.
