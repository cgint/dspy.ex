# DSPy-for-Elixir Porting Charter (Ownership + Operating Agreement)

## Purpose
This repo exists to build a **maintainable, Elixir-native** implementation of the core ideas of the upstream **Python DSPy** library (see `../dspy`).

The intent is not “LLM utilities”, but specifically:
- **Composable LM programs** (Signatures + Modules)
- **Repeatable evaluation**
- **Algorithmic optimization** (“teleprompting”) of instructions/demos/parameters

## What “taking responsibility” means (in this repo)
Within the constraints of this agent harness (I can’t change your env vars, can’t do destructive git ops, and need your explicit approval before implementation changes), I will treat the DSPy port as a product with:

1. **A single source of truth for direction**
   - `plan/NORTH_STAR.md` defines the north star.
   - `plan/RELEASE_MILESTONES.md` defines the milestone sequence.
   - `plan/STRATEGIC_ROADMAP_DSPY_PORT.md` defines the long-term plan.
   - `plan/STATUS.md` tracks current health, decisions, and next steps.

2. **Small, verifiable, reversible progress**
   - Prefer incremental changes with tests.
   - Prefer “stable structs + parameters” over dynamic module generation.
   - Keep changes PR-sized and easy to review.

3. **Compatibility discipline (explicitly scoped)**
   - We optimize for **end-user-facing interface familiarity** and **functional/behavioral parity** with upstream Python DSPy.
   - We are **not** trying to mirror Python’s internal implementation details; we should use Elixir/BEAM strengths (data/immutability, concurrency, OTP) as long as the *observable behavior* remains close.
   - Any intentional divergence becomes a documented decision (what differs + why).

4. **Always-on verification**
   - Every change package includes reproducible verification steps (`mix test`, `./precommit.sh`, and at least one deterministic “golden path” test).

## Scope (what we consider “core DSPy” here)
In-scope for `:dspy` (library-only):
- `Dspy.Signature` (fields, validation, prompt building, output parsing)
- `Dspy.Module` + basic modules (`Predict`, `ChainOfThought`, etc.)
- `Dspy.LM` adapter layer (delegating provider specifics to `req_llm`)
- Evaluation (`Dspy.Evaluate`, datasets/trainsets, metrics)
- Teleprompting (`Dspy.Teleprompt.*`) with deterministic tests

Out-of-scope (should live outside core, or be gated):
- Phoenix/LiveView UI (`lib/dspy_web/*`)
- Long-running orchestration runtime as a hard dependency (Jido should remain optional)

## Upstream reference (ground truth)
Local upstream checkout:
- Path: `../dspy`
- Pinned commit (current): `970721b9911feb3205083585b1bd1935c5899647`

If we need strict comparisons, we will use “reference oracle” tests (Elixir vs Python side-by-side) in `test/` behind `:dev/:test` deps only.

## How we will work (Clarity-First)
- **Phase 1 (Planning)**: investigate + propose + write planning artifacts; stop for approval.
- **Phase 2 (Implementation)**: after explicit approval, implement tasks, tick them off, and verify.

This matches the repo’s existing guidance in `plan/WORKFLOW.md`.
