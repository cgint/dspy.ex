# Analysis: Jido vs. dspy.ex for Elixir Agentic Systems

**User Request:**
> i need you to analyse how much overlap there is betwee @jido/ and @dspy/ - they have different tech stacks definitely. dspy.ex is a minimal implementation of dspy for elixir. my plan is to contribute to dspy.es as i want to have the way dspy works for elixir ecosystem. i use dspy for python a lot and i want to switch more and more to elixir, phoenix, liveview and use some layer to build agentic systems. now i need to understand 1. what is the main advantage of jido ? what does it very well compared to other agentic-ai-systems ? 2. what would it mean to advance dspy.ex ? would it make sense to have it be based on jido or req_llm so implement least possible inside dspy.ex. pls create a document, add diagrams and put this request at the top of the document

---

## 1. Executive Summary

**Jido** and **dspy.ex** solve different but complementary problems in the AI agent space.

- **Jido** is a **runtime + orchestration framework** (state, supervision, side effects, messaging).
- **dspy.ex** is a **prompt/program composition + optimization framework** (signatures, modules, teleprompters).

### Status / Versioning Note (Jido)

This document assumes **Jido v2** (currently published as `2.0.0-rc.1` on Hex: `https://hex.pm/packages/jido/2.0.0-rc.1`), which matches the **main branch** of `https://github.com/agentjido/jido`. The `v1.x` branch is the stable line but expected to be deprecated soon. This repo’s local checkout at `../jido` is the main branch.

### Diagram: High-Level Overlap

![Overlap Diagram](./overlap.svg)

---

## 2. Deep Dive: Jido

### What is the main advantage of Jido?
Jido’s primary advantage is that it **formalizes a production-grade agent pattern on top of OTP**, centered around a pure `cmd/2` core and directive-based side effects.

**What it does very well vs other agentic systems:**

1. **Deterministic, testable agent logic**
   - agent logic = pure state transition (`cmd/2`)
   - side effects = explicit data (`directives`)

2. **Operational robustness (OTP-native)**
   - supervision trees, process isolation, restart semantics
   - multi-agent lifecycle + hierarchy management

3. **Standardized communication model**
   - signals/envelopes, routing, pub/sub strategies

4. **Ecosystem layering**
   - `req_llm` as an LLM HTTP client
   - opt-in packages for actions/tools/signals/AI integrations

---

## 3. Deep Dive: dspy.ex

### What would it mean to advance `dspy.ex`?
Advancing `dspy.ex` means moving from “typed prompts” into **the DSPy differentiator**: *algorithmic optimization* of prompts/instructions/demos with a repeatable evaluation loop.

Key areas:

1. **Teleprompters (optimizers) that truly compile programs**
   - bootstrap/select demos
   - propose instructions
   - evaluate candidates
   - persist chosen parameters

2. **A reliable evaluation harness**
   - clear metrics API
   - reproducible sampling/splitting
   - parallel evaluation via `Task.async_stream` (and later distributed)

3. **A coherent internal program/parameter model**
   - represent “compiled” configuration (demos/instructions/params)
   - apply config deterministically in `forward/2`

---

## 4. Synthesis: Building a Unified Stack

### Does it make sense to base `dspy.ex` on Jido?
**As a hard dependency in the core library: usually no.**

- Jido is a runtime/orchestration choice.
- DSPy-style optimization should remain usable without requiring an agent runtime.

**But:** it makes a lot of sense to align `dspy.ex` with the Jido ecosystem:

- Prefer adopting **`req_llm`** as an LM backend (additive, low disruption).
- Provide an optional **bridge package** (e.g. `dspy_jido`) that wraps DSPy modules as Jido Actions/Skills.

### Diagram: Unified Agent Architecture

![Unified Architecture](./architecture.svg)

---

## 5. Recommendation for Contributions

To maximize impact (and keep things maintainable):

1. **Keep `dspy.ex` focused on DSPy concepts**
   - signatures/modules/teleprompt/eval

2. **Adopt `req_llm` through a new LM adapter**
   - minimal changes to existing APIs

3. **Use Jido at the application layer**
   - let Jido run long-lived agents
   - let `dspy.ex` provide the reasoning/optimization components

