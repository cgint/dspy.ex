# WORK REPORT

## Handoff ID

`raw-output-on-parse-failure-20260811`

## What I did (high level)

Created the OpenSpec change proposal `attach-raw-output-to-parse-failures` through the repository's OpenSpec CLI. Created `proposal.md`, `design.md`, two specification deltas, and TDD-shaped `tasks.md`; then ran strict validation.

## Findings / results

`openspec validate attach-raw-output-to-parse-failures --strict` passes. The change is planning-complete (4/4 artifacts).

1. **Error shape & compatibility — decision:** Use the pipeline-only wrapper `{:output_parse_failed, reason, %{raw_output: response_text}}`. It preserves the original reason in a stable structured wrapper while leaving direct adapter `parse_outputs/3` contracts unchanged. This is intentionally breaking for pipeline callers that match bare errors. Migrate: `test/untyped_output_retry_default_adapter_test.exs:123,136`, `test/r3_1_core_contract_hardening_test.exs:148`, `test/acceptance/classifier_credentials_json_acceptance_test.exs:67`, `test/acceptance/classifier_credentials_acceptance_test.exs:90`, and `test/react_module_characterization_test.exs:210`. Preserve direct-contract matchers: `test/signature_adapters/chat_adapter_parse_test.exs:80,107`, `test/openspec_change_id_signature_regression_test.exs:31`, and `test/signature/json_adapter_parity_test.exs:72`.
2. **Coverage — decision:** Attach context to all terminal pipeline output parse/validation failures: adapter errors, normalized unexpected adapter results, and tool-output merge validation failures. With output retries, return only the final failed attempt's raw output; successful retry behavior remains unchanged.
3. **Size policy — decision:** Return complete, uncapped raw text. The caller owns redaction, display truncation, and persistence policy. This preserves diagnostics and avoids an arbitrary library policy; it also means errors can be large or sensitive.
4. **Where implemented — decision:** Implement at the adapter pipeline choke point. At `pipeline.ex:149-156`, raw response text and adapter parse result coexist; the same module owns retry classification and terminal return (`:184-305`). This covers adapters without changing individual adapter APIs.

## Evidence

- Read: `AGENTS.md`, `openspec/config.yaml`, OpenSpec propose skill, CMUX skill.
- Verified adapter raw-text contract: `lib/dspy/signature/adapter.ex:32-33`.
- Verified choke point and parse lifecycle: `lib/dspy/signature/adapter/pipeline.ex:149-203`.
- Verified retry ownership/classification: `lib/dspy/signature/adapter/pipeline.ex:214-305`.
- Verified caller passthrough: `lib/dspy/predict.ex:78-95`.
- Verified legacy reason sites/matchers with `rg` across `lib/` and `test/`.
- Commands and outcomes:
  - `openspec new change attach-raw-output-to-parse-failures` — created the repo-local change.
  - `openspec status --change ... --json` and `openspec instructions <artifact> ... --json` — followed artifact dependency order.
  - `openspec validate attach-raw-output-to-parse-failures --strict` — `Change 'attach-raw-output-to-parse-failures' is valid`.
  - `openspec status --change ...` — 4/4 artifacts complete.
  - `git diff --check -- openspec/changes/attach-raw-output-to-parse-failures` — passed (no output).
  - `wc -w .../proposal.md` — 360 words (under configured 1000-word limit).

## What worked / what didn't

- Worked: The current CLI uses `openspec new change <name>` and provided complete JSON instructions/templates for each artifact. Strict validation passed on the first validation run.
- Did not affect deliverable: An initial regex intended to list assertion files used an invalid escape sequence twice. I replaced it with fixed-string searches; the resulting inventory is recorded above. No artifact or validation result depended on the failed regex.

## Risks / uncertainties / assumptions

- The proposed wrapper is a breaking error-shape change for downstream pipeline callers; the proposal intentionally rejects an opts-gated compatibility path because it leaves the diagnostic gap as the default.
- Full raw completion text can contain sensitive or large data. The proposal assigns redaction and truncation before logging/persistence to callers.
- The proposal treats tool-output merge failures as output-validation failures because they occur after raw completion extraction in the same pipeline. Implementation characterization tests must verify this path.

## Next step suggestions

Review and approve the proposal, then run `/skill:openspec-apply-change` to implement tasks in order: failing characterization tests, terminal wrapper, caller matcher updates, focused/full verification, and downstream inspection.

## Files changed + diff summary (`git status --short` output)

Created by this handoff only:

