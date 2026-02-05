# Strategic Roadmap: DSPy (Python) → Elixir-native `dspy.ex`

## Summary
This document is the durable “north star” for porting the upstream Python DSPy library (`../dspy`) into an Elixir-native, testable, maintainable library.

- **Core principle:** keep `:dspy` **library-only**.
- **Provider principle:** delegate provider HTTP/API surface to **`req_llm`**.
- **Orchestration principle:** keep **Jido v2** as an **optional integration layer**, not a core dependency.

## Diagram
![DSPy Port Strategic Roadmap](./diagrams/strategic_roadmap_dspy_port.svg)

## Reference (upstream ground truth)
- Upstream local checkout: `../dspy`
- Pinned commit (current): `970721b9911feb3205083585b1bd1935c5899647`

When semantics are unclear, prefer the upstream implementation over blog posts/docs.

## Roadmap (phased, execution via OpenSpec changes)
### Phase A — Foundation gate (repo health + provider layer)
**Goal:** a stable baseline where tests and tooling are always green.

Acceptance:
- `mix compile --warnings-as-errors` passes
- `mix test` passes
- `./precommit.sh` passes
- Default LM provider path goes through `Dspy.LM.ReqLLM` (adapter only; no provider quirks in core)

### Phase B — Core DSPy “golden path”
**Goal:** core program execution is correct and predictable.

Key capabilities:
- `Signature` prompt format + parsing are stable and covered by tests
- `Predict` and `ChainOfThought` run deterministically with a mock LM
- Program state is explicit (`parameters/1`, `update_parameters/2`) and teleprompt-friendly

### Phase C — Evaluation harness
**Goal:** we can measure improvements repeatably.

Key capabilities:
- Deterministic dataset splitting/sampling (`seed`)
- Metric library that matches what teleprompters need
- Safe parallel evaluation (`Task.async_stream`) and stable aggregation

### Phase D — Teleprompting (optimization)
**Goal:** at least 1–2 teleprompters that improve a score on a toy dataset deterministically.

Target order:
1. BootstrapFewShot
2. COPRO or SIMBA
3. (Later) MIPROv2

Non-goals:
- Do not chase full upstream breadth before we have a reliable evaluation loop.
- Avoid dynamic module generation; represent candidates as configs/parameters.

### Phase E — Optional integration layers
**Goal:** production-grade orchestration and UI without polluting core.

Deliverables:
- `dspy_jido` (in-tree initially or separate package) for Jido v2 runner semantics
- separate Phoenix/LiveView UI app/package depending on `:dspy`

## How execution will be organized
- Each concrete chunk of work becomes an **OpenSpec change** (proposal → tasks → implementation → verify → archive).
- `plan/STATUS.md` remains the “day-to-day” heartbeat (health, checklists, verification runs, learnings).

## Current state (as of last recorded work)
See `plan/STATUS.md` for the detailed checklist and verification commands.

## Open questions (to resolve early)
1. **Parity target:** Do we want to mirror Python DSPy public APIs, or only semantics while adopting idiomatic Elixir naming?
2. **Repo shape:** When (and how) do we relocate/gate `lib/dspy_web/*` and other non-core modules?
3. **Oracle tests:** Do we want dev/test-only Python execution (e.g., via `Pythonx`) to validate tricky teleprompt semantics?
