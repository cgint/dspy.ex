# dataset-dataloader Specification

## ADDED Requirements

### Requirement: Reproducible seeded ordering independent of the runtime
Seeded shuffling and sampling SHALL use a generator that produces, for the same integer seed, the same order on every Elixir and OTP version, and SHALL equal CPython's `random.Random(seed).shuffle` and `.sample`. It SHALL NOT use `:rand`, the process dictionary or map iteration order.

#### Scenario: Golden permutation
- **WHEN** rows `0..9` are shuffled with seed `0`
- **THEN** the order SHALL be `[7, 8, 1, 5, 3, 4, 2, 0, 9, 6]`

#### Scenario: Golden sample, both branches
- **WHEN** `sample(0..9, 3, seed: 0)` and `sample(0..99, 3, seed: 0)` are taken
- **THEN** they SHALL be `[6, 9, 0]` and `[49, 97, 53]`

#### Scenario: Caller's random state untouched
- **WHEN** `train/1`, `sample/3` or `train_test_split/2` runs
- **THEN** the caller's `:rand` process state SHALL be the same before and after

### Requirement: Dataset splits
`Dspy.Dataset.train/1`, `dev/1` and `test/1` SHALL shuffle the split with its seed (dev and test both use `eval_seed`), keep the first `size` rows (`nil` = all, `0` = none, larger = all), and return `Example`s with `input_keys` applied. A negative size SHALL raise `ArgumentError`. Repeated calls SHALL return equal lists.

#### Scenario: Same split as upstream
- **WHEN** `train_seed: 0` and `train_size: 7` are used over rows `0..9`
- **THEN** `train/1` SHALL return the rows `[7, 8, 1, 5, 3, 4, 2]`

#### Scenario: Shared eval seed
- **WHEN** `eval_seed: 7` is used and the dev and test rows are identical
- **THEN** `dev/1` and `test/1` SHALL return the same order

#### Scenario: Stable across calls
- **WHEN** `train/1` is called twice on the same dataset
- **THEN** the two lists SHALL be equal

### Requirement: reset_seeds keeps what is not given
`Dspy.Dataset.reset_seeds/2` SHALL change only the keys present in its options, treat `0` as a value, keep the old value for an explicit `nil`, and set both dev and test seeds from `eval_seed`.

#### Scenario: Zero is a value
- **WHEN** every seed and size is reset to `0`
- **THEN** each SHALL be `0`

#### Scenario: Omitted and nil keep
- **WHEN** only `train_seed: 1` is given, or `train_size: nil` is given
- **THEN** every other value, and the size, SHALL keep its previous value

### Requirement: CSV loading
`Dspy.DataLoader.from_csv/2` SHALL read RFC 4180 CSV with a required header, return `Example`s with string keys and string values, strip a leading UTF-8 BOM, skip blank lines, accept CRLF and LF, keep quoted commas, quotes and newlines, read an empty cell as `nil`, fill the missing cells of a short row with `nil`, and keep surrounding whitespace. It SHALL raise `ArgumentError` for a row with more fields than the header, for a duplicate header name, and for an unknown name in `fields:`. It SHALL NOT create atoms from file data.

#### Scenario: Long row
- **WHEN** a row has more fields than the header
- **THEN** it SHALL raise `ArgumentError` naming the line

#### Scenario: Duplicate header
- **WHEN** two header cells have the same name
- **THEN** it SHALL raise `ArgumentError` naming the column

#### Scenario: Values stay strings
- **WHEN** cells hold `2`, `1.5` and `True`
- **THEN** the example values SHALL be the strings `"2"`, `"1.5"` and `"True"`

#### Scenario: No atoms created
- **WHEN** a CSV whose header is a name never used before is loaded
- **THEN** `String.to_existing_atom/1` on that name SHALL still raise

#### Scenario: Round trip with save_as_csv
- **WHEN** rows with non-empty string values are written by `save_as_csv` and read back with `from_csv`
- **THEN** the key/value pairs SHALL be the same

### Requirement: JSON loading
`Dspy.DataLoader.from_json/2` SHALL read either a JSON array of objects or JSON Lines, keep JSON types and nesting, use string keys, fill keys missing from some records with `nil`, and raise `ArgumentError` naming the record for a record that is not an object.

#### Scenario: Array and JSON Lines
- **WHEN** the same records are given as a JSON array and as JSON Lines
- **THEN** both SHALL load to the same examples

#### Scenario: Union of keys
- **WHEN** one record has `a` and another has `b`
- **THEN** each example SHALL have both keys, the missing one `nil`

#### Scenario: Round trip with save_as_json
- **WHEN** rows are written by `save_as_json` and read back with `from_json`
- **THEN** the rows SHALL be the same, with string keys

### Requirement: train_test_split
`Dspy.DataLoader.train_test_split/2` SHALL shuffle with the generator and seed, take `trunc(n * train_size)` rows for a float strictly between 0 and 1 or `train_size` rows for an integer, give the rest (or `test_size` rows) to test, and raise `ArgumentError` when the sizes are invalid or exceed the data.

#### Scenario: Upstream split
- **WHEN** rows `0..9` are split with `train_size: 0.7` and `seed: 0`
- **THEN** train SHALL be `[7, 8, 1, 5, 3, 4, 2]` and test `[0, 9, 6]`

#### Scenario: Truncation
- **WHEN** 10 rows are split with `train_size: 0.75`
- **THEN** train SHALL have 7 rows
