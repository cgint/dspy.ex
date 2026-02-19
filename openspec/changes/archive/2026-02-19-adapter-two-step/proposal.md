# adapter-two-step — TwoStep signature adapter (main completion + extraction LM)

## Summary

Add a TwoStep signature adapter that calls an extraction LM to produce structured outputs from a freeform main completion, mirroring upstream Python DSPy’s TwoStepAdapter.

## Dependencies / Order

- Requires `adapter-pipeline-parity`.
- Recommended after `adapter-callbacks` (observability) and after `signature-chat-adapter` (optional; for marker-based extraction).

## Backward compatibility

TwoStep is opt-in. Default and JSONAdapter behavior is unchanged.
