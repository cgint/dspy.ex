# DSPex-snakepit wrapper reference (SnakeBridge/Snakepit) — notes for dspy.ex

**User request (verbatim):**

> pls see /Users/cgint/dev-external/DSPex-snakepit/ for such an implementation of a wrapper

## Summary

`/Users/cgint/dev-external/DSPex-snakepit/` is a concrete example of a **full Python DSPy wrapper** for Elixir implemented via:

- **SnakeBridge** (Universal FFI + generated Elixir bindings), and
- **Snakepit** (a **gRPC bridge** to a managed pool of Python worker processes).

This is **not** Pythonx/NIF embedding; it is a “Python workers behind gRPC” approach.

Key takeaways for our dspy.ex endeavour:

- This wrapper provides **immediate feature parity** (because it runs the real Python DSPy), and is therefore a strong candidate for **“reference oracle / golden master”** testing.
- It also demonstrates the **maintenance/operational costs** of a wrapper-first strategy: session affinity, object reference locality, serialization challenges, Python runtime packaging.
- It contains several patterns worth borrowing even for a native port (timeouts, lifecycle ownership, strict session routing) — while still keeping DSPy core logic native if our goal is BEAM-first orchestration.

## Questions & answers (from this thread)

### Q: “what is your gist/tl'dr and take-away?”

**A:** DSPex-snakepit is a strong wrapper-first approach: it exposes Python DSPy via generated Elixir modules and runs calls in pooled Python workers over gRPC. You get parity quickly, but you inherit the wrapper tax: session affinity/ref locality, Python runtime packaging, and cross-boundary serialization.

### Q: “what does this mean for us — is it a good idea to follow the native path even?”

**A:** Seeing DSPex makes the trade-off concrete and generally **strengthens** the case for a native `dspy.ex` core *if* our goal is “DSPy as an Elixir-first primitive”:

- Native is the right choice when we care about **BEAM/OTP-level control** over evaluation/optimization loops (supervision, cancellation, retries, progress events, distribution) and want a clean `req_llm` provider adapter.
- Wrapper-first is the right choice when we care primarily about **feature parity now** and accept that most orchestration logic lives in Python.

**Pragmatic hybrid:** keep `dspy.ex` native, and use DSPex as a **reference oracle** in dev/test (golden-master fixtures) to reduce semantic drift.

### Q: “why should people want to use the native implementation over the snakepit version?”

**A:** Prefer a native `dspy.ex` when you want the *DSPy paradigm* but need the runtime and control-flow to be **BEAM-native**, not Python:

- **BEAM/OTP-level orchestration:** run evaluation/optimization loops as supervised, cancellable, retryable jobs with clear failure isolation.
- **Observability + UI integration:** emit telemetry/events per step and stream progress to LiveView/Jido-friendly consumers without deep Python instrumentation.
- **Operational simplicity:** ship an Elixir dependency (plus `req_llm`) instead of a Python runtime + uv-managed env + gRPC worker pools.
- **Native concurrency/distribution:** scale with OTP primitives directly, without ref locality and session-affinity constraints.
- **Elixir-native APIs:** structs/behaviours, predictable `{:ok, _} | {:error, _}`, fewer “Python-shaped” values and refs.

When the priority is **feature parity now** (all DSPy optimizers/modules), the snakepit wrapper can be the better choice—but it keeps most DSPy control-flow in Python and makes session routing/ref locality a first-class concern.

### Clarifying decision question

In ~6 months, do we want:

- **A)** “teleprompt optimization as supervised, cancellable, observable BEAM jobs with LiveView/Jido-friendly instrumentation” (native-first), or
- **B)** “call any DSPy feature from Elixir with minimal porting effort” (wrapper-first)

## Diagram

![DSPex wrapper architecture](./dspex_snakepit_wrapper_reference.svg)

## What DSPex-snakepit implements

### 1) Dual API surface: generated `Dspy.*` + thin convenience layer

DSPex intentionally exposes **two layers**:

