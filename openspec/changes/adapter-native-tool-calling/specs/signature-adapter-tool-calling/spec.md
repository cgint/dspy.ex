## ADDED Requirements

### Requirement: Signature adapters map `:tools` fields into provider-native request tools
The active signature adapter SHALL detect tool declaration input fields and emit provider-compatible `request.tools` payloads when the signature declares them.

#### Scenario: Convert signature tool declarations into request tools
- **WHEN** a signature input includes a field with type `:tool` or `:tools`
- **AND** the field value is one or more `Dspy.Tools.Tool` structs (or equivalent tool maps with `name`, `description`, `parameters`)
- **THEN** adapter formatting SHALL include a `tools` key in the generated request map
- **AND** each tool SHALL be normalized into a canonical internal tool object (OpenAI-like) with `"type": "function"` and a nested `function` map containing `name`, `description`, and JSON-schema-like `parameters`.
- **AND** provider-specific translation (if any) is handled below the adapter boundary; adapters emit the canonical internal schema.

#### Scenario: No tool field yields a plain request
- **WHEN** the active signature has no `:tool`/`:tools` input field
- **THEN** adapter formatting SHALL omit `request.tools` (or set it to `nil`) without changing response parsing behavior.

#### Scenario: Invalid tool definition fails fast
- **WHEN** a declared tool field exists but cannot be converted to a valid tool schema
- **THEN** the adapter SHALL return a tagged adapter error (e.g., `{:invalid_tool_spec, ...}`)
- **AND** the program SHALL not proceed to LM generation until the error is resolved.

### Requirement: Signature adapters parse ToolCalls output from structured completion metadata
The active adapter SHALL parse `tool_calls` from LM completion metadata into a signature output field typed as `:tool_calls`.

**Normalization requirement:** the adapter parse boundary MUST receive a provider-agnostic view of tool calls (a list of tool-call entries with at least `name` and `arguments`), even if the raw provider response nests tool calls differently.

#### Scenario: Parse tool call results into a ToolCalls output field
- **WHEN** the LM completion message includes one or more tool calls
- **AND** the signature has an output field of type `:tool_calls`
- **THEN** the parser SHALL return that field as a list of call objects
- **AND** each object SHALL include at least `name` and `args` (parsed from JSON arguments).

#### Scenario: ToolCalls parsing recovers from JSON argument formats
- **WHEN** tool call arguments are provided as stringified JSON
- **THEN** the parser SHALL decode `arguments` into structured data before returning `:tool_calls`
- **AND** malformed argument JSON SHALL produce a tagged parse error (not silently empty args).

#### Scenario: ToolCalls output is optional when not requested
- **WHEN** the completion includes `tool_calls` but the signature has no `:tool_calls` output field
- **THEN** parsing SHALL continue to use the normal text/JSON output contract for declared output fields
- **AND** tool_calls metadata SHALL not be injected into unrelated output fields.

### Requirement: ToolCalls-required output fields enforce presence
The parser SHALL treat missing tool call output as a required-field failure when declared as required.

#### Scenario: Required ToolCalls field is missing
- **WHEN** the signature has a required `:tool_calls` output field
- **AND** the completion has no extractable tool-call metadata
- **THEN** parsing SHALL return a missing-required-output error tagged to that field.
