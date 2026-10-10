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
  kind-specific attempt counter, and `inspect(reason)` / `inspect(last_reason)`.
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
  `max_output_retries_settings_default`) pin the return shapes; no test asserts
  log output, so none need changing.
