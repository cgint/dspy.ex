# adapter-retry-observability-logging

## ADDED Requirements

### Requirement: The pipeline logs retry attempts at the debug level
When a signature-adapter call is retried, the pipeline SHALL emit a debug-level
log line identifying the retry, so operators can opt into per-attempt detail
without it appearing at the default log level.

#### Scenario: A transport retry is logged
- **WHEN** an LM call fails and is retried within `max_retries`
- **THEN** the pipeline SHALL log a `dspy.adapter_retry` line at the `:debug`
  level carrying `kind=transport`, the stable `call_id`, the attempt counter
  against the transport maximum, and the failure reason

#### Scenario: An output retry is logged
- **WHEN** an output parse/validate failure is retried within
  `max_output_retries`
- **THEN** the pipeline SHALL log a `dspy.adapter_retry` line at the `:debug`
  level carrying `kind=output`, the same `call_id`, the attempt counter against
  the output maximum, and the failure reason

### Requirement: The pipeline logs retries-exhausted at the info level
When a signature-adapter call has used all of its allowed attempts and is
going to return a terminal error, the pipeline SHALL emit an info-level log
line, because this is the operator-visible "this call is now failing" moment.

#### Scenario: Transport retries are exhausted
- **WHEN** all transport attempts have failed and the pipeline is about to
  return `{:error, reason}`
- **THEN** the pipeline SHALL log a `dspy.adapter_exhausted` line at the
  `:info` level carrying `kind=transport`, the `call_id`, the number of
  transport attempts used, and the last failure reason

#### Scenario: Output retries are exhausted
- **WHEN** all output attempts have failed and the pipeline is about to return
  the terminal `{:output_parse_failed, ...}` error
- **THEN** the pipeline SHALL log a `dspy.adapter_exhausted` line at the
  `:info` level carrying `kind=output`, the `call_id`, the number of output
  attempts used, and the last failure reason

### Requirement: Retry reasons are logged in a log-safe form
The pipeline SHALL NOT write a transport error's `request_body` or
`response_body` (the full prompt, output contract, or raw provider payload) or
any transport `headers` into a retry/exhaustion log line.

#### Scenario: A transport error logs its summary, not its body
- **WHEN** a transport retry or exhaustion logs a `%ReqLLM.Error.API.Request{}`
  reason that carries a `request_body`
- **THEN** the log line SHALL contain the exception's human-readable summary
  (e.g. `"API request failed: timeout"`) and SHALL NOT contain the
  `request_body` or `response_body` content

#### Scenario: A non-exception reason is bounded
- **WHEN** a retry or exhaustion reason is a non-exception value (e.g.
  `{:output_validation_failed, ...}`)
- **THEN** it SHALL be rendered via `inspect/1` and truncated to a bounded
  length so a deep error cannot bloat the log line

### Requirement: Retry logging does not change the observable contract
The retry/exhaustion logging SHALL be a log-only change: it SHALL NOT alter
`Pipeline.run/4`'s signature, any `{:ok, _}` / `{:error, _}` return shape, the
adapter callback event set, or any `Settings` key.

#### Scenario: Return shapes are unchanged
- **WHEN** a call succeeds after retries, or fails after exhausting retries
- **THEN** the returned value SHALL be identical to the pre-logging behavior
  (success tuple or the same error tuple), with logging as the only side
  effect
