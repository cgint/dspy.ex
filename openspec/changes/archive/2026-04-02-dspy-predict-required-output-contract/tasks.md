## 1. Scope and tests-first setup

- [x] 1.1 Identify existing adapter pipeline tests that cover parse failures and retries (TDD)
- [x] 1.2 Add/extend a regression test that reproduces `{:missing_required_outputs, ...}` for an untyped output signature and asserts retry recovers (TDD)

## 2. Core implementation (output-repair retries)

- [x] 2.1 Update the adapter pipeline to allow output-repair retries for `:missing_required_outputs` and other retryable parse errors even when outputs are untyped
- [x] 2.2 Implement adapter-aware retry prompt formatting (JSON vs label adapters) so the retry instruction matches the adapter’s required output format
- [x] 2.3 Add configuration plumbing to set `max_output_retries` per call and/or via settings (with documented defaults)

## 3. Verification

- [x] 3.1 Verify unit tests pass and include coverage for: (a) retry success, (b) retry exhaustion, (c) retries disabled
- [x] 3.2 Manually verify (in a small example) that a “bad format then good format” completion sequence returns `{:ok, outputs}` within the retry bound

## 4. Final verification by the user

- [x] 4.1 In a downstream app that previously showed flaky `missing_required_outputs` (e.g. “Clarify”), confirm the first-attempt failure rate is materially reduced and a single click usually succeeds
- [x] 4.2 Confirm latency/cost impact is acceptable (retries only happen on failures, and the bound is as expected)
