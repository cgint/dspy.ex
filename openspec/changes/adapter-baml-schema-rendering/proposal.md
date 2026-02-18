# adapter-baml-schema-rendering — BAML-style typed schema hints (prompt shaping only)

## Summary

Add an opt-in adapter that renders typed output schemas into a compact, BAML-inspired snippet to improve adherence for nested structured outputs.

## Notes

- Prompt shaping only; parsing/validation/casting remain unchanged.
- This change should also make typed-output retry prompts schema-hint neutral (not hard-coded to “JSON Schema”).

## Dependencies / Order

Recommended after `adapter-pipeline-parity`.

## Backward compatibility

Opt-in adapter; default prompt/schema embedding unchanged.
