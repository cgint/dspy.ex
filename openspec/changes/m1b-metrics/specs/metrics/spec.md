# metrics Specification

## ADDED Requirements

### Requirement: Upstream text normalisation
`Dspy.Metrics.normalize_text/1` SHALL return, for every binary, the same string as DSPy 3.4.0 `dspy.evaluate.normalize_text`: Unicode NFD, lowercase, removal of ASCII punctuation only, whole-word removal of `a`, `an`, `the`, and whitespace collapse, in that order. It SHALL NOT strip accents or Unicode punctuation.

#### Scenario: Upstream docstring example
- **WHEN** `normalize_text("The,  Eiffel  Tower!")` is called
- **THEN** it SHALL return `"eiffel tower"`

#### Scenario: Golden vectors
- **WHEN** each input in the upstream-generated golden file is normalised
- **THEN** every output SHALL equal the recorded upstream output

#### Scenario: Articles only as whole words
- **WHEN** the input is `"the banana theater"`
- **THEN** `banana` and `theater` SHALL be kept

### Requirement: EM and F1 over answer lists
`Dspy.Metrics.em/2` SHALL return `true` when the prediction equals any answer after normalisation, else `false`. `Dspy.Metrics.f1/2` SHALL return the maximum token F1 over the answers as a float, using multiset token overlap, and `0.0` when there is no overlap or both sides are empty. Both SHALL raise `ArgumentError` when the answers are not a non-empty list.

#### Scenario: EM docstring cases
- **WHEN** `em("The Eiffel Tower", ["Eiffel Tower", "Louvre"])`, `em("paris", ["Paris"])` and `em("paris", ["Paris, France"])` are evaluated
- **THEN** they SHALL return `true`, `true` and `false`

#### Scenario: F1 docstring case
- **WHEN** `f1("Eiffel Tower is in Paris", ["Paris"])` is evaluated
- **THEN** the result rounded to 2 places SHALL be `0.33`

#### Scenario: Repeated tokens count as a multiset
- **WHEN** F1 is computed for inputs with repeated tokens from the golden file
- **THEN** each result SHALL equal the recorded upstream value

#### Scenario: No overlap is a float zero
- **WHEN** the prediction and answers share no token
- **THEN** `f1/2` SHALL return `0.0`, a float

#### Scenario: Empty answer list
- **WHEN** `em/2` or `f1/2` is given `[]`
- **THEN** it SHALL raise `ArgumentError`

### Requirement: answer_exact_match with frac
`Dspy.Metrics.answer_exact_match/3` SHALL read `:answer` from the example (a binary or a non-empty list of binaries) and from the prediction (a binary), and return a boolean: EM when `frac >= 1.0`, otherwise `f1 >= frac`. It SHALL be usable as an Evaluate metric at arity 2.

#### Scenario: Upstream tests
- **WHEN** the answer is `"2"` or `["2", "two"]` and the prediction is `"2"`, or the answer is `"2"` and the prediction is `"3"`
- **THEN** the results SHALL be `true`, `true` and `false`

#### Scenario: Any answer in the list matches
- **WHEN** the answer is `["2", "two"]` and the prediction is `"two"`
- **THEN** the result SHALL be `true`

#### Scenario: Threshold is inclusive
- **WHEN** the prediction is `"cat dog"`, the answer is `"cat bird"` and `frac: 0.5`
- **THEN** the result SHALL be `true`

#### Scenario: frac above 1.0 means exact match
- **WHEN** `frac: 1.5` is given for a pair that matches exactly after normalisation
- **THEN** the result SHALL be `true`

#### Scenario: Used through Evaluate
- **WHEN** `Dspy.Evaluate.evaluate/4` runs with `&Dspy.Metrics.answer_exact_match/2` on one matching and one non-matching example
- **THEN** `scores` SHALL be `[1.0, 0.0]`

#### Scenario: Invalid inputs raise
- **WHEN** the example or prediction lacks `:answer`, the answer is not a binary or a list of binaries, the prediction's answer is not a binary, or `frac` is not a number
- **THEN** it SHALL raise `ArgumentError` naming the field

### Requirement: answer_passage_match
`Dspy.Metrics.answer_passage_match/2` SHALL return `true` when any passage in the prediction's `:context` list contains any answer as a contiguous run of DPR tokens, after `normalize_text`, and `false` otherwise.

#### Scenario: Upstream docstring case
- **WHEN** the answer is `"Eiffel Tower"` and the context is `["The Eiffel Tower is in Paris.", "..."]`
- **THEN** the result SHALL be `true`

#### Scenario: Token match, not substring
- **WHEN** the answer is `"art"` and the only passage is `"party"`
- **THEN** the result SHALL be `false`

#### Scenario: Empty context
- **WHEN** the context is `[]`
- **THEN** the result SHALL be `false`

#### Scenario: Context must be a list
- **WHEN** the context is a binary
- **THEN** it SHALL raise `ArgumentError` naming `:context`

### Requirement: Existing metrics unchanged
Every function that existed in `Dspy.Metrics` before this change SHALL keep its behaviour, including the normalisation used by `exact_match` and `f1_score`, which are optimizer defaults.

#### Scenario: Legacy exact_match keeps articles
- **WHEN** `Dspy.Metrics.exact_match/2` compares an example answer `"The cat"` with a prediction answer `"cat"`
- **THEN** it SHALL return `0.0`
