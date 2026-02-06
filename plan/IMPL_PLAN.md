# Implementation Plan: DSPy Core → `req_llm` → Teleprompters (GEPA priority)

Outcome: Ship a stable, testable DSPy-style core in `dspy.ex` as a **library-only** project, use **`req_llm`** for low-level LLM provider access, then deliver real optimization value via teleprompters (GEPA is a priority).

Note: Jido integration is explicitly **out of scope for now**; revisit only after core + key teleprompters are solid.

Success criteria:
- `Predict`/`ChainOfThought` + `Evaluate` run end-to-end deterministically with a mock LM.
- Teleprompt(s) can improve scores on a toy dataset with a fixed seed.
- Low-level LLM API/provider maintenance is delegated to `req_llm` (single adapter in `dspy.ex`).
- Teleprompting includes a real, valuable optimizer; **GEPA is prioritized** over orchestration/runtime integrations.

## Diagram
![Implementation Plan](./diagrams/impl_plan.svg)

## Scope & principles

- Keep `dspy.ex` **library-only**. A web UI can exist as a separate package/app that depends on `:dspy`.
- Keep DSPy core independent of Jido (runtime/orchestration stays outside core).
- Do not maintain vendor-specific LLM HTTP APIs in `dspy.ex`; use `req_llm`.
- Follow `req_llm`’s two-layer model:
  - **High-level API (default):** use unified functions (e.g. text generation + streaming) with standardized requests/responses.
  - **Low-level API (escape hatch):** allow advanced HTTP/provider control via Req plugin access, but keep it contained to the adapter layer.
- Prefer small, verifiable steps; avoid “big bang” refactors.
- Use request-map LM calls consistently (`Dspy.LM.generate/2`); keep `generate_text/2` as a convenience wrapper only.

## Phase 0 — Lock repo shape + LLM provider basis (foundation gate)

Decisions:
- **Library-first:** `dspy.ex` does not ship Phoenix/web modules; a web interface is a separate package/app depending on `:dspy`.
- **Provider layer:** `dspy.ex` uses **`req_llm`** as the low-level provider client; `dspy.ex` maintains only an adapter.

Deliverable:
- A compile+test baseline for library-only `dspy.ex`.
- A clear “out of tree” boundary for any future `dspy_web` package.

## Phase 1 — Stabilize DSPy core “golden path”

Goal: A minimal, correct, testable DSPy core loop.

Work items:
- Normalize LM calling convention across repo:
  - Teleprompts and tools must not call `LM.generate(lm, prompt, opts)`; instead build a request map and call `Dspy.LM.generate(lm, request)`.
  - Keep prompt-string helpers (`generate_text/2`) as thin wrappers.
- Implement (and use) a single low-level LM adapter:
  - Add `Dspy.LM.ReqLLM` that satisfies `Dspy.LM` and delegates provider HTTP details to `req_llm`.
  - Use `req_llm` **high-level** API by default for common flows (text + streaming).
  - Keep a documented **escape hatch** for `req_llm` low-level Req plugin usage when needed (without leaking provider specifics into core DSPy modules).
- Make “optimizable program state” explicit:
  - Ensure `Predict` (and other optimized modules) expose `parameters/1` and `update_parameters/2` so teleprompters can mutate instructions/demos without runtime `defmodule`.
- Add/adjust tests around:
  - deterministic evaluation (`seed`)
  - LM request-shape correctness

Deliverable:
- A small example program + tests proving `Predict` → `Evaluate` works deterministically.

## Phase 2 — Bring teleprompters to “real” (GEPA priority)

Goal: A teleprompter that measurably improves performance, using an Elixir-native candidate representation.

Pick order (subject to adjustment as we learn):
1. **GEPA** (see `plan/GEPA.md`)
2. **BootstrapFewShot** (foundational)
3. **COPRO** or **SIMBA**
4. **MIPROv2** (later; depends on more moving parts)

Work items:
- Represent candidates as structs/config applied to stable modules (no dynamic modules).
- Add tracing/capturing of predictor calls if needed for bootstrapping semantics.
- Align algorithm intent with upstream `../dspy` where practical (not strict parity).

Deliverable:
- A toy dataset + fixed-seed run that shows an improvement and is reproducible.

## Phase 3 — (Deferred) orchestration/runtime integration

Intentionally deferred. We focus on:
- core DSPy workflows
- evaluation
- teleprompters/optimizers (GEPA priority)

We can revisit orchestration (e.g., Jido) once the basics are solid and we have real workloads to orchestrate.

## Verification (each phase)

- `mix test`
- A single “golden path” script/example that runs deterministically with `seed`.

## Open questions

- Do we want a separate repo/package for `dspy_jido`, or keep it in-tree initially?
- Should `dspy.ex` ship only `Dspy.LM.ReqLLM`, or also keep other LM adapters as optional add-ons?
