# string-key-access Specification

## ADDED Requirements

### Requirement: One canonical attrs accessor
Every library read of a user-supplied `attrs` field by a fixed or caller-given key SHALL go through `Dspy.Attrs`. An atom key SHALL find the atom key first, then its string form. A string key SHALL match only that exact string. When both forms exist, the atom key SHALL win.

#### Scenario: Atom wins when both forms exist
- **WHEN** an example holds both `:answer => "a"` and `"answer" => "s"`
- **THEN** `Dspy.Example.get(example, :answer)` SHALL return `"a"`

### Requirement: Metrics accept string-keyed examples
`Dspy.Metrics.answer_exact_match/2,3` and `answer_passage_match/2` SHALL read `answer` and `context` in either key form, and SHALL still raise when the field is missing in both forms.

#### Scenario: Loaded example scores
- **WHEN** example and prediction hold `"answer"` string keys with matching values
- **THEN** `answer_exact_match/2` SHALL return true

#### Scenario: Missing in both forms
- **WHEN** the example holds neither `:answer` nor `"answer"`
- **THEN** it SHALL raise `ArgumentError` with `example[:answer] is missing`

### Requirement: Demos render string-keyed values
The Default and JSON adapters SHALL render the values of a string-keyed demo. Prompts for atom-keyed demos SHALL be byte-identical to those of `3fcbea1`.

#### Scenario: String-keyed demo
- **WHEN** a `Predict` with the demo `%{"question" => "DEMO_Q", "answer" => "DEMO_A"}` is called
- **THEN** the request sent to the LM SHALL contain `DEMO_Q` and `DEMO_A`

### Requirement: majority accepts string-keyed maps
`Dspy.majority/2` SHALL vote over plain maps keyed by the string form of `:field`. It SHALL raise `ArgumentError` naming both keys when one map holds both forms.

#### Scenario: Mixed tally
- **WHEN** the completions are `[%{"answer" => "2"}, %{answer: "2"}, %{"answer" => "3"}]` with `field: :answer`
- **THEN** the winner's value SHALL be `"2"`

#### Scenario: Both forms in one map
- **WHEN** a completion holds both `:answer` and `"answer"`
- **THEN** it SHALL raise `ArgumentError` naming both keys
