## MODIFIED Requirements

### Requirement: JSONAdapter enforces output keyset matching
When parsing in JSONAdapter mode, the resulting JSON object SHALL contain all declared signature output keys. Extra keys are ignored.

**Key normalization (deterministic):**
- Decoded JSON object keys are strings.
- Signature output fields are atoms.
- A JSON key matches an output field if it is exactly equal to `Atom.to_string(field_atom)` (no case folding).
- Keyset checks (missing/extra) are computed after applying this normalization.

**Required outputs:**
- All declared signature outputs are treated as required by JSONAdapter.

#### Scenario: Exact required keys are present
- **WHEN** the repaired JSON object contains all declared signature output keys
- **THEN** parsing SHALL proceed to field validation
- **AND** required output fields SHALL be accepted when present and correctly validated

#### Scenario: Missing output keys fail with a typed error
- **WHEN** one or more declared signature output keys are missing from the repaired JSON object
- **THEN** parsing SHALL return `{:error, {:missing_required_outputs, missing_keys}}`
- **AND** `missing_keys` SHALL list missing output field atoms

#### Scenario: Extra output keys are ignored
- **WHEN** the repaired JSON object contains keys not declared by the signature
- **THEN** parsing SHALL ignore them (filter to expected keys) and continue validation
