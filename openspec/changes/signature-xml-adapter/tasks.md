## 1. Baseline + contract tests (TDD)

- [ ] 1.1 Review existing signature adapter behaviour/tests (adapter selection + signature parsing) and identify best test placement (unit vs acceptance)
- [ ] 1.2 Add TDD tests for XMLAdapter parsing success (all required tags present; whitespace/newlines tolerated)
- [ ] 1.3 Add TDD tests for XMLAdapter error on missing required outputs (`{:error, {:missing_required_outputs, ...}}`)
- [ ] 1.4 Add TDD tests for XMLAdapter duplicate tag handling (first occurrence wins)
- [ ] 1.5 Add TDD tests for XMLAdapter type coercion + `one_of` constraint enforcement
- [ ] 1.6 Add TDD tests proving adapter selection works (global config + per-program override) and that XMLAdapter `format_instructions/2` affects the prompt
- [ ] 1.7 Add TDD tests for deterministic coercion failure error shapes (`:type_coercion_failed`, `:one_of_violation`) and tag-name failure (`:invalid_xml_tag_name`)

## 2. Core implementation

- [ ] 2.1 Implement `Dspy.Signature.Adapters.XMLAdapter` module with `format_instructions/2`
- [ ] 2.2 Implement `parse_outputs/3` using regex extraction and required-field enforcement
- [ ] 2.3 Implement/co-locate primitive coercion + constraint validation used by XML parsing
- [ ] 2.4 Ensure adapter selection wiring works with no changes to default behaviour (global config + per-program override)

## 3. Documentation

- [ ] 3.1 Update `docs/OVERVIEW.md` (or the most appropriate doc) with an example of selecting the XML signature adapter
- [ ] 3.2 Add module docs clarifying difference between `Dspy.Signature.Adapters.XMLAdapter` and `Dspy.Adapters.XMLAdapter`

## 4. Verification

- [ ] 4.1 Run the focused test subset covering the new XML adapter behaviour and ensure all new tests pass
- [ ] 4.2 Run the full deterministic test suite to ensure no regressions in Default/JSON adapters

## 5. Final verification by the user

- [ ] 5.1 In an `iex -S mix` session, configure `adapter: Dspy.Signature.Adapters.XMLAdapter` with a mock LM that returns XML-tagged outputs and confirm the parsed prediction attributes match the signature outputs