---

## 6. Impact on the current `dspy.ex` code structure (how much needs to change?)

This section is specifically about **maintainer acceptance**: how much of the existing implementation can stay stable if we move `dspy.ex` toward a more “real DSPy” feature set and/or toward the Jido ecosystem.

### 6.1 What can likely stay as-is (good news)

From reviewing the current code, the project already has the right top-level shape:

- **`Dspy.Signature`**: typed IO contract + prompt building/parsing.
- **`Dspy.Module` behaviour**: a coherent `forward/2` contract.
- **`Dspy.Predict` / `Dspy.ChainOfThought`**: thin wrappers around prompt + LM call.
- **`Dspy.LM` behaviour + `Dspy.Settings`**: pluggable LM backend + global config.
- **`Dspy.Teleprompt` behaviour + `Dspy.Teleprompt.*`**: optimizer API exists.

This is a strong signal that advancing the library does **not** require a rewrite; most work can be internal improvements while keeping the surface area stable.

### 6.2 What will need some refactoring (moderate changes)

1) **LM call consistency / API correctness**
- `Predict`/`ChainOfThought` call `Dspy.LM.generate_text/2` → consistent.
- Some teleprompt code (e.g. `MIPROv2`) calls `LM.generate(...)` in a way that does **not** match the defined `Dspy.LM` behaviour (`generate/2` expects a request map). To get to “real DSPy”, internal LM calls must be standardized on the request map contract.

2) **Candidate program representation**
- Some teleprompts generate dynamic modules via `defmodule` inside `compile/3`.
- This is workable for experiments, but often hurts acceptance/maintainability (debuggability, determinism, atom leakage risk).
- More maintainable: represent candidates as **structs** (configuration) applied by a stable module, or use a parameter update mechanism rather than generating new modules.

3) **Scope/noise management**
- `lib/dspy/` contains many large “experimental” modules.
- For maintainer acceptance, focus changes narrowly on LM + evaluation + teleprompt correctness and avoid broad reorg/renames.

### 6.3 Where adopting Jido or `req_llm` fits with minimal disruption

- **Adopt `req_llm` (low-risk, high-value):**
  - Add `{:req_llm, ...}` dependency and implement `Dspy.LM.ReqLLM` (or similar) that satisfies the existing `Dspy.LM` behaviour.
  - No need to change `Dspy.Predict`/`ChainOfThought` call sites.

- **Avoid embedding Jido into the `dspy.ex` core (higher risk):**
  - raises dependency weight and narrows adoption
  - scope mismatch (“agent runtime inside prompt optimizer”)

- **Prefer a bridge package (lowest friction):**
  - `dspy_jido`: wrap DSPy modules as Jido Actions/Skills
  - keeps `dspy.ex` clean and easier to merge upstream

### 6.4 Maintainer acceptance strategy (pragmatic)

Given the maintainer is currently unresponsive, the best tactic is layering small PRs:

1. **PR 1: correctness + tests**
   - fix LM request-shape mismatches inside teleprompts
   - add focused unit tests
2. **PR 2: `req_llm` LM adapter (additive)**
   - new LM backend without removing existing clients
3. **PR 3: harden eval + teleprompt loop**
   - deterministic sampling, stable candidate representation, parallel eval

## Diagram: Upstream vs Fork path

![Maintainer paths](./maintainer_paths.svg)

### 6.5 If upstream doesn’t respond: fork considerations

Forking is viable, but reduce ecosystem confusion:

- publish under a distinct Hex name (avoid hijacking `:dspy`)
- keep API close to original to ease migration
- document changes clearly (LM backend, teleprompt correctness, eval loop)

---

### 6.6 “Ground truth” references while implementing DSPy semantics

Two sources are particularly useful to reduce ambiguity and speed up correct implementations:

1. **Upstream DSPy Python source (best detail level)**
   - This repo contains a full checkout at `../dspy`.
   - When DSPy website docs and behavior diverge, prefer the Python implementation.

2. **Curated docs via `asks.sh`**
   - Use `asks.sh` to quickly query DSPy and Elixir ecosystem references.
   - See: `dspy.ex/docs/ASKS_TOOLING.md` for recommended topics and usage.
