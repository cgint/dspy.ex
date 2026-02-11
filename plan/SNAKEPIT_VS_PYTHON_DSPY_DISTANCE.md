# SNAKEPIT_VS_PYTHON_DSPY_DISTANCE.md — How far is DSPex-snakepit from “pure” Python DSPy?

## Summary
DSPex-snakepit runs **real Python DSPy** behind a gRPC bridge and exposes it to Elixir via generated wrappers.

- **Functionally/semantically** (DSPy behavior): *very close* to Python DSPy, because it *is* Python DSPy.
- **Operationally/architecturally** (how you run it from Elixir): *meaningfully different*, because you now have a distributed/runtime boundary.

This matters because:
- For **behavior parity**, DSPex-snakepit is an excellent oracle.
- For **BEAM-native orchestration**, it imposes constraints (ref locality, session affinity, packaging).

DSPex-snakepit pins `dspy==3.1.2` (see `../DSPex-snakepit/snakebridge.lock`).

## Where it is effectively identical to Python DSPy
These aspects are “near-zero distance” because calls ultimately run in Python DSPy:
- Teleprompter semantics (as implemented by Python DSPy)
- Prompt formats/adapters (as implemented by Python DSPy)
- Any feature present upstream that DSPex has generated bindings for

## Where it differs (distance drivers)

### 1) Runtime boundary + object references
**Python DSPy:** values are in-process Python objects.

**DSPex-snakepit:** many values are **Python object refs** (handles). In Elixir you often:
- call `DSPex.method/4` to execute a method on the ref
- call `DSPex.attr/3` to fetch properties

Impact:
- harder to use Elixir pattern matching on values
- bridging introduces serialization rules and “graceful serialization” strategies

### 2) Session affinity / ref locality
Python objects are worker-local in a multi-process pool.
DSPex must model:
- session IDs
- pool routing
- worker lifecycle

Impact:
- user mental model includes “which worker owns this object?”
- failure modes include worker restart invalidating refs

### 3) Timeouts are first-class
DSPex adds explicit timeout profiles (`:ml_inference`, `:batch_job`, …) via `__runtime__` options.

Impact:
- not a Python DSPy concept per se; it’s bridge/runtime-specific

### 4) Packaging + reproducibility constraints
DSPex requires:
- Python + uv-managed environment
- snakebridge lockfile (`snakebridge.lock`) and setup commands

Impact:
- operational overhead vs a pure Elixir dependency

### 5) Error shapes and debugging experience
Python DSPy errors are Python exceptions.
DSPex wraps many errors into:
- `{:error, reason}` tuples
- bridge-level errors (gRPC, timeouts, serialization errors)

Impact:
- stack traces may cross language boundaries

## Practical conclusion (how to use this analysis)
- Treat DSPex-snakepit as:
  1) an **escape hatch** for “I need the exact upstream feature now”, and/or
  2) a **golden master oracle** to prevent semantic drift in our native port.

- Treat “distance” as primarily **runtime/ops friction**, not semantic friction.

## Suggested parity-check strategy for `dspy.ex`
- Use Python DSPy (`../dspy`) + DSPex-snakepit as references to validate:
  - prompt formatting
  - output parsing edge cases
  - evaluator semantics
  - teleprompter search semantics (where we claim parity)

…but keep the native implementation free to use BEAM idioms as long as the **observable behavior** stays close.
