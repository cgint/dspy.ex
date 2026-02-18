# Enable signature-driven XML outputs for structured extraction

## Why

### Summary
`dspy.ex` currently supports signature-driven output parsing via the Default adapter (JSON-first, then label parsing) and a strict JSON-only signature adapter. Upstream Python DSPy also supports an XMLAdapter that uses XML tags per field for reliable extraction. Adding a signature-level XML adapter gives users a deterministic, non-JSON structured-output mode that can be preferable for some models and prompts (and aligns adapter parity workstream goals).

### Original user request (verbatim)
Propose OpenSpec change: add a signature-level XMLAdapter (format instructions + parse into signature output map), distinct from generic Dspy.Adapters.XMLAdapter utility.

## What Changes

- Add `Dspy.Signature.Adapters.XMLAdapter` implementing `Dspy.Signature.Adapter`.
  - `format_instructions/2` tells the model to return output fields wrapped in XML tags (e.g. `<answer>...</answer>`).
  - `parse_outputs/3` extracts the first occurrence of each expected output tag and returns a signature-shaped output map.
- Enforce adapter semantics at the signature layer (not via `Dspy.Adapters.XMLAdapter`).
- Provide deterministic tests proving:
  - successful parsing of XML outputs (including whitespace/newlines)
  - strictness around missing required output fields
  - no behavior changes for existing default/JSON adapters.

## Capabilities

### New Capabilities
- `signature-xml-adapter`: Allow programs to select a signature adapter that requests and parses XML-tagged outputs per signature output field.

### Modified Capabilities
- (none)

## Impact

- New module: `lib/dspy/signature/adapters/xml_adapter.ex`.
- Potential small additions in:
  - `lib/dspy/signature/adapter.ex` (docs/types only; no behavior change)
  - `docs/OVERVIEW.md` (optional: document adapter selection example for XML)
- New/updated tests under `test/` (adapter-level and/or acceptance-style) to lock in parsing/strictness contract.
- No new external dependencies required (use regex-based parsing similar to upstream Python DSPy).