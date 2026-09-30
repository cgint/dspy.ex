# program-state Specification

## ADDED Requirements

### Requirement: Named predictor paths
`Dspy.Module.named_predictors/1` SHALL list every predictor in a program with upstream DSPy 3.4.0 path names: `"self"` for a predictor on its own, `"<field>"` for a predictor field, `"<field>.<sub>"` for a nested module, `"<field>[<i>]"` for list items and `"<field>['<key>']"` for map entries, in sorted field order. A `Dspy.ChainOfThought` SHALL report its predictor at `"predict"`.

#### Scenario: All path shapes
- **WHEN** a program has a predictor field, a ChainOfThought field, a list of two predictors and a map of predictors
- **THEN** the paths SHALL be the upstream names for each shape

### Requirement: JSON state round trip
`Dspy.Module.save/2` SHALL write the program state as JSON and `Dspy.Module.load/3` SHALL return a new program whose `dump_state/1` equals the saved one. Each predictor state SHALL contain `traces`, `train`, `demos`, `signature` (instructions plus each field's `name`, `prefix` and `description`) and `lm`.

#### Scenario: Round trip
- **WHEN** a program with changed instructions, demos and field descriptions is saved and loaded
- **THEN** `dump_state/1` of the loaded program SHALL equal that of the original

#### Scenario: Same prompt after load
- **WHEN** the loaded program and the original are given the same inputs
- **THEN** the rendered LM request SHALL be identical, although loaded demos have string keys

### Requirement: Python interoperability
Files SHALL be readable by upstream DSPy 3.4.0 `load` and files written by it SHALL be readable by `load/3`. `metadata.dependency_versions` SHALL be written as an empty object; our versions SHALL be written under `metadata.dspy_ex`.

#### Scenario: Python reads our file
- **WHEN** upstream DSPy loads a file written by `save/2`
- **THEN** it SHALL not raise and SHALL restore the same instructions, demos and descriptions

#### Scenario: We read Python's file
- **WHEN** `load/3` reads a file written by upstream DSPy for each path shape
- **THEN** each predictor's state SHALL equal the file's

### Requirement: Refuse silent mislabelling
When the file carries field names that do not match the signature, or carries no names and a different field count, `load/3` SHALL return `{:error, {:signature_mismatch, path, details}}` instead of restoring by position.

#### Scenario: Reordered names
- **WHEN** a file's field names are in a different order than the signature's
- **THEN** `load/3` SHALL return a signature-mismatch error

#### Scenario: Count differs without names
- **WHEN** a Python-written file has one field fewer than the signature
- **THEN** `load/3` SHALL return a signature-mismatch error

### Requirement: Missing, extra and unknown state
A program path missing from the file SHALL return `{:error, {:missing_state, path}}`. An extra path in the file, or an unknown key in a predictor state, SHALL be ignored with a logged warning. A bad later path SHALL never produce `{:ok, program}` with earlier paths applied.

#### Scenario: Extra path
- **WHEN** the file has a path the program does not have
- **THEN** the load SHALL succeed and log a warning

#### Scenario: Half-loaded is not success
- **WHEN** the second of two paths in a file is invalid
- **THEN** `load/3` SHALL return `{:error, _}`

### Requirement: Unsafe LM keys
`api_base`, `base_url` and `model_list` in a saved `lm` SHALL be dropped with a warning unless `allow_unsafe_lm_state: true` is given.

#### Scenario: Dropped by default
- **WHEN** a file's `lm` contains `api_base`
- **THEN** the loaded LM state SHALL not contain it and a warning SHALL be logged

### Requirement: No atoms from file data
Loading SHALL NOT create atoms from paths, field names, demo keys or LM class names.

#### Scenario: Never-seen names
- **WHEN** a file with runtime-built never-seen names is loaded
- **THEN** `String.to_existing_atom/1` on each name SHALL still raise

### Requirement: Format errors are values
A `.pkl` or non-`.json` path, invalid JSON, or a JSON value that is not an object SHALL return `{:error, _}` naming the problem.

#### Scenario: Pickle path
- **WHEN** `load/3` is given a `.pkl` path
- **THEN** it SHALL return an error that names `.json`
