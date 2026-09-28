# judged-metrics Specification

## ADDED Requirements

### Requirement: Upstream judge signatures
The signatures `SemanticRecallPrecision`, `DecompositionalSemanticRecallPrecision`, `AnswerCompleteness` and `AnswerGroundedness` SHALL have the same instructions, field names, field descriptions and field order as DSPy 3.4.0 `dspy.evaluate.auto_evaluation`.

#### Scenario: Golden signature text
- **WHEN** each signature is compared with the golden generated from upstream 3.4.0
- **THEN** instructions, field names, descriptions and order SHALL be equal

### Requirement: SemanticF1 metric
`Dspy.Evaluate.SemanticF1.metric/1` SHALL return a function of `(example, prediction)` that asks the judge LM for precision and recall of `prediction[:response]` against `example[:response]` for `example[:question]`, and returns their F1 as a float, each input clamped to `[0.0, 1.0]`, and `0.0` when both are zero.

#### Scenario: Score value
- **WHEN** the judge answers precision `0.8` and recall `0.6`
- **THEN** the metric SHALL return a float within `0.001` of `0.6857`

#### Scenario: Clamping
- **WHEN** the judge answers precision `1.5` and recall `-0.2`
- **THEN** the metric SHALL return `0.0`

#### Scenario: Both zero
- **WHEN** the judge answers precision `0` and recall `0`
- **THEN** the metric SHALL return `0.0`

#### Scenario: Decompositional
- **WHEN** the judge is built with `decompositional: true`
- **THEN** the judge LM SHALL be asked for the decompositional signature's output fields

### Requirement: CompleteAndGrounded metric
`Dspy.Evaluate.CompleteAndGrounded.metric/1` SHALL call the judge LM for completeness and then for groundedness, and return the F1 of the two as a float.

#### Scenario: Two distinct inputs
- **WHEN** the judge answers completeness `1.0` and then groundedness `0.5`
- **THEN** the metric SHALL return a float within `0.001` of `0.6667`

### Requirement: Threshold metric
`threshold_metric/1` SHALL return a function whose result is `true` when the F1 is at least the judge's threshold (default `0.66`) and `false` otherwise.

#### Scenario: Custom threshold
- **WHEN** the F1 is `0.6` and the threshold is `0.5`
- **THEN** the result SHALL be `true`

#### Scenario: Default threshold
- **WHEN** the F1 is `0.6` and no threshold is given
- **THEN** the result SHALL be `false`

### Requirement: Judge failures are failed examples
When the judge's answer cannot be parsed or lacks a required field, the metric SHALL raise, so that `Dspy.Evaluate.evaluate/4` scores that example `failure_score` and counts it toward `max_errors`. The metric SHALL NOT return `0.0`, `nil` or a non-number in that case.

#### Scenario: Unparseable judge answer through Evaluate
- **WHEN** the judge answers `N/A` for one example during `Dspy.Evaluate.evaluate/4`
- **THEN** that example SHALL score `failure_score` and `failures` SHALL be `1`

#### Scenario: Budget
- **WHEN** the same happens with `max_errors: 1`
- **THEN** `Dspy.Evaluate.evaluate/4` SHALL raise `Dspy.Evaluate.MaxErrorsExceeded`

### Requirement: Missing inputs raise
The metric SHALL raise `ArgumentError` naming the field when `:question` or `:response` is missing from the example, `:response` from the prediction, or (for groundedness) `:context` from the prediction. String-keyed examples SHALL be read through `Example` Access.

#### Scenario: Missing response
- **WHEN** the example has no `:response`
- **THEN** it SHALL raise `ArgumentError` naming `:response`

#### Scenario: String keys
- **WHEN** the example's keys are the strings `"question"` and `"response"`
- **THEN** the score SHALL equal the score for the atom-keyed example
