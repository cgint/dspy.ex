## Context

See `proposal.md`. `JSV.Schema.normalize_collect/2` emits reusable nested definitions under `$defs`; JSONAdapter embeds each typed field schema inside an outer object contract. ReqLLM uses that contract directly for supported native providers and falls back to text on errors.

## Goals / Non-Goals

**Goals:**
- Produce a reference-free local schema for native output contracts.
- Reject recursive or non-local references deterministically.
- Preserve JSONAdapter’s one shared prompt/native contract and existing parser.
- Make native failure before text fallback observable without provider calls in tests.
- Load schema modules before checking their schema callbacks.

**Non-Goals:**
- General JSON Schema reference resolution, recursive-schema support, changing unsupported-provider fallback, or attaching provider metadata to response maps.

## Decisions

### Add a pure native-schema normalization boundary
`Dspy.TypedOutputs.native_schema/1` will normalize a schema, remove JSV metadata, and inline only local `#/$defs/<name>` references. It returns `{:error, {:recursive_schema_reference, ref}}` for cycles and a tagged unsupported/unknown reference error otherwise. This keeps invalid provider contracts out of ReqLLM and gives callers a testable boundary. A provider-specific sanitizer would duplicate schema policy across adapters.

### Build the adapter-owned contract from native schemas
JSONAdapter will use the reference-free schema for typed fields before composing its outer object. Its prompt serialization is already derived from that exact outer map, preserving the existing equality invariant. The standalone prompt-schema helper may continue to preserve references because it is not a native provider contract.

### Warn at the fallback boundary
ReqLLM will issue `Logger.warning/1` with the native reason immediately before text fallback. A response metadata channel is deferred because the current normalized response shape has no stable metadata API; warning is the minimum observable behavior and avoids changing caller contracts.

### Load modules explicitly
`normalize_schema/1` will call `Code.ensure_loaded/1` before `function_exported?/3`; this addresses first-touch failure without changing valid schema behavior.

## Risks / Trade-offs

- [Unexpected reference forms] → reject with a tagged error rather than silently emitting an invalid contract.
- [Recursive schemas cannot use native structured output] → return a clear error; supporting recursive provider schemas is out of scope.
- [Warning noise] → log only after a native attempt actually fails, including the diagnostic reason.

## Migration Plan

1. Add offline red tests for nested-contract inlining, recursion rejection, first-touch loading, and warning visibility.
2. Implement pure schema normalization, wire JSONAdapter and ReqLLM, then retain prompt/parser parity tests.
3. Run focused tests, full `mix test`, and `./precommit.sh`. Rollback is a source revert; no data migration exists.
