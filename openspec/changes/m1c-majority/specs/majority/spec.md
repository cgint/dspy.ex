# majority Specification

## ADDED Requirements

### Requirement: Most common completion
`Dspy.majority/2` SHALL take a list of completions in caller order (maps with atom keys or `%Dspy.Prediction{}`), normalise the chosen field of each, and return as a `%Dspy.Prediction{}` the first original completion whose normalised value is the most common one.

#### Scenario: Clear majority
- **WHEN** the completions have answers `"2"`, `"2"`, `"3"`
- **THEN** the result's `:answer` SHALL be `"2"`

#### Scenario: Chosen field
- **WHEN** `field: :other` is given and the completions have `other` values `"1"`, `"1"`, `"2"`
- **THEN** the result's `:other` SHALL be `"1"`

#### Scenario: Original value is returned
- **WHEN** the answers are `"3"`, `" 2"`, `"2"` and `normalize: &Dspy.Metrics.normalize_text/1` is given
- **THEN** the result's `:answer` SHALL be `" 2"`

#### Scenario: Prediction completions are returned unchanged
- **WHEN** the completions are `%Dspy.Prediction{}` structs
- **THEN** the result SHALL equal the winning struct

### Requirement: Ties go to the earliest first appearance
When several normalised values share the highest count, the value that first appears earliest in the list SHALL win.

#### Scenario: No majority
- **WHEN** the answers are `"2"`, `"3"`, `"4"`
- **THEN** the result's `:answer` SHALL be `"2"`

#### Scenario: Tie not in sort order
- **WHEN** the answers are `"b"`, `"a"`
- **THEN** the result's `:answer` SHALL be `"b"`

### Requirement: nil means ignore, and only nil
A completion whose normalised value is `nil` SHALL be ignored. Every other value, including `false` and `""`, SHALL count as a vote. If every normalised value is `nil`, the first completion SHALL be returned.

#### Scenario: nil ignored
- **WHEN** `normalize` maps `"x"` to `nil` and the answers are `"x"`, `"x"`, `"y"`
- **THEN** the result's `:answer` SHALL be `"y"`

#### Scenario: false is a vote
- **WHEN** `normalize` maps `"x"` to `false` and `"y"` to `"y"`, and the answers are `"x"`, `"x"`, `"y"`
- **THEN** the result's `:answer` SHALL be `"x"`

#### Scenario: All ignored
- **WHEN** `normalize` returns `nil` for every completion and the answers are `"p"`, `"q"`
- **THEN** the result's `:answer` SHALL be `"p"`

### Requirement: Default normaliser
Without a `:normalize` option, values SHALL be normalised with `Dspy.Metrics.normalize_text/1`, and a value that normalises to `""` SHALL be ignored. `normalize: nil` SHALL mean no normalisation.

#### Scenario: Empty after normalisation is ignored
- **WHEN** the answers are `"!!"`, `"!!"`, `"3"` and no `:normalize` is given
- **THEN** the result's `:answer` SHALL be `"3"`

#### Scenario: Identity
- **WHEN** the same answers are used with `normalize: nil`
- **THEN** the result's `:answer` SHALL be `"!!"`

### Requirement: Field selection and invalid input
If `:field` is not given and every completion has exactly one and the same key, that key SHALL be used. Otherwise `:field` is required. `Dspy.majority/2` SHALL raise `ArgumentError` for an empty list, for a `%Dspy.Prediction{}` passed as the whole input, for a completion missing the field, and for a missing `:field` when the completions have several keys, naming the keys seen.

#### Scenario: Single key used by default
- **WHEN** every completion has only `:answer` and no `:field` is given
- **THEN** `:answer` SHALL be used

#### Scenario: Several keys without field
- **WHEN** the completions have `:answer` and `:other` and no `:field` is given
- **THEN** it SHALL raise `ArgumentError` stating that `:field` is required because the completions do not share one single key, and listing both keys

#### Scenario: Empty input
- **WHEN** the input is `[]`
- **THEN** it SHALL raise `ArgumentError`

#### Scenario: Prediction as the whole input
- **WHEN** the input is a single `%Dspy.Prediction{}`
- **THEN** it SHALL raise `ArgumentError`

#### Scenario: Missing field
- **WHEN** one completion lacks the chosen field
- **THEN** it SHALL raise `ArgumentError` naming the field
