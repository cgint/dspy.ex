# adapter-callbacks — signature adapter lifecycle callbacks (format/call/parse)

## Summary

Add an adapter lifecycle callback system (format → LM call → parse) for observability and parity with upstream Python DSPy `with_callbacks`.

## Dependencies / Order

- Implement after `adapter-pipeline-parity` so callbacks have a single centralized pipeline boundary.

## Backward compatibility

Callbacks are optional and no-op by default; existing users are unaffected.
