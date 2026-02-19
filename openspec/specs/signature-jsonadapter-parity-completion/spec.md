# signature-jsonadapter-parity-completion Specification

## Purpose
TBD - created by archiving change signature-json-adapter-parity-completion. Update Purpose after archive.
## Requirements
### Requirement: JSONAdapter SHALL recover from bounded malformed JSON wrappers
The JSONAdapter SHALL apply deterministic preprocessing before failing decode when completion text contains common wrapper noise around a JSON object.

#### Scenario: Markdown fenced JSON
- **WHEN** completion text contains a JSON object inside markdown fences
- **THEN** JSONAdapter SHALL extract the object and continue parsing.

#### Scenario: Leading/trailing commentary around object
- **WHEN** completion text includes commentary before/after a JSON object
- **THEN** JSONAdapter SHALL extract the bounded object and continue parsing.

### Requirement: JSONAdapter SHALL expose deterministic tagged errors after repair attempts
If parsing still fails after preprocessing/repair, JSONAdapter SHALL return tagged decode errors.

#### Scenario: No JSON object found
- **WHEN** completion text contains no JSON object
- **THEN** parser SHALL return `{:error, {:output_decode_failed, :no_json_object_found}}`.

#### Scenario: Unrepairable malformed JSON
- **WHEN** object extraction succeeds but JSON remains invalid
- **THEN** parser SHALL return `{:error, {:output_decode_failed, reason}}`.

