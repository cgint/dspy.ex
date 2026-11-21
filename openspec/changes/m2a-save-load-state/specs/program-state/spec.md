# Restore an optimized program in a fresh process

## Purpose

Let callers reuse the learned predictor state of a native DSPy program after the original process ends while retaining control over the program, its field schema, and its language models.

## ADDED Requirements

### Requirement: Native versioned checkpoint

`Dspy.Module.save_state(program, path, opts)` SHALL return `:ok` after publishing native JSON v1 at the supplied path. `Dspy.Module.load_state(program, path, opts)` SHALL return `{:ok, restored_program}` for a compatible checkpoint. Options default to `[]`. The format SHALL carry an explicit identifier and integer version. Filenames are caller-selected.

#### Scenario: Fresh runtime

- **WHEN** the caller saves the result of real composite BootstrapRS and builds a compatible program in an independent BEAM with matching runtime settings and caller-supplied LMs
- **THEN** the loaded program SHALL reproduce the original inference requests and prediction for the same input

#### Scenario: Foreign format or version

- **WHEN** a file contains a different checkpoint format or an unsupported version
- **THEN** load SHALL return a format or version error without hydration

### Requirement: Exact predictor slots

A checkpoint SHALL identify every predictor by a typed path. A root predictor uses an empty path. Paths SHALL distinguish struct fields, zero-based list or tuple positions, and map keys. Supported map key types are atoms, UTF-8 strings, and integers. Save SHALL reject unsupported key types on predictor paths.

#### Scenario: Exact map identity

- **WHEN** equal predictors occupy slots under keys `1`, `"1"`, and `:"1"`
- **THEN** save and load SHALL keep the three predictor states distinct

#### Scenario: Standalone ChainOfThought

- **WHEN** a standalone ChainOfThought checkpoint is loaded into a compatible ChainOfThought
- **THEN** load SHALL restore the predictor at the root and preserve the caller's reasoning configuration

### Requirement: Compatible caller program

The file and target SHALL have identical sets of predictor slots. At each slot the target SHALL match the predictor kind and the ordered input names and ordered output names. The target supplies the remaining field schema and program configuration.

#### Scenario: Different shape

- **WHEN** the checkpoint has duplicate, missing, or extra slots, a different predictor kind, or changed field names, order, or direction
- **THEN** load SHALL return an error for the incompatibility

### Requirement: Learned state round trip

The checkpoint SHALL preserve each predictor's instructions, ordered demos, and stored generation config. Supported demos are `Dspy.Example` values with portable attributes and metadata. The codec SHALL preserve the exact type of supported keys and values. Config SHALL preserve explicit `rollout_id: nil` independently of omission and preserve `n`.

#### Scenario: Typed example and metadata

- **WHEN** a saved example contains a declared atom field key, a string key with the same spelling, and metadata from `Example.with_inputs/2`
- **THEN** the two keys, their values, and the metadata SHALL survive hydration with the same runtime types

#### Scenario: Caller-owned runtime setup

- **WHEN** a compatible caller program supplies adapters, callbacks, retry options, field definitions, or non-predictor fields
- **THEN** hydration SHALL preserve those values while replacing the learned state

### Requirement: External LM bindings

Save SHALL represent a bound LM solely by its unique matching name in the caller's optional `lms:` registry. Load SHALL resolve each reference from the caller's registry. An unbound predictor SHALL carry a null reference and hydrate as unbound. Save SHALL exclude the bound LM's runtime struct and all its fields.

#### Scenario: Bound and unbound slots

- **WHEN** a file has a named binding and a null binding
- **THEN** load SHALL bind the first slot to the supplied LM and clear any pre-existing binding in the second slot

#### Scenario: Unresolvable LM reference

- **WHEN** a bound LM has zero or multiple matching names on save, or a file references a name missing on load
- **THEN** the operation SHALL return a distinct LM reference error without fallback

### Requirement: Safe all-or-error restoration

Load SHALL validate the complete envelope, predictor records, values, and LM references before returning a hydrated program. The loader SHALL rely on caller-provided slot and signature atoms and a fixed metadata vocabulary. File data SHALL never create atoms. Duplicate JSON members, typed keys, or slots SHALL be rejected before any corresponding map loses that information.

#### Scenario: Late malformed state

- **WHEN** a file has a valid first slot and an invalid later record
- **THEN** load SHALL return an error and no partially restored program

#### Scenario: Missing atom in the caller schema

- **WHEN** a checkpoint tags an unrecognized name as an atom example key
- **THEN** load SHALL reject it even if that atom already exists elsewhere in the VM

### Requirement: Atomic checkpoint replacement

Save SHALL publish a complete file by atomic replacement. It SHALL return errors for unsupported values or recoverable I/O failures and preserve an existing destination if save fails.

#### Scenario: Unsupported value after a valid checkpoint

- **WHEN** the caller saves over an existing checkpoint and a demo contains a function, process identifier, unsupported key, or struct
- **THEN** save SHALL return an unsupported-value error and preserve the earlier file byte for byte

#### Scenario: Failed publish

- **WHEN** save cannot rename its temporary file to the destination
- **THEN** save SHALL return a filesystem error and clean up its temporary file
