# Tasks

- [x] TDD: add the four log sites in `lib/dspy/signature/adapter/pipeline.ex`
      (retry → `:debug`, exhausted → `:info`), threading `max_output_attempts`.
- [x] Remove the dead `generate_with_retries/2`; the `call_with_retry_log/3`
      wrapper now owns the transport-retry loop + log line.
- [x] Fix the unused `reason` binding (transport-exhaustion fallthrough uses
      `reason`; the retry loop's terminal clause binds `_reason`).
- [x] Verification: `mix compile --warnings-as-errors` clean.
- [x] Verification: focused retry tests pass
      (`test/adapter_pipeline_edge_cases_test.exs`,
      `test/typed_output_retry_test.exs`,
      `test/untyped_output_retry_default_adapter_test.exs`,
      `test/max_output_retries_settings_default_test.exs`).
- [ ] [User Verification] Confirm retry lines are `:debug` and exhaustion
      lines are `:info` in a real LM-heavy run; confirm no contract/Settings
      surface changed.
