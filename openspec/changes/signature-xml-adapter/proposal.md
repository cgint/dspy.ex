# signature-xml-adapter — XML-tagged structured outputs (opt-in)

## Summary

Add a signature-level `XMLAdapter` that requests and parses `<field_name>...</field_name>` outputs, as an alternative structured-output mode to JSON.

## Dependencies / Order

Independent; can be implemented after the pipeline-parity foundational work, but does not require it.

## Backward compatibility

Opt-in adapter; Default and JSONAdapter unchanged.
