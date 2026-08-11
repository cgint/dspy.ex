# Typed structured outputs delta

## MODIFIED Requirements

### Requirement: Typed structured output mapping pipeline
The system SHALL provide a deterministic pipeline that converts an LM completion text into a validated/cast Elixir value according to a provided schema, without raising exceptions. Typed output helpers MUST accept a JSON Schema map or a module exporting `json_schema/0` or `schema/0`; before checking module exports, the helper MUST ensure that the module is loaded.

#### Scenario: Completion contains valid JSON matching the schema
- **WHEN** the completion contains a JSON object that matches the provided schema (including nested objects and lists)
- **THEN** the pipeline SHALL return `{:ok, value}` where `value` is the validated/cast Elixir representation

#### Scenario: Completion JSON is missing a required field
- **WHEN** the completion contains a JSON object that fails schema validation because a required key is missing
- **THEN** the pipeline SHALL return `{:error, {:output_validation_failed, errors}}` and `errors` SHALL include enough detail to identify the missing field

#### Scenario: Completion JSON contains an enum-like mismatch
- **WHEN** the completion contains a JSON object that fails schema validation because a field value is not in the allowed set (enum/Literal-like constraint)
- **THEN** the pipeline SHALL return `{:error, {:output_validation_failed, errors}}` and `errors` SHALL include the field path and a human-readable message

#### Scenario: First-touch schema module
- **WHEN** `prompt_schema_json/1` receives a valid schema module that has not yet been loaded in the VM
- **THEN** it loads the module and returns its JSON schema
- **AND THEN** it does not return `{:error, {:invalid_schema, module}}`
