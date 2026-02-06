# GEPA.md — Teleprompter roadmap (spec + tests)

## Summary
**GEPA** is prioritized as an optimizer/teleprompter after the core Predict/Evaluate “golden path”. This doc is the **spec anchor** for how we intend to implement GEPA in Elixir (interfaces + determinism + tests), without committing to full algorithmic parity on day 1.

## Diagram
![GEPA flow](./diagrams/gepa_flow.svg)

## What GEPA should provide (user-facing)
- A teleprompter/optimizer that can **improve a program’s score** on a trainset deterministically (seeded).
- Works with stable program representations (no dynamic modules): uses `Dspy.Module.parameters/1` + `Dspy.Module.update_parameters/2`.
- Produces evidence via tests on a toy dataset:
  - baseline score
  - improved score
  - fixed seed run is reproducible

## Proposed Elixir interface
- Module: `Dspy.Teleprompt.GEPA`
- Functions:
  - `new/1` (requires `:metric` like other teleprompters)
  - `compile/3` (returns `{:ok, optimized_program}` or `{:error, reason}`)
- Integration point: `Dspy.Teleprompt.new(:gepa, ...)` and `Dspy.Teleprompt.compile/3` dispatch.

## Candidate/program representation (core design constraint)
- GEPA must only mutate program state via:
  - `Dspy.Module.parameters(program)` → list of `Dspy.Parameter`
  - `Dspy.Module.update_parameters(program, params)` → updated program
- Avoid dynamic module creation.

## Determinism requirements
- All stochastic steps must be seedable (explicit `:seed` option).
- Tests must use **mock LMs** (no network).
- Do not rely on wall clock for defaults in tests.

## Test plan (acceptance-style)
A minimal GEPA “spec suite” should include:
1. **Contract tests** (cheap):
   - `new/1` requires `:metric`.
   - `compile/3` returns a structured error until fully implemented.
2. **Toy improvement test** (the real acceptance signal):
   - A dataset where varying instructions/examples changes outcome.
   - Baseline program scores < 1.0.
   - GEPA-optimized program scores higher with a fixed seed.

## Non-goals (for now)
- Exact parity with upstream GEPA internals.
- Any orchestration/runtime integration (Jido) as part of GEPA.
