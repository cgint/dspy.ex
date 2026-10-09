# Image input: make first-class image fields discoverable and declared

## Why

### Summary

Two separate consumers of `dspy.ex` independently concluded the library "cannot send images to the model." Both reached this conclusion by following the documented path: the README, OVERVIEW, PROVIDERS, and COMPATIBILITY docs all point at `Dspy.Attachments` (which emits `input_file` parts — opaque file attachments appended to the request). The first-class `:image` field type and `Dspy.Image` value (which emit OpenAI-style `image_url`/base64 parts spliced inline at field position) exist and are proven by an e2e test, but they are invisible to any consumer following the documented path.

The root cause is twofold:
1. **API divergence from Python dspy**: Python registers `dspy.Image` as a real declared type discovered by annotation; Elixir accepts `%Dspy.Image{}` by runtime value-sniffing and its type normalizer does not recognise `:image` at all.
2. **Documentation gap**: every top-level doc points at Attachments/`input_file`; zero hits for `Dspy.Image` or the `:image` field type across `docs/*.md`, `AGENTS.md`, `CONTRIBUTING.md`.

### Original user request (verbatim)

> "The mostly documentation change and just some APIs you described to me sound good. I would like you to follow along with this and create a new OpenSpec change."

## What Changes

Three coordinated changes, in order of risk (lowest first):

### 1. Document the `:image` field and `Dspy.Image` (docs-only, zero risk)

- **README.md** — add a bullet under "What works today" for the `:image` field / `Dspy.Image` (sibling to the existing Attachments bullet).
- **docs/OVERVIEW.md** — add an "Image input (inline `image_url` splicing)" section after the existing Attachments section, with the e2e test (`test/dspy/image_input_pipeline_test.exs`) as proof.
- **docs/PROVIDERS.md** — add an `image_url` part example to the multimodal content-parts section, alongside the existing `text` and `input_file` examples.
- **docs/COMPATIBILITY.md** — add a `dspy.Image` / `:image` field row to the parity table.
- **README.md Examples** — link the three orphaned examples: `examples/playground/image_input_offline.exs`, `examples/playground/image_input_real_multimage.exs`, `examples/playground/image_input_real_per_page.exs`.
- **`Dspy.Attachments` moduledoc** — add one line directing image-input users to the `:image` signature field / `%Dspy.Image{}`.

### 2. Register `:image` as a declared field type in `Dspy.Signature` (small API change, low risk)

- `Dspy.Signature` SHALL recognise `:image` (and the string `"image"`) as a first-class field type, on par with `:string`, `:integer`, etc.
- A `%Dspy.Image{}` value (single or non-empty list) SHALL be accepted on a `:image`-typed field; any other value SHALL be rejected with an `:invalid_image` error.
- The existing runtime splice mechanism (sentinel token in the prompt, consumed before the wire) is unchanged — this change makes the *type* declared and *validatable*, not the splicing.
- **The `:string` escape-hatch is NOT touched.** It remains valid and the existing acceptance test (`test/acceptance/simplest_transcription_acceptance_test.exs`) continues to pass.

### 3. Disambiguate `Dspy.Attachments` scope (documentation only)

- Add the one-line moduledoc disambiguation (item 1 above).
- **No rename, no deprecation, no MIME-type warning in this change.** A rename (`Dspy.Attachments` → `Dspy.FileAttachment`) is a separate follow-up change with a deprecation cycle.

## Capabilities

| Capability | New / Modified |
|---|---|
| `:image` is a declared, validatable field type | New |
| Image input is documented in all top-level docs | New |
| `Dspy.Attachments` moduledoc disambiguates its scope | Modified |

## Impact

- **Breaking changes**: none. `:image` is a new case in the type normalizer (previously raised `ArgumentError` for `"image"`); `:image` is a new case in field-value validation (previously fell through to a default catch-all that accepted any value). Existing signatures continue to work identically.
- **Tests**: existing image tests must pass unchanged. New tests verify `:image` recognition and validation.
- **Consumer contract**: `test/consumer_contract/` is unaffected.
- **Python parity**: after this change, the Elixir `:image` field type is declared and validatable, matching Python's `dspy.Image` annotation-discovered type. The wire shape (`image_url` parts) is identical.