- `openspec/changes/attach-raw-output-to-parse-failures/.openspec.yaml` (CLI scaffold)
- `openspec/changes/attach-raw-output-to-parse-failures/proposal.md` (33 added lines)
- `openspec/changes/attach-raw-output-to-parse-failures/design.md` (43 added lines)
- `openspec/changes/attach-raw-output-to-parse-failures/tasks.md` (23 added lines)
- `openspec/changes/attach-raw-output-to-parse-failures/specs/output-parse-failure-context/spec.md` (31 added lines)
- `openspec/changes/attach-raw-output-to-parse-failures/specs/output-repair-retries/spec.md` (25 added lines)
- `agent/cmux-report-raw-output-on-parse-failure-20260811.md` (this report)

Final `git status --short` (unrelated existing changes retained):

```text
 M .gitignore
 M lib/dspy/chain_of_thought.ex
 M lib/dspy/lm/bumblebee.ex
 M lib/dspy/lm/history.ex
 M lib/dspy/predict.ex
 M mix.lock
?? agent/cmux-handoff-raw-output-on-parse-failure-20260811.md
?? agent/cmux-report-raw-output-on-parse-failure-20260811.md
?? openspec/changes/attach-raw-output-to-parse-failures/
?? trivy.yaml
```

## Implementation update (2026-08-11)

### What changed

Implemented the approved pipeline-only terminal wrapper:

```elixir
{:output_parse_failed, reason, %{raw_output: response_text}}
```

`Dspy.Signature.Adapter.Pipeline` now carries `response_text` into its terminal retry boundary and wraps only after retry eligibility is evaluated. The original reason remains unwrapped for retry classification and repair-prompt formatting. The wrapper covers adapter errors, normalized unexpected adapter results, and tool-output merge errors. Direct `parse_outputs/3` contracts remain bare.

Updated caller-facing `:max_output_retries` docs in `lib/dspy/predict.ex:28` and `lib/dspy/chain_of_thought.ex:54`. Added the requested legacy-path non-goal (`lib/dspy/lm.ex:535`) and recorded the decision not to add `:attempts`.

### Tests and verification

- TDD proof: before implementation, the new missing-output and typed-validation wrapper assertions failed exactly because callers received bare reasons (3 failures; 4 existing retry tests passed).
- Focused suite: 52/52 passed, covering missing outputs, typed validation, final retry raw response, retry success, unexpected adapter return, tool-output merge error, migrated downstream callers, and preserved direct-adapter contracts.
- Full suite: 325/326 passed, 8 excluded. All five wrapper-related failures found on the first run were migrated; the sole remaining failure is `test/signature_typed_schema_integration_test.exs:66`, which expects generated schema JSON to exclude `jsv-cast` but receives `x-jsv-cast`. It does not exercise the pipeline or error wrapper and is outside the allowed implementation scope.
- Formatting: `mix format --check-formatted` passed for every changed implementation/test file.
- OpenSpec: `openspec validate attach-raw-output-to-parse-failures --strict` passed after implementation.
- Diff hygiene: `git diff --check` passed.
- Precommit: `./precommit.sh` failed during its warnings-as-errors compilation gate on existing warnings in dependencies and project files (e.g. `lib/dspy/typed_outputs.ex:58`, `lib/dspy/adapters.ex:152`, `lib/dspy/parameter.ex:376`), before its test phase. It also reports pre-existing unused lockfile dependencies. No warning was introduced by this change.

### Task status

Tasks 1.1–3.1 and 3.3 are checked complete. Task 3.2 remains unchecked because the full suite and precommit gates are not green. Per supervisor instruction, tasks 4.1–4.2 remain unchecked for user verification.

### Files changed by implementation

- `lib/dspy/signature/adapter/pipeline.ex`
- Documentation comments only: `lib/dspy/predict.ex`, `lib/dspy/chain_of_thought.ex`
- Tests: `test/untyped_output_retry_default_adapter_test.exs`, `test/typed_output_retry_test.exs`, `test/adapter_pipeline_edge_cases_test.exs`, `test/adapter_selection_test.exs`, `test/r3_1_core_contract_hardening_test.exs`, `test/react_module_characterization_test.exs`, `test/acceptance/classifier_credentials_acceptance_test.exs`, `test/acceptance/classifier_credentials_json_acceptance_test.exs`, `test/signature/adapter_native_tool_calling_test.exs`, `test/signature/two_step_adapter_test.exs`
- OpenSpec proposal/design/tasks and this report.

All pre-existing unrelated modifications (`.gitignore`, `lib/dspy/lm/bumblebee.ex`, `lib/dspy/lm/history.ex`, existing non-doc edits in `lib/dspy/predict.ex`/`lib/dspy/chain_of_thought.ex`, `mix.lock`, `trivy.yaml`, and handoff/review files) were left intact.
