# process-context Specification

## ADDED Requirements

### Requirement: Captured process context is installed in spawned work
The system SHALL provide `Dspy.Context` to capture, in the caller, settings overrides (including `track_usage` and `callbacks`) and the adapter callback stack, and to install that context in the current process for the duration of a function (restoring previous values afterwards, without spawning). Usage accumulators are intentionally not captured.

#### Scenario: Overrides reach a child
- **WHEN** a caller inside `Dspy.context([lm: lm2], fn -> ... end)` runs work through `Dspy.Context` in a new process
- **THEN** `Dspy.Settings.get(:lm)` inside that process SHALL return `lm2`, and the global LM SHALL be unchanged afterwards

#### Scenario: Callbacks reach a child
- **WHEN** a caller registers adapter callbacks and runs a `Dspy.Predict` through `Dspy.Context` in a new process
- **THEN** those callbacks SHALL receive the child's adapter events

#### Scenario: Child usage stays on the child prediction (upstream parity)
- **WHEN** `track_usage: true` and a program runs in a child through `Dspy.Context`
- **THEN** the child's returned prediction SHALL carry that child's usage, and the caller's accumulator SHALL NOT be changed by the child

#### Scenario: Untracked caller gets no usage state
- **WHEN** the caller has no open usage frame and runs work through `Dspy.Context`
- **THEN** no usage state SHALL be created in the caller's process and results SHALL be unchanged

#### Scenario: Crashed child leaves caller state intact
- **WHEN** a child run through `Dspy.Context` raises
- **THEN** the caller's overrides, callback stack and usage state SHALL be unchanged

#### Scenario: Child state does not leak back
- **WHEN** a child opens its own `Dspy.context/2` or registers callbacks
- **THEN** none of that SHALL be visible in the caller after the child returns

### Requirement: Every library spawn site carries the process context
All library sites that spawn processes to run programs, LM calls, or tools SHALL use `Dspy.Context`: `Dspy.Parallel`, `Dspy.Module.parallel`, `Dspy.Evaluate`, `Dspy.Tools` (both sites), `Teleprompt.Ensemble` (3), `SIMBA`, `BootstrapFewShot` (2), `MIPROv2`, `Dspy.Retrieve`.

#### Scenario: Per-site propagation test (programs)
- **WHEN** each listed program-running entry point is invoked inside `Dspy.context([lm: marker_lm], ...)` with a program whose output reveals the LM in use
- **THEN** the program running in the spawned process SHALL use `marker_lm`

#### Scenario: Per-site propagation test (tools)
- **WHEN** a `Dspy.Tools` tool function is executed inside `Dspy.context([lm: marker_lm], ...)`
- **THEN** `Dspy.Settings.get(:lm)` read inside the tool function SHALL return `marker_lm`

### Requirement: Backward compatibility
`Dspy.Settings.current_overrides/0` and `Dspy.Settings.with_overrides/2` SHALL keep their v0.3.40 behavior, and `test/consumer_contract/` SHALL pass unchanged.

#### Scenario: Existing API unchanged
- **WHEN** the existing `test/settings_context_test.exs` and consumer contract suite run
- **THEN** they SHALL pass without modification
