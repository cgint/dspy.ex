# Python-DSPy-compatible LM configuration: reasoning_effort

## Context

- `dspy.ex` delegates provider specifics to `req_llm` and tries to keep a small, Python-DSPy-like LM configuration surface via `Dspy.LM.new/2`.
- We recently added Python-aligned Gemini configuration (`thinking_budget` → `provider_options[:google_thinking_budget]`) and documented it in `docs/PROVIDERS.md`.
- Python DSPy and the local `dspy-intro` reference suite frequently configure LMs with a `reasoning_effort` knob (e.g. "low"/"medium"/"high" and sometimes "disable").
- `req_llm` already supports `:reasoning_effort` and translates it provider-appropriately (e.g. OpenAI Responses API `reasoning`, Anthropic extended thinking, etc.).
- `dspy.ex` currently does not expose a curated, safe `reasoning_effort` path in `Dspy.LM.new/2`.

Constraint: we must avoid atom-leak patterns (no `String.to_atom/1` on untrusted input). We should provide predictable validation and error messages.

## Goals / Non-Goals

**Goals:**
- Add a Python-DSPy-style `reasoning_effort` option to `Dspy.LM.new/2`.
- Support a small, documented set of values (atoms and strings) and normalize aliases (notably "disable").
- Forward the resulting value to `req_llm` via the existing ReqLLM adapter (as a default option on the LM instance).
- Provide deterministic unit tests that lock in the normalization/validation contract.

**Non-Goals:**
- Implement provider-specific reasoning logic in `dspy.ex` (owned by `req_llm`).
- Add automatic provider selection based on env vars (Python `dspy-intro` does this; out of scope here).
- Expand `Dspy.configure/1` global defaults to include reasoning controls (Python usage configures this on the LM instance).

## Decisions

1) **Implement normalization in `Dspy.LM.new/2` (constructor-time)**
- **Decision:** Validate + normalize `:reasoning_effort` inside `Dspy.LM.new/2` alongside existing curated options (e.g. `thinking_budget`).
- **Rationale:** Keeps the “Python-like kwargs” policy in one place, avoids sprinkling validation across call sites, and ensures a consistent contract for all modules using `%Dspy.LM.ReqLLM{default_opts: ...}`.
- **Alternatives considered:**
  - Validate in `Dspy.LM.ReqLLM` before dispatching: would require re-validating per call and couples adapter more strongly to onboarding ergonomics.

2) **Curated allowed values + safe string mapping**
- **Decision:** Accept `reasoning_effort` as either an atom or string; normalize strings to a safe, bounded set without creating new atoms.
  - Allowed atoms: `:none | :minimal | :low | :medium | :high | :xhigh`
  - Allowed strings: "none" | "minimal" | "low" | "medium" | "high" | "xhigh"
  - Alias: "disable" / `:disable` → `:none`
- **Rationale:** Matches user expectations (“minimal/low/medium/high”) while staying compatible with `req_llm`’s broader set and keeping atom usage safe.
- **Alternatives considered:**
  - Allow arbitrary strings and let providers error: would be less predictable and inconsistent across providers.
  - Allow arbitrary atoms: would reduce guardrails and make docs less reliable.

3) **Forwarding path: LM default opts**
- **Decision:** Encode the normalized value as a default option on the LM instance (i.e. `%Dspy.LM.ReqLLM{default_opts: [reasoning_effort: ...]}`), relying on the existing `default_opts` merge.
- **Rationale:** This matches how other defaults are passed and avoids widening the per-request option whitelist unless needed.

## Risks / Trade-offs

- **[Risk] Semantics differ across providers** (e.g. OpenAI expects low/medium/high only; others may accept minimal/xhigh)
  → **Mitigation:** treat this as a request *hint*; `req_llm` remains the provider translator; document the allowed set and that provider support varies.

- **[Risk] Users rely on Python string "disable"**
  → **Mitigation:** explicitly support "disable" and map it to `:none`.

- **[Trade-off] Slightly larger curated surface area in `Dspy.LM.new/2`**
  → **Mitigation:** keep the list small, well-tested, and push everything else behind `provider_options` / raw ReqLLM usage.
