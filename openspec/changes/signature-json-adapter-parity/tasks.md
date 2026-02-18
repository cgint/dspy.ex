## Status

Planning tasks (not started).

---

## 1. Tests first (TDD)

- [ ] 1.1 Add deterministic unit tests for JSON “noise” inputs (fenced JSON, leading/trailing commentary).
- [ ] 1.2 Add tests that pin keyset semantics:
  - missing any signature output key → `{:error, {:missing_required_outputs, _}}` (or a new tag if desired)
  - extra keys are ignored
- [ ] 1.3 Add tests for schema-attached outputs:
  - successful casting returns typed structs
  - schema failures return `{:error, {:output_validation_failed, %{field: _, errors: _}}}`
- [ ] 1.4 Add tests pinning decode error tags: `{:error, {:output_decode_failed, _}}`.

## 2. Implementation

- [ ] 2.1 Implement deterministic preprocessing steps before JSON decode:
  - strip ```json fences
  - bounded `{...}` extraction
  - (optional) conservative trailing-comma cleanup if deterministic
- [ ] 2.2 Enforce “all output keys must be present” in JSONAdapter mode.
- [ ] 2.3 Keep typed casting behavior; ensure error tags match tests.

## 3. Verification

- [ ] 3.1 Run focused adapter tests.
- [ ] 3.2 Run `mix test`.
- [ ] 3.3 Run `./precommit.sh`.
