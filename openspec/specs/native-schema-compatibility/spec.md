# native-schema-compatibility Specification

## Purpose
TBD - created by archiving change native-schema-compat. Update Purpose after archive.
## Requirements
### Requirement: Native structured-output schemas are reference-free
When JSONAdapter builds an output contract for a typed output field used by native structured-output generation, the system MUST inline local nested schema definitions so the complete outer contract contains neither `$defs` nor `$ref`.

#### Scenario: Nested typed field is inlined
- **WHEN** a typed output schema contains a nested module schema
- **THEN** JSONAdapter’s complete output contract contains the nested field structure inline
- **AND THEN** the contract contains no `$defs` or `$ref`

### Requirement: Unsupported native schema references fail explicitly
When a native schema contains a recursive, unknown, or non-local reference, the system MUST return a tagged schema error rather than emit that reference in a native provider contract.

#### Scenario: Recursive reference is rejected
- **WHEN** a local definition refers to itself directly or indirectly
- **THEN** native schema normalization returns `{:error, {:recursive_schema_reference, ref}}`

### Requirement: Native fallback is observable
When native object generation fails and ReqLLM falls back to text generation, the system MUST emit a warning containing the native failure reason before requesting text generation.

#### Scenario: Provider rejects native generation
- **WHEN** native object generation returns `{:error, reason}`
- **THEN** the adapter logs a warning containing `reason`
- **AND THEN** it performs the existing text-generation fallback
