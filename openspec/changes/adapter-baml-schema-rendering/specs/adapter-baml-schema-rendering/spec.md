# Adapter capability: BAML-style schema rendering for typed outputs

## ADDED Requirements

### Requirement: Opt-in BAML-style schema rendering for typed output fields
When a program is configured to use the BAML-style schema rendering adapter and the signature contains one or more typed output fields (`schema:`), the system MUST render a compact, human-readable schema snippet in the prompt.

The rendered schema snippet MUST, at minimum:
- include each typed output field name
- describe the expected structure (object/array) and primitive types (string/integer/number/boolean)
- preserve nested structure using indentation

#### Scenario: Prompt includes BAML-style schema snippet for a nested typed output
- **WHEN** a signature contains an output field with a nested typed schema
- **AND WHEN** the program builds the prompt using the BAML-style schema rendering adapter
- **THEN** the prompt contains a simplified schema snippet that includes the output field name and nested field names
- **AND THEN** the snippet represents object structure with braces and indentation

### Requirement: BAML schema rendering does not duplicate JSON Schema embedding
When BAML-style schema rendering is active for typed outputs, the prompt MUST NOT also embed the existing raw JSON Schema section for those same typed output fields.

#### Scenario: Prompt does not contain both BAML snippet and raw JSON Schema section
- **WHEN** a signature contains at least one typed output field (`schema:`)
- **AND WHEN** the prompt is generated with the BAML-style schema rendering adapter
- **THEN** the prompt does not contain the raw JSON Schema embedding label used by the default typed-output prompt (e.g. "Return a JSON object that matches the following schema(s):" or "JSON Schema for ")

### Requirement: Unsupported schema constructs fall back to raw JSON Schema embedding
If the system encounters a typed schema that cannot be rendered into the supported BAML-style subset (e.g. unsupported JSON Schema constructs), the system MUST fall back to embedding the raw JSON Schema for that field rather than failing prompt generation.

#### Scenario: Fallback to raw JSON Schema when BAML rendering is unsupported
- **WHEN** a typed output field schema includes an unsupported construct for BAML rendering
- **AND WHEN** the prompt is generated with the BAML-style schema rendering adapter
- **THEN** prompt generation succeeds
- **AND THEN** the prompt embeds the raw JSON Schema for that typed output field

### Requirement: BAML-style schema rendering is prompt-shaping only
Selecting the BAML-style schema rendering adapter MUST NOT change output parsing, validation, or casting semantics for typed structured outputs.

#### Scenario: Typed output parsing and casting remains unchanged
- **WHEN** a program run returns a valid JSON object that conforms to the typed output schema
- **AND WHEN** the program uses the BAML-style schema rendering adapter
- **THEN** the system returns the same typed struct outputs as with the default typed-output behavior
