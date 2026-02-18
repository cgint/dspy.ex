## Status

Planning tasks (not started).

## Dependencies

- Requires `adapter-pipeline-parity`.

---

## 0. TDD foundations

- [ ] 0.1 Test: callback lifecycle events are emitted for a successful `Predict` run and are in the correct order.
- [ ] 0.2 Test: callback merge order is deterministic (global first, then instance/call).
- [ ] 0.3 Test: callback exceptions (e.g. in format_start) do not fail the parent call.
- [ ] 0.4 Test: `call_id` stays stable across all lifecycle phases.

## 1. Callback behaviour + config

- [ ] 1.1 Implement `Dspy.Signature.Adapter.Callback` behaviour.
- [ ] 1.2 Extend `Dspy.Settings` to accept `callbacks: [{module, state}]`.
- [ ] 1.3 Extend `Predict`/`ChainOfThought` constructors and/or forward options to accept callbacks.

## 2. Pipeline instrumentation

- [ ] 2.1 Introduce a centralized adapter pipeline runner (if not created in pipeline parity).
- [ ] 2.2 Emit format/call/parse start/end events around that runner.
- [ ] 2.3 Include usage summary (if any) in call-end.

## 3. Verification

- [ ] 3.1 Run focused callback tests.
- [ ] 3.2 Run `mix test`.
- [ ] 3.3 Run `./precommit.sh`.
