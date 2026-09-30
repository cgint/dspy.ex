# module-history Specification

## ADDED Requirements

### Requirement: Per-call history on results
Every successful result of `Dspy.Module.forward/2` SHALL carry, as `metadata[:lm_history]`, every LM call made during that call — including calls made by nested modules and by tasks spawned through the library's spawn sites — oldest first. `Dspy.Module.history/1` SHALL return them and `Dspy.Module.inspect_history/2` SHALL print the last `n`.

#### Scenario: Nested modules
- **WHEN** a program whose forward calls a ChainOfThought is called once
- **THEN** the program's result and the ChainOfThought's result SHALL each carry that one call

#### Scenario: Parallel calls are attributed
- **WHEN** a program is run twice through `Dspy.Parallel` inside `Dspy.with_history/1`
- **THEN** `with_history/1` SHALL return two entries

#### Scenario: Unrelated concurrent calls stay apart
- **WHEN** two programs are called at the same time in two unrelated processes
- **THEN** each result SHALL carry only its own call's entries

### Requirement: Block capture
`Dspy.with_history/1` SHALL run a function and return `{result, entries}` with every LM call made during it, in its process and in tasks spawned through the library's spawn sites, including calls whose module result is an error.

#### Scenario: Failed call captured
- **WHEN** a call that returns `{:error, _}` runs inside `with_history/1`
- **THEN** its LM call SHALL appear in the returned entries

### Requirement: Entry content
Each history entry SHALL include the request `messages` and the LM `outputs`, and the global `Dspy.inspect_history/1` SHALL print them.

#### Scenario: Output visible
- **WHEN** a scripted LM answers a known text and `Dspy.inspect_history/1` is called
- **THEN** the printed output SHALL contain that text

### Requirement: History settings
`disable_history: true` SHALL stop all history recording. `max_history_size` SHALL cap each frame, keeping the newest entries; `0` SHALL disable frames while global history continues.

#### Scenario: Cap keeps the newest
- **WHEN** 10 distinguishable calls run inside one `with_history/1` with `max_history_size: 5`
- **THEN** the entries SHALL be the last 5 calls

#### Scenario: Zero keeps global history
- **WHEN** `max_history_size: 0`
- **THEN** frames SHALL be empty and the global history SHALL still record the call

### Requirement: History never breaks a call and never leaks
A history frame SHALL be removed when its call ends by return, raise, throw or exit. Recording into a frame that no longer exists SHALL be ignored, and SHALL NOT make the LM call fail.

#### Scenario: Cleanup on every exit kind
- **WHEN** a module call returns, raises, throws or exits
- **THEN** its frame SHALL no longer exist afterwards

#### Scenario: Late recorder
- **WHEN** a process carrying a captured context calls the LM after the frame's call has ended
- **THEN** the LM call SHALL still succeed
