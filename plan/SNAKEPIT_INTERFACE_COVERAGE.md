# SNAKEPIT_INTERFACE_COVERAGE.md — DSPex-snakepit interfaces vs `dspy.ex`

## Summary
DSPex-snakepit (`../DSPex-snakepit`) exposes **Python DSPy** to Elixir via SnakeBridge/Snakepit.
This document tracks **which DSPex-snakepit user-facing interfaces** are already available natively in this repo (`dspy.ex`), and which are not.

Goal: keep our **end-user-facing behavior** close to Python DSPy **where it matters**, but allow BEAM/Elixir-idiomatic internals.

Reference oracles:
- DSPex-snakepit repo: `../DSPex-snakepit`
- Upstream Python DSPy checkout: `../dspy`

DSPex-snakepit pins Python DSPy at **`dspy==3.1.2`** (see `../DSPex-snakepit/snakebridge.lock`).

## What DSPex-snakepit exposes (two layers)
1) **Thin facade**: `DSPex.*` (`../DSPex-snakepit/lib/dspex.ex`)
2) **Generated bindings**: `Dspy.*` (`../DSPex-snakepit/lib/snakebridge_generated/dspy/**/*.ex`)

For the native port, the closest analogue is:
- our curated facade: `Dspy.*` (this repo) with small helpers in top-level `Dspy`.

## Coverage map (DSPex facade → `dspy.ex` native)

Legend:
- ✅ supported natively (same outcome achievable without Python bridge)
- 🟡 partially supported / different shape
- ❌ not supported yet

| DSPex-snakepit interface | What it is | Native `dspy.ex` equivalent | Status | Notes |
|---|---|---|---:|---|
| `DSPex.run/2` | lifecycle wrapper around Snakepit | (none) | ❌ | Native doesn’t need Python lifecycle mgmt; we may add script helpers, but not the same concern |
| `DSPex.lm/2` / `lm!/2` | create LM ref in Python | `Dspy.LM.new/2-3`, `Dspy.LM.new!/2-3` | ✅ | Native returns an Elixir struct adapter (ReqLLM by default) |
| `DSPex.configure/1` / `configure!/1` | configure global DSPy settings | `Dspy.configure/1`, `Dspy.configure!/1`, `Dspy.settings/0` | ✅ | Native settings stored in `Dspy.Settings` |
| `DSPex.predict/2` | construct Predict | `Dspy.predict/2` or `Dspy.Predict.new/2` | ✅ | We intentionally support arrow strings |
| `DSPex.chain_of_thought/2` | construct ChainOfThought | `Dspy.chain_of_thought/2` or `Dspy.ChainOfThought.new/2` | ✅ | Native CoT adds `:reasoning` output field |
| `DSPex.call/4` / `call!/4` | universal “call any Python module/function/class” | (no universal equivalent) | 🟡 | Native is explicit modules/functions; we generally avoid “stringly-typed reflection” in core |
| `DSPex.method/4` / `method!/4` | call a method on a Python ref | `Dspy.call/2` / `Dspy.Module.forward/2` (for programs) | 🟡 | Python refs vs Elixir structs/behaviours; conceptually similar for `forward` |
| `DSPex.attr/3` / `attr!/3` | read an attribute from a Python ref | `pred[:field]` / `pred.attrs.field` | 🟡 | Python attr lookup vs Elixir struct + `Access` |
| `DSPex.with_timeout/2`, `timeout_profile/1` | SnakeBridge runtime timeouts | per-call opts in request-map / OTP timeouts | 🟡 | Native timeouts are per-adapter concerns (e.g. ReqLLM) and OTP-level timeouts |

## Coverage map (selected generated `Dspy.*` bindings → `dspy.ex` native)

This is a **priority-filtered** list focused on the most common workflows.

| Python DSPy concept (via generated `Dspy.*`) | DSPex generated module (example) | Native `dspy.ex` module(s) | Status | Notes |
|---|---|---|---:|---|
| Signatures | `Dspy.Signature` | `Dspy.Signature` | ✅ | Native supports module signatures + arrow-string signatures |
| Predict | `Dspy.Predict` | `Dspy.Predict` | ✅ | Native returns `%Dspy.Predict{}` (struct), not Python ref |
| ChainOfThought | `Dspy.ChainOfThought` | `Dspy.ChainOfThought` | ✅ | |
| Example / Prediction | `Dspy.Example`, `Dspy.Prediction` | `Dspy.Example`, `Dspy.Prediction` | ✅ | Native implements `Access` for JSON-friendly usage |
| Evaluate | `Dspy.Evaluate` | `Dspy.Evaluate` + `Dspy.evaluate/4` | ✅ | Deterministic evaluation is a core native slice |
| Refine loop | `Dspy.Refine` | `Dspy.Refine` | ✅ | Acceptance test exists |
| JSONAdapter | `Dspy.Adapters.JSONAdapter` / `Dspy.JSONAdapter` | `Dspy.Signature.parse_outputs/2` (JSON fenced parsing) | 🟡 | We emulate the *behavior* without a 1:1 adapter object yet |
| ReAct | `Dspy.ReAct` | `Dspy.Tools.React` | 🟡 | Similar outcome; different module naming and tool schema |
| Retrieve / embeddings | `Dspy.Retrieve`, `Dspy.Embeddings` | `Dspy.Retrieve.*` | ✅ | Native includes RAG pipeline + retrievers |
| Teleprompters (BootstrapFewShot, COPRO, SIMBA, MIPROv2, GEPA, …) | `Dspy.Teleprompt.*` (various) | `Dspy.Teleprompt.*` | ✅ | Native teleprompters are parameter-based (no runtime modules) |
| RLM / PythonInterpreter | `Dspy.RLM`, `Dspy.PythonInterpreter` | (none) | ❌ | Requires a careful safety story; likely P2 |
| ProgramOfThought / CodeAct / CodeInterpreter | `Dspy.ProgramOfThought`, `Dspy.CodeAct`, `Dspy.CodeInterpreter` | (none) | ❌ | Not yet ported; overlaps with tools/sandboxing concerns |

## Implications for roadmap
- DSPex-snakepit is a **parity oracle** (because it is Python DSPy). We can use it to check our observable behavior without adopting its runtime architecture.
- For adoption-first native work, we should prioritize:
  1) Predict/CoT + parsing (incl JSON-style) + providers
  2) Evaluate determinism
  3) Teleprompters that matter most
  4) Tools/ReAct + Retrieval/RAG
- Treat RLM / sandboxed execution as **explicitly deferred** unless we decide to make it a first-class feature.
