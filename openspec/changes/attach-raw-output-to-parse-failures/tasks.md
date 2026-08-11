## 1. Characterize the contract with TDD

- [x] 1.1 Review the existing pipeline retry and direct-adapter tests, then add TDD tests that fail while asserting the terminal wrapper preserves `{:missing_required_outputs, missing}` and the exact raw response; gate: each new test fails against the pre-change behavior.
- [x] 1.2 Add TDD coverage for an invalid output value and an unexpected adapter parse result through a pipeline-backed call; gate: both failures require the original reason plus the exact raw response.
- [x] 1.3 Add TDD coverage for retry exhaustion using distinct failed completions; gate: it proves only the final attempt's complete text is returned and a later successful retry still returns normal outputs.
- [x] 1.4 Preserve direct adapter-contract tests for JSON, chat, and default adapters; gate: direct `parse_outputs/3` assertions still require their bare legacy reason tuples.

## 2. Add terminal failure context in the pipeline

- [x] 2.1 Add one pipeline-boundary helper that constructs `{:output_parse_failed, reason, %{raw_output: response_text}}` only when an output parse/validation failure becomes terminal; gate: the helper is reached from adapter errors, normalized unexpected parse results, and tool-output merge failures.
- [x] 2.2 Keep retry classification and retry-prompt formatting based on the unwrapped reason, then wrap only after retries are unavailable; gate: the existing retryable reason set and generated repair feedback remain equivalent for each legacy reason.
- [x] 2.3 Update the in-repository pipeline/caller error matchers identified in the design while leaving direct-adapter matchers unchanged; gate: every migrated assertion verifies both the preserved reason and `raw_output`.

## 3. Verification

- [x] 3.1 Run the focused pipeline, output-retry, acceptance, and direct-adapter test files; gate: all pass and the new failure-context tests demonstrate complete, untruncated raw text.
- [x] 3.2 Run the full project test suite and formatting/check suite used by the repository; gate: all checks pass with no unrelated source or test changes.
  - Evidence (2026-08-11): `./precommit.sh` passed after the `green-and-demo-20260811` follow-up handoff unblocked warnings-as-errors compilation; its full suite reported 326 passed, 8 excluded. The working tree retains unrelated pre-existing edits, intentionally uncommitted; the supervisor will use hunk-scoped staging so the eventual commit contains only related work.
- [x] 3.3 Update and review `lib/dspy/predict.ex:28` and `lib/dspy/chain_of_thought.ex:54` so their `:max_output_retries` docs distinguish inner retry reasons from the terminal wrapper; review any `@spec`/typedoc that enumerates pipeline error shapes; gate: these two sites and every discovered caller-facing type reference document the wrapper or are confirmed absent.

## 4. Final verification by the user

- [ ] 4.1 In a downstream consumer or a representative REPL call, induce a decoded JSON response missing `:result`; gate: the returned error exposes the complete model text at `{:output_parse_failed, {:missing_required_outputs, [:result]}, %{raw_output: raw_output}}` for inspection.
- [ ] 4.2 Review the downstream consumer's error matcher and logging policy; gate: it matches the wrapper, inspects the preserved reason as needed, and intentionally redacts or truncates `raw_output` before persistence.
