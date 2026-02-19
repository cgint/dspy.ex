## Status

Planning tasks (not started).

## Dependencies

- Requires `adapter-pipeline-parity`.
- Recommended after `adapter-callbacks`.

---

## 0. TDD foundations

- [x] 0.1 Test: signature tool declarations produce `request.tools` in the adapter-formatted request.
- [x] 0.2 Test: structured tool_calls in the LM response populate a `:tool_calls` output field.
- [x] 0.3 Test: malformed tool call argument JSON returns a tagged error.
- [x] 0.4 Test: non-tool signatures behave identically (no `tools` added, parsing unchanged).

## 1. Signature types + normalization

- [x] 1.1 Add signature field types for tools/tool_calls (exact naming to be decided and pinned by tests).
- [x] 1.2 Add a response normalization helper that exposes tool_calls (do not rely on text-only extraction).

## 2. Adapter request shaping

- [x] 2.1 Add adapter helpers to convert `Dspy.Tools.Tool` into canonical tool schema.
- [x] 2.2 Update built-in adapters to include `tools` in formatted request when tool inputs are present.

## 3. Adapter parsing

- [x] 3.1 Update adapter parse flow so tool_calls can be mapped into `:tool_calls` output.
- [x] 3.2 Ensure tool_calls do not pollute non-tool outputs.

## 4. Verification

- [x] 4.1 Run focused tests.
- [x] 4.2 Run `mix test`.
- [x] 4.3 Run `./precommit.sh`.
