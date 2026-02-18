## 0. TDD Foundations

- [ ] 0.1 TDD: add failing test coverage in `test/` that verifies tool declaration fields add `tools` to the request map before LM invocation.
- [ ] 0.2 TDD: add failing test coverage for parsing `tool_calls` completion metadata into a `:tool_calls` signature output field.
- [ ] 0.3 TDD: add failing test coverage for malformed tool definitions producing deterministic adapter errors instead of silent fallback.

## 1. Adapter protocol and request shaping

- [ ] 1.0 Add signature field types for tools and tool calls (`:tool`, `:tools`, `:tool_calls`) to the signature DSL/type validation and document how to declare them.
- [ ] 1.1 Extend `lib/dspy/signature/adapter.ex` with tool-aware request-shaping behavior (additive API, no breaking changes to existing callbacks).
- [ ] 1.2 Add or reuse tool conversion helpers (likely in `Dspy.Tools` or a new adapter utility module) to normalize `:tool` / `:tools` signature inputs into provider-compatible tool objects.
- [ ] 1.3 Update built-in adapters (at least `Dspy.Signature.Adapters.Default` and adapter wrapper path used for JSON-only behavior) to include `request.tools` when the signature declares tool fields.
- [ ] 1.4 Ensure existing adapter-selection and override precedence (`predict.adapter`, module override, global default) controls whether tool-aware formatting is active.

## 2. ToolCalls parsing and output integration

- [ ] 2.0 Normalize LM responses so adapter parsing can access tool calls in a provider-agnostic way (define one internal place where `tool_calls` live).
- [ ] 2.1 Add structured parsing for completion metadata containing `tool_calls` entries and return normalized `{name, args}` objects for fields typed `:tool_calls`.
- [ ] 2.2 Add validation/error tagging for malformed tool-call argument JSON and missing required `:tool_calls` outputs.
- [ ] 2.3 Ensure tool-call metadata does not populate non-` :tool_calls` outputs and does not break legacy text parsing when ToolCalls is not requested.
- [ ] 2.4 Keep adapter parse contracts backward-compatible for existing non-tool signatures (JSON/label fallback behavior unchanged).

## 3. Execution path integration

- [ ] 3.1 Update `lib/dspy/predict.ex` and `lib/dspy/chain_of_thought.ex` request generation to pass adapter-produced request maps when available.
- [ ] 3.2 Update parsing flow to pass completion metadata to the adapter parser for ToolCalls extraction while preserving text-only parsing paths.
- [ ] 3.3 Add a dedicated deterministic helper to avoid duplicating prompt-filling and attachment logic across modules.
- [ ] 3.4 Add focused docs update in compatibility/overview notes indicating native tool-calling is adapter-driven and opt-in via `:tool` / `:tool_calls` signatures.

## 4. Verification

- [ ] 4.1 Verification: run focused tests for the new adapter request-shaping and ToolCalls parsing specs and update any affected existing adapter-selection tests.
- [ ] 4.2 Verification: run focused regression tests for `Predict`, `ChainOfThought`, and `adapter` behavior (offline deterministic suite) to confirm no unrelated parsing regressions.
- [ ] 4.3 Verification: run a targeted end-to-end offline spec-like example demonstrating a provider that returns tool call metadata is converted into `:tool_calls` output.

## 5. Final verification by the user

- [ ] 5.1 Final verification by the user: confirm adapter-level tool inputs now map to request payloads and tool-call metadata maps to `:tool_calls` outputs as described in the specs.
- [ ] 5.2 Final verification by the user: confirm existing text-only workflows (no Tool/ToolCalls fields) behave exactly as before and no extra request-side side effects occur.
- [ ] 5.3 Final verification by the user: confirm the new capability is documented and the risk/unknown tradeoffs are acceptable for rollout.