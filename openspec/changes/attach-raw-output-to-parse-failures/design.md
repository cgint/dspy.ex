## Context

See `proposal.md` for motivation and `specs/output-parse-failure-context/spec.md` for the caller contract. `Dspy.Signature.Adapter.Pipeline` is the only call path where the response text and all adapter parse/merge outcomes coexist. It also owns output-repair retry classification and terminal error return. Adapter `parse_outputs/3` implementations are public and currently return bare reason tuples.

## Goals / Non-Goals

**Goals:**
- Add one consistent caller-facing context shape for terminal pipeline parse/validation failures.
- Preserve direct adapter contracts and existing retry semantics.
- Return the full final completion without duplicate response storage or library truncation.

**Non-Goals:**
- Capturing LM transport failures that have no response text.
- Retaining every failed retry completion.
- Redaction, logging, persistence, or changing callback payloads.
- Backward-compatible opt-in behavior for pipeline callers.
- The legacy non-pipeline structured-output path in `lib/dspy/lm.ex:535`, which calls `Dspy.Signature.parse_outputs/2` after `generate_text` and therefore will not carry raw output in this change.

## Decisions

### Wrap terminal pipeline failures, not adapter reasons
The pipeline will retain bare reasons while deciding retry eligibility and building retry prompts. Once no retry is possible, it will return `{:output_parse_failed, reason, %{raw_output: response_text}}`. The same terminal wrapping applies to adapter errors, unexpected adapter return values normalized as parse failures, and tool-output merge validation errors because each occurs after the response text is available.

This centralizes behavior across adapters, preserves `parse_outputs/3` compatibility, and ensures retry helpers can continue matching original reason tuples. The alternative of extending every reason tuple would break direct adapters and require every adapter to carry a value it already receives. An opts-gated detail channel would preserve old matches but gives consumers an inconsistent default and adds configuration/plumbing without resolving the diagnostic gap.

### Treat the pipeline error shape as a deliberate breaking change
Pipeline callers currently match bare parse reasons. The wrapper has a stable tag, preserves the original reason, and adds a detail map extensible for future metadata. In-repository pipeline/caller matchers to migrate are: two assertions each in `test/untyped_output_retry_default_adapter_test.exs`, `test/adapter_selection_test.exs`, and `test/signature/two_step_adapter_test.exs`; one each in `test/typed_output_retry_test.exs`, `test/r3_1_core_contract_hardening_test.exs`, `test/acceptance/classifier_credentials_json_acceptance_test.exs`, `test/acceptance/classifier_credentials_acceptance_test.exs`, `test/react_module_characterization_test.exs`, `test/adapter_pipeline_edge_cases_test.exs`, and `test/signature/adapter_native_tool_calling_test.exs`. Direct-adapter assertions in JSON, chat, and signature tests remain bare and must not change.

### Return only the full final failed completion
The terminal failure contains the response that callers need to diagnose the result they received after repair attempts. Retaining every response increases error size and obscures the terminal condition. The library will not truncate because a cap can hide the diagnostic content and forces a policy the caller is better placed to choose; callers must manage sensitive/large values before persistence or display.

The detail map will not add `:attempts` in this change. It is mechanically available, but raw output and the preserved reason solve the reported diagnosis problem; adding retry-count semantics expands the public contract without a stated consumer need.

## Risks / Trade-offs

- [Breaking pipeline error matches] → Document the wrapper, migrate repository caller tests, and preserve the original reason as the second element.
- [Large or sensitive completion retained in error values] → Return it only on terminal parse failure; document caller responsibility for redaction and truncation before logging.
- [Retry regression from matching wrapped errors] → Keep wrappers outside retry classification and test both retry success and exhausted retry behavior.
- [A failure path bypasses the choke point] → Characterize adapter errors, unexpected parse results, and tool-output merge errors through pipeline-backed calls.

## Migration Plan

1. Add failing pipeline/caller tests for no-retry and exhausted-retry failures, then implement the terminal wrapper at the pipeline boundary.
2. Update in-repository pipeline/caller matchers to destructure the wrapper and assert preserved reasons; leave direct adapter-contract tests unchanged.
3. Run targeted and full tests. Downstream callers must update bare pipeline-error matches to `{:output_parse_failed, reason, %{raw_output: raw_output}}`; they can continue matching `reason` for existing classification.
4. Roll back by reverting the pipeline wrapper if released behavior causes unacceptable compatibility impact; no stored data or migration is involved.
