## Context

Prerequisites:
- `typed-structured-outputs-foundation` provides typed-output validation/casting + structured errors.
- `typed-structured-outputs-signature-integration` wires typed schemas into `Signature.to_prompt/2` and `Signature.parse_outputs/2`.

Current state:
- `Predict` / `ChainOfThought` have `max_retries`, but retries are only triggered by LM call failures, not output parse/validation failures.

## Goals / Non-Goals

**Goals:**
- Add a **bounded retry** loop when typed-output parsing/validation fails.
- Make retry behavior deterministic and testable (mock LM).
- Provide a retry prompt that includes schema + a compact validation error summary.

**Non-Goals:**
- Provider-specific structured output APIs (OpenAI `response_format`, tool calling).
- Streaming structured outputs.

## Decisions

### Decision 1: Separate knob for output retries

To preserve existing behavior, introduce a separate opt-in setting:
- `max_output_retries` (default `0`)

`max_retries` remains “LM transport errors only”.

### Decision 2: Retry prompt content

On a typed-output failure, the retry prompt should:
- restate “return JSON only”
- include the schema hint (or a stable reference to it)
- include validation errors in a compact, path-oriented format

Example (sketch):

```
Your previous output did not match the required JSON schema.
Errors:
- $.components[0].component_type: expected one of ["subject","verb","object","modifier"], got "subj"
Return a JSON object matching the schema. Do not include markdown fences.
```

### Decision 3: Minimal deterministic repair (defer heavy repair deps)

We will only do deterministic repairs that are already proven valuable by tests:
- strip ```json fences
- attempt bracketed-object extraction

If we need stronger repair (single quotes, trailing commas, partial JSON), we will consider `:json_remedy` as a dependency via an explicit handshake.

## Risks / Trade-offs

- [Risk] Retry loops can silently hide real model failures.
  - Mitigation: keep retries bounded; return the final structured error when exhausted.

- [Risk] Prompt growth / repetition across retries.
  - Mitigation: keep retry prompt small; only include schema + errors.

## Migration Plan

- Backwards compatible: defaults keep current behavior.
