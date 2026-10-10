# random-everywhere Specification

## ADDED Requirements

### Requirement: Library sampling never touches the caller's random state
Every library function that samples, shuffles or draws SHALL use `Dspy.Random`, threading its state, and SHALL NOT call `:rand` or `Enum.shuffle/random/take_random`. The caller's `:rand.export_seed()` SHALL be unchanged by any such call.

#### Scenario: Seeded caller
- **WHEN** the caller has run `:rand.seed(:exsss, {1, 2, 3})` and then calls `Dspy.Trainset.sample(trainset, 3, seed: 7)`
- **THEN** `:rand.export_seed()` SHALL equal its value before the call

#### Scenario: Never-seeded caller
- **WHEN** a fresh process that never used `:rand` calls `Dspy.Teleprompt.LabeledFewShot.compile/3`
- **THEN** `:rand.export_seed()` SHALL still be `:undefined`

### Requirement: Seeded selections are CPython-exact
For the same integer seed, `Trainset.sample(strategy: :random)` SHALL equal CPython `random.Random(seed).sample(trainset, n)`, and `Dspy.Random.random/1` and `choice/2` SHALL equal CPython `random()` and `choice()` bit for bit.

#### Scenario: Sample parity
- **WHEN** `Dspy.Trainset.sample(trainset, 3, strategy: :random, seed: 0)` runs over 10 examples
- **THEN** it SHALL return the examples at the indices CPython's `Random(0).sample(range(10), 3)` returns

### Requirement: Trainset stays usable without compile warnings
`Trainset.split/2` and `Trainset.sample/3` SHALL keep their signatures and SHALL NOT carry `@deprecated` in this change; their docs SHALL point to `Dspy.DataLoader`.

#### Scenario: Warnings gate
- **WHEN** `mix compile --warnings-as-errors --force` runs
- **THEN** it SHALL exit 0
