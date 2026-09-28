# crash-hardening Specification

## ADDED Requirements

### Requirement: A failing child never takes down the caller
At every spawn site (Module.parallel, `Dspy.Tools` execution ×2, Ensemble forward and compile ×2, SIMBA, MIPROv2, BootstrapFewShot ×2, Evaluate), the system SHALL catch a raise, throw or exit inside the child task body and return it as a per-item failure value using the site's existing error shape. The caller process SHALL stay alive, and it SHALL NOT use `trap_exit` or catch around the stream.

#### Scenario: Child raises
- **WHEN** a program, tool or candidate run at a listed site raises inside its task, with `max_concurrency` of at least 2
- **THEN** the public call SHALL return, the caller process SHALL be alive, and the site's failure value SHALL contain the raised reason

#### Scenario: Child throws or exits
- **WHEN** the child body at a tools site or in Module.parallel calls `throw/1` or `exit/1`
- **THEN** the call SHALL return the existing error shape (`"Tool execution failed: …"`, `{:error, msg}`, or `{:error, {:thrown | :exit, reason}}` for Module.parallel) and the caller SHALL be alive

### Requirement: Timed-out children are killed and reported
A child that exceeds its site's timeout SHALL be killed before the call returns (`on_timeout: :kill_task` or `Task.shutdown`), and its item SHALL become a timeout failure value. Module.parallel SHALL accept a `:timeout` option (default `:infinity`) and SHALL NOT use `Task.await_many`.

#### Scenario: Timeout kills the child
- **WHEN** a child sleeps past the timeout and would afterwards send a message to the test process
- **THEN** the call SHALL return a timeout failure value, the child pid SHALL be dead, and the message SHALL never arrive

### Requirement: Results stay aligned with inputs
Every site SHALL return results in input order and with input length. A failed item SHALL occupy its own position and SHALL NOT be dropped.

#### Scenario: Mixed success and failure keep positions
- **WHEN** item 2 of 3 fails
- **THEN** the results SHALL have length 3 and items 1 and 3 SHALL hold their own successful results

#### Scenario: Ensemble weights stay with their members
- **WHEN** member 2 of a 3-member weighted Ensemble fails during forward
- **THEN** the weighted vote SHALL use the weights of members 1 and 3 and SHALL produce the winner that the aligned weights determine

### Requirement: Teleprompter compile survives failing candidates
SIMBA, MIPROv2, BootstrapFewShot and Ensemble compile SHALL treat a failed candidate run as a failed score and SHALL still return a compiled program, as long as the error budget is not exceeded.

#### Scenario: One candidate crashes
- **WHEN** one candidate run raises during compile
- **THEN** compile SHALL return a program and the caller SHALL be alive

### Requirement: Evaluate counts failures with failure_score
`Dspy.Evaluate.evaluate/4` SHALL accept `:failure_score` (default `0.0`). A failed example SHALL be scored `failure_score` and SHALL be included in the mean. `items` and `scores` SHALL align 1:1 with the testset (upstream `evaluate.py:179-181`).

#### Scenario: One of four examples fails
- **WHEN** 3 examples score 1.0 and 1 raises, with default options
- **THEN** there SHALL be 4 items, the failed score SHALL equal `0.0`, and the mean SHALL equal `0.75`

#### Scenario: Scores stay aligned without return_all
- **WHEN** `return_all` is false and example 3 of 4 fails
- **THEN** `scores` SHALL equal `[1.0, 1.0, 0.0, 1.0]` and `failures` SHALL equal 1

### Requirement: Error budget stops the run
`Dspy.Settings` SHALL provide `max_errors` (default `10`, overridable via `Dspy.configure/1` and `Dspy.context/2`). `Dspy.Evaluate.evaluate/4` SHALL accept `:max_errors` (nil means the setting). When the failure count reaches the budget, Evaluate SHALL kill the pending tasks and raise `Dspy.Evaluate.MaxErrorsExceeded` with fields `:errors`, `:max_errors` and `:completed` (upstream `parallelizer.py:66, 102-104`).

#### Scenario: Budget reached (upstream `>=` boundary)
- **WHEN** Evaluate runs with `max_errors: 2` and 2 examples fail
- **THEN** it SHALL raise `Dspy.Evaluate.MaxErrorsExceeded`, and no pending task SHALL produce a side effect after the raise

#### Scenario: Below budget
- **WHEN** Evaluate runs with `max_errors: 2` and 1 example fails
- **THEN** it SHALL return normally with `failures` equal to 1

#### Scenario: Default and override of max_errors
- **WHEN** no value is configured
- **THEN** `Dspy.Settings.get(:max_errors)` SHALL return `10`, and inside `Dspy.context([max_errors: 3], …)` it SHALL return `3`

### Requirement: Process context still reaches every child
The H0 `Dspy.Context.with_context/2` wrapping SHALL remain inside every task body. The existing `test/context/**` tests SHALL pass unchanged.

#### Scenario: Overrides reach a hardened child
- **WHEN** a caller inside `Dspy.context([lm: lm2], …)` runs a listed site
- **THEN** each child SHALL see `lm2`, the same as before hardening

### Requirement: Boolean metric results count as 1.0 and 0.0
`Dspy.Teleprompt.run_metric/3` SHALL map `true` to `1.0` and `false` to `0.0` (Python bool arithmetic, upstream `evaluate.py:182`). Boolean results SHALL NOT count as failures.

#### Scenario: Boolean metric mean
- **WHEN** a metric returns `true` for 3 examples and `false` for 1
- **THEN** the mean SHALL equal `0.75` and `failures` SHALL equal 0

#### Scenario: Many false results do not exhaust the budget
- **WHEN** a boolean metric returns `false` for 11 examples with default `max_errors`
- **THEN** Evaluate SHALL return normally with mean `0.0`

### Requirement: Budget errors propagate out of optimizers
When Evaluate raises `Dspy.Evaluate.MaxErrorsExceeded` inside an optimizer's candidate task (simba, ensemble weights, bootstrap selection), the optimizer SHALL NOT swallow it: `compile/3` SHALL surface it to its caller.

#### Scenario: Budget exceeded during compile
- **WHEN** every candidate evaluation in a compile fails and the number of failures reaches `max_errors`
- **THEN** `compile/3` SHALL raise `Dspy.Evaluate.MaxErrorsExceeded` to its caller and SHALL NOT return a program
