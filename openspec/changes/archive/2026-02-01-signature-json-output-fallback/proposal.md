# Prevent signature parsing failures when LLM returns JSON

## Why

### Summary

`Dspy.Signature.parse_outputs/2` currently only extracts outputs from label-formatted text (e.g. `Change_id: ...`). In real downstream usage (and as reflected by the failing ExUnit test `DspyOpenSpecChangeIdSignatureExpectedBehaviorTest`), LLMs frequently return a JSON object (e.g. `{"change_id":"..."}`) even when instructed to use labels. This causes `{:error, {:missing_required_outputs, [:change_id]}}` and breaks integrations.

Upstream Python DSPy is more resilient because parsing is handled by an adapter layer and the default chat adapter falls back to a JSON adapter when the structured chat format fails.

### Original user request (verbatim)

Not available (this change directory did not capture the initiating request text).

## What Changes

- Extend `Dspy.Signature.parse_outputs/2` to accept JSON object output as an additional parsing strategy:
  - If the response text is (or contains) a JSON object, decode it and use its keys to populate signature output fields.
  - If JSON parsing fails or does not provide required fields, fall back to the existing label-based extraction.
- Refactor parsing logic into small, testable helper functions (separate responsibilities: JSON detection/extraction, JSON decoding, field mapping/type validation, required-field validation).
- Add focused unit tests to cover:
  - JSON-only output satisfies required outputs (makes the expected-behavior test green).
  - Existing labeled output continues to work.
  - Non-structured prose without outputs still yields `{:error, {:missing_required_outputs, [...]}}`.

### Non-goals

- Introduce a full adapter system like Python DSPy (deferred to keep scope small and unblock real-world usage quickly).
- Change `req_llm` integration/provider transport (this is pure local parsing and does not involve LM backends).

## Capabilities

### New

- Signatures can parse required outputs from JSON object responses (with fallback to label parsing).

### Modified

- None.

## Impact

- Affected code:
  - `lib/dspy/signature.ex` (`parse_outputs/2` and new helper functions)
  - tests under `test/` related to signature output parsing
- API/behavior impact:
  - Backwards compatible: existing label parsing remains unchanged.
  - More permissive: JSON object output (with matching keys) will now be accepted.
- Design direction:
  - This is a short-term resilience improvement while keeping the door open to a future adapter layer (chat-format parser + JSON fallback) similar to Python DSPy.
