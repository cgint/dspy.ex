# JSON repair strategy (signature JSONAdapter)

## Summary
The signature `Dspy.Signature.Adapters.JSONAdapter` SHALL remain **JSON-object-only** and deterministic, but it SHOULD be resilient to common LM output defects via a bounded repair pass before decoding.

This document fixes the previously-open question in `design.md` by selecting a concrete, low-risk repair strategy **without adding new dependencies**.

## Deterministic two-pass parse

1. **First pass (strict):**
   - extract a JSON object substring from the completion text (code-fence/bracket extraction is acceptable)
   - decode with `Jason.decode/1`

2. **Second pass (repair → strict):** only if strict decode fails
   - apply a **limited** repair transform to the extracted JSON substring, then re-decode

If the second pass still fails, the adapter returns `{:error, {:output_decode_failed, reason}}`.

## Allowed repair transforms (bounded)

The repair pass MAY apply the following transforms, in order:

1. **Strip markdown fences / surrounding prose**
   - if one or more fenced blocks exist:
     - prefer the **first** ` ```json ... ``` ` fenced block
     - otherwise use the **first** fenced block with no language tag (``` ... ```)
   - otherwise fall back to extracting the first JSON object span by taking the substring from the first `{` to the last `}`
   - if no `{` is present at all, return `{:error, {:output_decode_failed, :no_json_object_found}}`

2. **Remove trailing commas**
   - e.g. `{ "a": 1, }` → `{ "a": 1 }`

3. **Normalize single-quoted strings**
   - e.g. `{ 'a': 'b' }` → `{ "a": "b" }`
   - this MUST remain a simple string-literal substitution; it MUST NOT attempt to infer or invent missing quotes around unquoted keys/values
   - **Limitation:** this transform may fail on tricky quoting cases (apostrophes, escapes, mixed quotes). In those cases, decode SHOULD fail deterministically with `{:output_decode_failed, reason}` rather than guessing.

## Explicitly disallowed repairs

To keep failure modes predictable, the repair pass SHALL NOT:
- insert quotes around bare identifiers ("invent" structure)
- accept a top-level JSON array (JSONAdapter remains object-only)
- silently drop undeclared output keys (extra keys are a keyset error)

## Notes

This strategy is intentionally similar to the existing generic `Dspy.Adapters.JSONAdapter` (format utility) `fix_and_retry/1`, but scoped to signature-adapter semantics and error tagging.
