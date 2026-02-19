# signature-adapter-callbacks-completion Specification

## Purpose
TBD - created by archiving change adapter-callbacks-completion. Update Purpose after archive.
## Requirements
### Requirement: Callback completion SHALL guarantee deterministic metadata and merge order
Lifecycle callback events SHALL include stable metadata and deterministic callback invocation order.

#### Scenario: Stable merge order
- **WHEN** both global and per-program/per-call callbacks are configured
- **THEN** callbacks SHALL be invoked in deterministic order (global first, then local).

#### Scenario: Stable call correlation metadata
- **WHEN** events are emitted for one signature invocation
- **THEN** each event SHALL include the same `call_id`
- **AND** include `attempt` for retry-capable flows.

### Requirement: Callback completion SHALL provide bounded call-end summaries
`call_end` callback payloads SHALL provide bounded request/usage summaries suitable for observability without large prompt dumps.

#### Scenario: Usage available
- **WHEN** provider usage metadata is present
- **THEN** `call_end` SHALL include normalized usage summary fields.

#### Scenario: Usage unavailable
- **WHEN** provider usage metadata is absent
- **THEN** `call_end` SHALL include `usage: nil` (or equivalent) and SHALL NOT fail.

