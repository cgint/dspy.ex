# image-input-field-type Specification

## ADDED Requirements

### Requirement: `:image` is a declared and validatable signature field type
The system SHALL recognise `:image` (and the string `"image"`) as a first-class field type in `Dspy.Signature`, on par with `:string`, `:integer`, etc.

#### Scenario: Arrow-string signatures accept `"image"` as a field type
- **WHEN** a signature is declared via the arrow string `"img: image -> answer: string"`
- **THEN** the resulting field's type SHALL be `:image` (not raise an error)

#### Scenario: DSL signatures with `:image` atom store the type directly
- **WHEN** a signature declares `input_field(:x, :image, "...")` via the `use Dspy.Signature` DSL
- **THEN** the field's type SHALL be `:image`

#### Scenario: `%Dspy.Image{}` is accepted on a `:image` field
- **WHEN** an input value is a `%Dspy.Image{}` struct and the field type is `:image`
- **THEN** `Dspy.Signature.validate_inputs/2` SHALL return `:ok`

#### Scenario: A list of `%Dspy.Image{}` is accepted on a `:image` field
- **WHEN** an input value is a non-empty list where every element is a `%Dspy.Image{}` and the field type is `:image`
- **THEN** `Dspy.Signature.validate_inputs/2` SHALL return `:ok`

#### Scenario: Non-image values are rejected on a `:image` field
- **WHEN** an input value is a plain binary, number, atom, or any non-`%Dspy.Image{}` value and the field type is `:image`
- **THEN** `Dspy.Signature.validate_inputs/2` SHALL return an error containing `:invalid_image`

#### Scenario: An empty list is rejected on a `:image` field
- **WHEN** an input value is an empty list `[]` and the field type is `:image`
- **THEN** `Dspy.Signature.validate_inputs/2` SHALL return an error containing `:invalid_image`

### Requirement: The `:string` escape-hatch for images remains valid
The system SHALL continue to accept `%Dspy.Image{}` values on fields declared as `:string`. This change does NOT restrict, warn on, or deprecate that path.

#### Scenario: `%Dspy.Image{}` on a `:string` field still splices inline
- **WHEN** a signature declares `input_field(:img, :string, "...")` and the input value is a `%Dspy.Image{}`
- **THEN** the adapter pipeline SHALL splice the image as an `image_url` content part at the field position (unchanged behaviour)

### Requirement: Image input is discoverable in top-level documentation
The system SHALL document the `:image` field type and `Dspy.Image` value in all top-level entry-point documents so that a consumer searching for "how do I send images to the model" finds the first-class mechanism before or alongside the Attachments mechanism.

#### Scenario: README lists the `:image` field
- **WHEN** a reader scans the "What works today" section of `README.md`
- **THEN** there SHALL be a bullet for the `:image` field / `Dspy.Image` (in addition to the existing Attachments bullet)

#### Scenario: OVERVIEW has an image-input section
- **WHEN** a reader scans `docs/OVERVIEW.md`
- **THEN** there SHALL be a section describing the `:image` field and `Dspy.Image`, with the e2e test as proof, positioned adjacent to the existing Attachments section

#### Scenario: PROVIDERS.md shows an `image_url` part example
- **WHEN** a reader scans the multimodal content-parts section of `docs/PROVIDERS.md`
- **THEN** the example SHALL include an `image_url` part alongside the existing `text` and `input_file` examples

#### Scenario: COMPATIBILITY.md maps `dspy.Image` to `Dspy.Image`
- **WHEN** a reader scans the parity table in `docs/COMPATIBILITY.md`
- **THEN** there SHALL be a row mapping Python `dspy.Image` / `:image` field to Elixir `Dspy.Image` / `:image` field

#### Scenario: README Examples links the image examples
- **WHEN** a reader scans the "Examples" section of `README.md`
- **THEN** the three `examples/playground/image_input_*.exs` files SHALL be listed

### Requirement: `Dspy.Attachments` moduledoc disambiguates its scope
The `Dspy.Attachments` moduledoc SHALL state that it is for opaque file attachments (`input_file` parts) and point readers to the `:image` field for prompt images.

#### Scenario: Moduledoc names the correct mechanism for images
- **WHEN** a reader inspects `Dspy.Attachments` (e.g. via `iex>` or IDE hover)
- **THEN** the moduledoc SHALL include a sentence directing image-input users to the `:image` signature field / `%Dspy.Image{}`
