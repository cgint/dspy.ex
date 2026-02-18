# signature-xml-adapter Specification

## ADDED Requirements

### Requirement: Users can request XML-tagged outputs via a signature adapter
The system SHALL provide a signature adapter (`Dspy.Signature.Adapters.XMLAdapter`) that can be selected as the active adapter for a program run.

#### Scenario: Adapter is selected globally
- **WHEN** the user configures `adapter: Dspy.Signature.Adapters.XMLAdapter`
- **THEN** signature prompt generation SHALL include XML output-format instructions from the adapter

#### Scenario: Adapter is selected per program
- **WHEN** a program is constructed/configured with `adapter: Dspy.Signature.Adapters.XMLAdapter`
- **THEN** that program run SHALL use the XML adapter regardless of the global default

### Requirement: XML adapter formats output requirements as per-field XML tags
The XML adapter MUST instruct the model to return outputs wrapped in XML tags whose names match the signature output field names (e.g. `<answer>...</answer>`).

**Tag name constraint (deterministic):**
- The XML tag name is derived from the output field atom via `Atom.to_string/1`.
- XMLAdapter only supports tag names matching `^[A-Za-z_][A-Za-z0-9_]*$`.
- If an output field name is not tag-safe, XMLAdapter MUST fail fast with `{:error, {:invalid_xml_tag_name, field}}`.

#### Scenario: Signature has multiple output fields
- **WHEN** the signature has output fields `:reasoning` and `:answer`
- **THEN** the adapter instructions MUST mention both `<reasoning>` and `<answer>` tags as required output wrappers

### Requirement: XML adapter parses XML-tagged outputs into a signature-shaped output map
The XML adapter SHALL parse a model completion by extracting the first occurrence of each expected output tag and returning a map keyed by the signature output field atoms.

#### Scenario: Completion contains all required output tags
- **WHEN** the completion contains one XML tag for each required signature output field
- **THEN** the adapter SHALL return a map containing all required output fields populated from the tag contents

#### Scenario: Completion contains duplicate tags for the same field
- **WHEN** the completion contains multiple occurrences of the same output tag
- **THEN** the adapter SHALL use the first occurrence for that field

### Requirement: XML adapter enforces required outputs and field coercion/constraints
The XML adapter MUST return an error when required outputs are missing, and MUST coerce/validate extracted tag contents according to signature field types and constraints.

#### Scenario: Missing required output tag
- **WHEN** the completion omits one or more required output tags
- **THEN** the adapter MUST return `{:error, {:missing_required_outputs, missing_fields}}`

#### Scenario: Output value violates a one_of constraint
- **WHEN** a parsed output value is not in the allowed `one_of` set for that field
- **THEN** the adapter MUST return `{:error, {:invalid_output_value, field_name, {:one_of_violation, allowed, got}}}`

#### Scenario: Output value cannot be coerced to the declared type
- **WHEN** a parsed output value cannot be coerced to the declared output field type
- **THEN** the adapter MUST return `{:error, {:invalid_output_value, field_name, {:type_coercion_failed, type, raw}}}`

#### Scenario: Whitespace handling is deterministic
- **WHEN** an output tag contains leading/trailing whitespace/newlines
- **THEN** the adapter MUST `String.trim/1` the extracted content before coercion (except `:code`, which preserves content verbatim)

#### Scenario: schema outputs are not supported by XMLAdapter
- **WHEN** a signature output field declares `schema:`
- **THEN** XMLAdapter MUST return `{:error, {:xml_schema_outputs_not_supported, field_name}}`
