# Make adapter retries observable (log retry and exhaustion)

## Why

### Summary

The signature-adapter pipeline (`Dspy.Signature.Adapter.Pipeline`) has two
silent retry loops — transport retries (`max_retries`) and output
parse/validate retries (`max_output_retries`). When a long LM-heavy run makes
many calls, an operator cannot tell "one slow call" from "N retried calls",
and a call that eventually gives up leaves no operator-visible trace except
the terminal `{:error, ...}` returned to the caller.

### Original user request (verbatim)

> Implement retry observability: log retry attempts and retries-exhausted
> events from the two silent retry loops in `pipeline.ex`, so a long run can
> distinguish a slow call from retried calls. Retry lines at `:debug`,
> exhaustion lines at `:info`. No callback event, no Settings key, no change
> to `run/4` or any return-tuple shape.

## What Changes

- Add four `Logger` sites in `lib/dspy/signature/adapter/pipeline.ex`:
  - **retry** (transport + output): `Logger.debug`, per-attempt detail
    (bounded by `max_retries` / `max_output_retries`); quiet at the default
    `:info` level.
  - **exhausted** (transport + output): `Logger.info`, the terminal
    "gave up, here's why" line.
- Messages are stable and greppable: `dspy.adapter_retry` /
  `dspy.adapter_exhausted`, a `kind=` field (`transport`|`output`), `call_id`
  (the stable `make_ref` that spans both retry kinds for one call), a
  kind-specific attempt counter, and a **log-safe** reason.
- Reasons are rendered by `format_reason/1`: a `%ReqLLM.Error.API.Request{}`
  (or any exception) becomes its human-readable `Exception.message/1`
  summary (e.g. `"API request failed: timeout"`), so the struct's
  `request_body`/`response_body` (the full prompt + output contract) and
  `headers` **never** reach a log line. Non-exception tuples are rendered via
  `inspect/1` truncated to `@reason_log_max_chars` (300) so a deep validation
  error can't bloat the line.
- Thread `max_output_attempts` (computed once in `run/4`) through the
  internal call chain so both output log lines report a consistent total;
  fixes an off-by-one where output-exhaustion previously would have reported
  `output_retries_left + 1`.
- The transport retry loop is wrapped in `call_with_retry_log/3` so the pure
  `Dspy.LM.generate` retry helper keeps the log line (which needs `call_id`).

## Capabilities

- `adapter-retry-observability-logging`

## Impact

- **Code:** `lib/dspy/signature/adapter/pipeline.ex` only.
- **Non-goals / no contract change:** no new callback event, no `Settings`
  key, no change to `Pipeline.run/4` signature or any `{:ok, _}` /
  `{:error, _}` return shape, no telemetry. The error contract (including the
  deliberate exclusion of `:attempts` from the `attach-raw-output` detail map)
  is untouched — this is log-only.
- **Tests:** existing behavior tests (`adapter_pipeline_edge_cases`,
  `typed_output_retry`, `untyped_output_retry_default_adapter`,
  `max_output_retries_settings_default`) pin the return shapes; a new
  `LeakyLM` test in `adapter_pipeline_edge_cases` proves a real
  `%ReqLLM.Error.API.Request{}` with a secret `request_body` logs as
  `"API request failed: timeout"` and **never** the body text.
