# RELEASE_MILESTONES.md — Step-by-step roadmap (ship value early)

## Summary
We will ship this port in **manageable release milestones** that each deliver:
- something commonly needed
- with stable interfaces (Python DSPy familiarity)
- and thorough tests

This is not a “feature completeness” roadmap. It’s an **adoption-first** roadmap.

## Milestone definition
Each milestone should include:
- a short “what users can do now” description
- examples in `examples/`
- deterministic tests proving it works
- a compatibility note (Python DSPy / DSPex-snakepit alignment)

## R0 — Adoption Baseline (Predict/CoT + JSON output parsing + providers)
**Goal:** make the *most common* usage reliable.

Users can:
- define signatures
- run `Predict` and `ChainOfThought`
- parse outputs robustly, including JSON object outputs (JSONAdapter-style)
- use multiple providers through `req_llm` (OpenAI, Anthropic, etc. as supported)

Hard requirements:
- deterministic golden-path tests
- output parsing tests (label format + JSON object fallback)
- acceptance tests derived from `/Users/cgint/dev/dspy-intro/src` for the common workflows (see `plan/REFERENCE_DSPY_INTRO.md`)

## R1 — Evaluation you can trust
**Goal:** enable measurable iteration.

Users can:
- build a dataset/trainset
- run deterministic evaluation (seeded)
- use a small, well-defined metrics set
- run parallel eval safely (Task-based) with stable aggregation

Hard requirements:
- reproducible eval tests
- clear metric contracts (input/expected output)

## R2 — First "real" teleprompt (optimization)
**Goal:** demonstrate the DSPy differentiator (optimization) end-to-end.

Users can:
- run **GEPA** (or the next chosen teleprompter) to improve a score
- keep candidates as stable structs/parameters (no dynamic module creation)

Hard requirements:
- deterministic toy dataset where improvement is proven

## R3 — Interface alignment + expansion (careful)
**Goal:** improve familiarity without breaking stability.

Focus areas:
- tighten interface parity with upstream Python DSPy
- incorporate proven patterns from `../DSPex-snakepit` where it improves ergonomics
- expand teleprompter set (COPRO/SIMBA before MIPROv2)

Hard requirements:
- compatibility notes and tests for any changed behavior

## R4 — Optional layers (separate packages/modules)
**Goal:** keep core clean while enabling production usage.

Deliverables (optional, separate):
- Jido v2 runner integration layer
- Phoenix/LiveView UI (separate app/package)