1. **Generated bindings (`Dspy.*`)**
   - Location: `lib/snakebridge_generated/dspy/*.ex`
   - They mirror Python DSPy’s package/class layout.
   - Each function calls into SnakeBridge runtime:
     - `SnakeBridge.Runtime.call_class/…` (constructors)
     - `SnakeBridge.Runtime.call_method/…` (method calls)
   - Example modules:
     - `Dspy.LM`
     - `Dspy.Predict`
     - `Dspy.BootstrapFewShot`
     - `Dspy.GEPA`
     - `Dspy.Predict.RLM`

2. **Thin facade (`DSPex`)**
   - Location: `lib/dspex.ex`
   - Provides:
     - `DSPex.run/1` lifecycle wrapper around Snakepit
     - ergonomic helpers: `lm!/2`, `predict!/2`, `chain_of_thought!/2`, `configure!/1`
     - universal pass-through: `call/…`, `method/…`, `attr/…`
     - timeout helpers via `__runtime__` (see below)

This split is a good pattern when you want both:
- maximal parity (generated tree), and
- a curated, stable “happy path” API (facade).

### 2) Python dependency management + reproducibility

- Python library deps are declared in `mix.exs` via `python_deps/0`.
- Setup is performed with `mix snakebridge.setup` (uses `uv` under the hood).
- Reproducibility is captured in `snakebridge.lock`:
  - Python version and platform
  - resolved Python package versions (e.g., `dspy 3.1.2`)
  - generator hash

This design is a real operational benefit vs ad-hoc “bring your own venv”.

### 3) Concurrency model: Python worker pool(s) + session affinity

DSPex runs multiple Python workers (multiple processes) behind gRPC.

However, **Python object references are worker-local**, which forces a routing model:

- **Strict affinity pools** for stateful refs (LMs, predictors, RLM instances)
- Every call can carry `__runtime__` options such as:
  - `pool_name`
  - `session_id`

DSPex showcases multi-pool routing in the flagship examples/guides:
- `guides/flagship_multi_pool_gepa.md`
- `guides/flagship_multi_pool_rlm.md`

**Implication:** wrapper-based DSPy in Elixir can be concurrent, but you must model:
- session lifecycle,
- ref locality,
- worker failure / session rehydration.

### 4) Handling non-serializable Python values (“graceful serialization”)

Prompt history inspection and other introspection features often return objects that can’t be trivially serialized across the bridge (e.g. response objects).

DSPex uses a “graceful serialization” approach:
- preserve serializable structure,
- keep problematic values as Python refs.

This is essential for usability when bridging large Python libraries.

## How this relates to our `dspy.ex` strategy

### Wrapper-first vs native port (what DSPex makes concrete)

DSPex demonstrates what you get with a wrapper:

- **Pros**
  - feature parity today (optimizers, modules, etc.)
  - minimal algorithm porting effort
  - good developer experience via generated docs and module structure

- **Cons**
  - DSPy’s *control flow* (teleprompter loops, eval loops) stays in Python → harder to make BEAM/Jido the “orchestrator of record”
  - operational cost: Python runtime packaging and bridge management
  - ref locality/session affinity becomes a first-class concern

### Why this is still valuable even if we keep the native port

Even if we keep `dspy.ex` native (recommended in our current docs), DSPex can serve as:

- a **semantic oracle** (golden master)
  - compare prompt structures, request/response normalization, and optimizer outcomes in deterministic test fixtures
- a **reference for tricky DSPy behaviors**
  - especially teleprompter semantics and edge cases

## Recommended next steps (non-implementation)

1. Decide explicitly how we will use DSPex:
   - (A) oracle tests only (dev/test), or
   - (B) keep a wrapper package as an alternative runtime for parity.
2. If (A), define 2–3 golden-master fixtures we care about:
   - `Predict` prompt formatting and output parsing
   - `BootstrapFewShot` demo selection behavior
   - basic `Evaluate` loop scoring
3. Keep `dspy.ex` provider layer aligned with `req_llm` (separate concern from “DSPy wrapper”).

## Files referenced

- `DSPex` facade: `lib/dspex.ex`
- Generated DSPy bindings: `lib/snakebridge_generated/dspy/*.ex`
- Setup + deps: `mix.exs`, `snakebridge.lock`
- Multi-pool demos:
  - `examples/flagship_multi_pool_gepa.exs` + `guides/flagship_multi_pool_gepa.md`
  - `examples/flagship_multi_pool_rlm.exs` + `guides/flagship_multi_pool_rlm.md`
