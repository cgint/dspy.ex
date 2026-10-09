## Status

Planning tasks (not started).

---

## 1. Baseline verification

- [x] 1.1 Confirm existing tests pass before any change: `mix test test/dspy/image_input_pipeline_test.exs test/dspy/image_test.exs test/dspy/image_merge_media_test.exs test/acceptance/simplest_transcription_acceptance_test.exs`.
- [x] 1.2 Confirm `test/consumer_contract/` passes: `mix test test/consumer_contract/`.

## 2. API change: register `:image` as a declared field type (TDD)

- [x] 2.1 TDD: Add a failing test that an arrow-string signature `"img: image -> answer: string"` produces a field with `type: :image` (exercises the type normalizer via the public arrow-string path).
- [x] 2.2 TDD: Add a failing test that `Dspy.Signature.validate_inputs/2` accepts a `%Dspy.Image{}` value on a `:image`-typed field.
- [x] 2.3 TDD: Add a failing test that `validate_inputs/2` accepts a non-empty list of `%Dspy.Image{}` on a `:image`-typed field.
- [x] 2.4 TDD: Add a failing test that `validate_inputs/2` rejects a plain binary on a `:image`-typed field with an `:invalid_image` error.
- [x] 2.4b TDD: Add a failing test that `validate_inputs/2` rejects an empty list `[]` on a `:image`-typed field with an `:invalid_image` error.
- [x] 2.5 Implement: make `Dspy.Signature` recognise `:image` (and `"image"`) as a declared field type in the type normalizer.
- [x] 2.6 Implement: make `Dspy.Signature`'s field-value validation accept `%Dspy.Image{}` (single or non-empty list) on `:image`-typed fields; reject all other values (including empty list) with `:invalid_image`.
- [x] 2.7 Run the new tests; confirm they pass.
- [x] 2.8 Run the full image test suite (task 1.1) to confirm no regression.

## 3. Documentation changes

- [x] 3.1 `README.md`: add a bullet under "What works today" for the `:image` field / `Dspy.Image` (sibling to the existing Attachments bullet).
- [x] 3.2 `README.md`: add the three `examples/playground/image_input_*.exs` to the "Examples" section.
- [x] 3.3 `docs/OVERVIEW.md`: add an "Image input (inline `image_url` splicing)" section after the existing Attachments section, citing `test/dspy/image_input_pipeline_test.exs` as proof.
- [x] 3.4 `docs/PROVIDERS.md`: add an `image_url` part example to the multimodal content-parts section, alongside the existing `text` and `input_file` examples.
- [x] 3.5 `docs/COMPATIBILITY.md`: add a `dspy.Image` / `:image` field row to the parity table.
- [x] 3.6 `lib/dspy/attachments.ex`: add one line to the moduledoc: "For opaque file attachments (`input_file` parts). For prompt images spliced inline at field position, use a `:image` signature field with `%Dspy.Image{}`."

## 4. Verification

- [x] 4.1 Run `mix test test/dspy/image_input_pipeline_test.exs test/dspy/image_test.exs test/dspy/image_merge_media_test.exs test/acceptance/simplest_transcription_acceptance_test.exs` — all pass.
- [x] 4.2 Run `mix test test/consumer_contract/` — all pass (the `:string` escape-hatch with `Attachments` is unchanged).
- [x] 4.3 Run `mix test` (full suite) — no new failures.
- [x] 4.4 Run `mix compile --warnings-as-errors` — clean.
- [x] 4.5 Grep `README.md` and `docs/*.md` for `Dspy.Image` and `:image` — confirm at least one hit in each of README.md, docs/OVERVIEW.md, docs/PROVIDERS.md, docs/COMPATIBILITY.md.

## 5. Final verification by the user

- [ ] 5.1 Discoverability check: open `README.md` in a fresh browser tab (no IDE, no source browsing). Can you find how to send images to the model within 10 seconds of scanning? If not, the docs are still not discoverable enough.
- [ ] 5.2 Cross-reference check: does `docs/COMPATIBILITY.md` map `dspy.Image` → `Dspy.Image` / `:image` so a Python consumer can find the Elixir equivalent without reading the source?
- [ ] 5.3 Consumer-contract check: confirm `test/consumer_contract/` still passes (the `:string` escape-hatch with `Attachments` used by the transcription acceptance test is unchanged).
