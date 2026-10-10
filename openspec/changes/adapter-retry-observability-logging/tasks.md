# Tasks

- [x] TDD: add the four log sites in `lib/dspy/signature/adapter/pipeline.ex`
      (retry → `:debug`, exhausted → `:info`), threading `max_output_attempts`.
- [x] Remove the dead `generate_with_retries/2`; the `call_with_retry_log/3`
      wrapper now owns the transport-retry loop + log line.
- [x] Fix the unused `reason` binding (transport-exhaustion fallthrough uses
      `reason`; the retry loop's terminal clause binds `_reason`).
- [x] Verification: `mix compile --warnings-as-errors` clean.
- [x] Add `format_reason/1`: exceptions -> `Exception.message/1` (so a
      `%ReqLLM.Error.API.Request{}` never leaks its `request_body`/`response_body`/
      `headers`), non-exceptions -> `inspect/1` truncated to
      `@reason_log_max_chars`.
- [x] Add `LeakyLM` no-leak test in `adapter_pipeline_edge_cases` proving a real
      `%ReqLLM.Error.API.Request{}` with a secret body logs only the summary.
- [x] Verification: focused retry + consumer-contract tests pass
      (`adapter_pipeline_edge_cases`, `typed_output_retry`,
      `untyped_output_retry_default_adapter`, `max_output_retries_settings_default`,
      `test/consumer_contract`).
- [ ] [User Verification] Confirm retry lines are `:debug` and exhaustion
      lines are `:info` in a real LM-heavy run; confirm no contract/Settings
      surface changed.
