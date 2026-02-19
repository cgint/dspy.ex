# Complete adapter-owned request pipeline for signature modules (finish archived parity work)

## Why

### Summary
The original `adapter-pipeline-parity` change was archived before all implementation/verification tasks were completed. We need a focused follow-up to finish the adapter-owned request pipeline so `Predict`/`ChainOfThought` consistently use adapter-produced request maps and we have deterministic coverage for parity-critical behavior.

### Original user request (verbatim)
pls create those 4 follow-up changes

## What Changes

- Complete remaining implementation for adapter-owned request formatting in signature modules.
- Ensure `Predict`, `ChainOfThought`, and relevant internal signature paths share one deterministic format→call→parse path.
- Finish/extend tests for request-shape ownership, adapter precedence, attachment pass-through, and backward compatibility fallback.
- Close remaining verification gaps (`mix test`, `./precommit.sh`) with explicit acceptance criteria.

## Capabilities

### New Capabilities
- `signature-adapter-message-pipeline-completion`: complete and verify adapter-owned request formatting end-to-end for existing signature programs.

### Modified Capabilities
- `signature-adapter-message-pipeline`: finalize implementation and tighten acceptance criteria for request ownership and regressions.
- `adapter-selection`: strengthen guarantees that adapter precedence applies to request formatting as well as parsing.

## Impact

- Affected code paths likely include `lib/dspy/signature/adapter.ex`, `lib/dspy/predict.ex`, `lib/dspy/chain_of_thought.ex`, and built-in signature adapters.
- Affected tests include adapter selection/request-shape characterization and signature program regressions.
- No new provider dependency expected.
