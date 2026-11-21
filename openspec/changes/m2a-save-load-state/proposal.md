# Resume an optimized program in a fresh process

## Why

### Summary

Composite BootstrapRS can learn distinct demos for predictors in separate slots. Parameter JSON can carry hand-exposed parameters, but callers lack a program-level checkpoint that preserves those typed slots along with each predictor's generation config and LM binding. Users should be able to optimize once and resume with the same requests and predictions in a fresh BEAM.

### Scope decision

The owner selected **Native JSON v1 first (Recommended)**. The caller provides the program structure and any LM bindings. This milestone covers native state for that program. Python file exchange and whole-program serialization are separate work.

## What Changes

- `Dspy.Module.save_state/3` writes a versioned JSON checkpoint. `Dspy.Module.load_state/3` returns the caller's program with its saved predictor state restored. Both functions default their options to `[]`.
- Checkpoints carry ordered demos and their portable Example metadata, instructions, stored generation config, and references for explicitly bound LMs. A caller can supply a registry with `lms: %{"name" => lm}`.
- A checkpoint must match the target's full typed predictor slot set, predictor kinds, and ordered input and output names. A validation error rejects the whole checkpoint. A failed save preserves an existing checkpoint.
- An offline acceptance fixture compiles a composite with BootstrapRS and proves matching requests, predictions, and restored state across independent BEAM runs.

## Capabilities

### New Capabilities

- `program-state` covers saving and restoring native predictor state for an existing program.

### Modified Capabilities

None.

## Impact

`Dspy.Module` gains a pair of file-based APIs backed by existing typed predictor traversal and JSON dependencies. Callers own the program and field schema, adapters, retries, callbacks, and runtime LM settings. Parameter JSON and runtime demo support retain their existing contracts. Live traces, inference history, and executable program code sit outside this checkpoint.
