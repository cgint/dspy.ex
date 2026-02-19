# Complete JSONAdapter parity hardening for reliability (finish archived parity work)

## Why

### Summary
The archived `signature-json-adapter-parity` change established direction, but completion work remains to make JSONAdapter robust and fully test-pinned for real model output noise. This follow-up closes those gaps so JSONAdapter is deterministic and production-ready.

### Original user request (verbatim)
pls create those 4 follow-up changes

## What Changes

- Complete JSONAdapter hardening for noisy/malformed JSON outputs with deterministic preprocessing/repair.
- Finalize and pin keyset semantics and error tags in tests.
- Finish typed casting/validation behavior checks and retry-related compatibility assertions.
- Complete verification and docs-level behavior notes where needed.

## Capabilities

### New Capabilities
- `signature-jsonadapter-parity-completion`: complete and verify robust JSONAdapter parsing semantics for parity-critical cases.

### Modified Capabilities
- `signature-jsonadapter-parity`: finalize implementation details and deterministic error contracts.

## Impact

- Primary code impact in `lib/dspy/signature/adapters/json.ex` and adjacent parser helpers.
- Tests impacted across JSON adapter unit/acceptance and typed-output retry intersections.
- No API surface break intended.
