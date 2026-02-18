# Enable robust structured outputs via a two-step extraction adapter

## Why

### Summary
Some models (especially reasoning-focused models) produce high-quality freeform answers but are brittle at producing strict, signature-shaped structured outputs in a single pass. Upstream Python DSPy addresses this with `TwoStepAdapter`: first get a natural completion from the main LM, then run a smaller/cheaper “extraction” LM pass to convert that completion into structured outputs.

Adding a TwoStep adapter to `dspy.ex` improves reliability for structured outputs without forcing the main LM call to be schema/JSON-constrained, and provides a parity milestone toward upstream DSPy’s adapter suite.

### Original user request (verbatim)
Propose OpenSpec change: implement TwoStepAdapter (freeform main LM completion + structured extraction LM pass) mirroring Python TwoStepAdapter.

## What Changes

- Add a built-in TwoStep signature adapter that:
  - runs the main LM call as usual (but with freeform-oriented instructions so the model is not forced into JSON/label formatting)
  - triggers a second LM call during adapter parsing to extract/produce the signature outputs from the first completion
- Add configuration surface to specify the extraction LM (and optionally extraction adapter/settings) used for the second pass.
- Add deterministic tests proving:
  - the pipeline calls two LMs in the expected order
  - structured outputs come from the second pass
  - failures in the extraction pass are surfaced as tagged parse/validation errors

## Capabilities

### New Capabilities
- `two-step-signature-adapter`: Provide a two-stage adapter mode that uses an extraction LM to produce signature-shaped outputs from a freeform completion.

### Modified Capabilities
- `adapter-selection`: Extend the built-in adapter options to include TwoStep, and document how users configure the extraction LM for this adapter.

## Impact

- Code:
  - likely new adapter module under `lib/dspy/signature/adapters/*`
  - likely changes in `Dspy.Predict` and potentially `Dspy.ChainOfThought` to support the two-stage parsing path and pass needed context/options
  - likely changes in `Dspy.Settings` to store extraction-LM configuration
- APIs:
  - `Dspy.configure/1` gains new options for configuring the extraction LM for TwoStep adapter
  - no breaking changes intended for existing adapters (Default / JSON-only)
- Tests:
  - new characterization/acceptance tests for the two-step pipeline using mock LMs
- Upstream reference:
  - Python: `dspy/dspy/adapters/two_step_adapter.py`