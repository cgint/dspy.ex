# MEMORY.md — Compact context window (resume quickly)

## What this repo is
- Project: Elixir-native port of Python **DSPy** (upstream checkout at `../dspy`).
- Goal: open-source, community-adoptable library that combines **DSPy’s program+optimization** concepts with **BEAM/Elixir** reliability and concurrency.

## Non-negotiables (project constraints)
- Keep core `:dspy` **library-first**.
- Favor **interface familiarity** with:
  - upstream Python DSPy (primary)
  - `../DSPex-snakepit` where it helps adoption
- Prefer shipping **stable, frequently-used slices** over “feature completeness”.
- Testing is mandatory: new functionality should be covered by deterministic tests where possible.

## Current big decisions (so far)
- Provider layer: use **`req_llm`** via an adapter (`Dspy.LM.ReqLLM`), avoid maintaining provider-specific HTTP quirks in core.
- Orchestration: Jido v2 is valuable but should remain an **optional integration layer**, not a hard dependency of core.
- Keep web UI separate (or gated); don’t let Phoenix/LiveView concerns define core.

## Upstream reference
- Upstream repo path: `../dspy`
- Pinned commit recorded in `plan/PORTING_CHARTER.md` and `plan/STRATEGIC_ROADMAP_DSPY_PORT.md`.

## Reference example suite (acceptance specs)
- Python examples path: `/Users/cgint/dev/dspy-intro/src`
- Planning doc: `plan/REFERENCE_DSPY_INTRO.md`

## Repo navigation tips
- Entry point: `AGENTS.md`
- Planning artifacts: `plan/`
  - also see `plan/INTERFACE_COMPATIBILITY.md` when working on parity
- Classic docs: `docs/`

## “How to resume” checklist
1. Read `plan/STATUS.md` (what’s next, what’s blocked).
2. Read `plan/RELEASE_MILESTONES.md` (where we are in the roadmap).
3. If a task references interface parity, open upstream at `../dspy` and compare behavior.
4. Run verification (when implementing): `mix test` and `./precommit.sh`.

## Verification habits
- Prefer small changes that keep `mix test` green.
- Add a failing test first (TDD) for behavior changes.
