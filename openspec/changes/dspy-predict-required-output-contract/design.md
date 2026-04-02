## Context

Downstream applications use `Dspy.Predict` to obtain structured outputs from LMs. Today, if the adapter/parser cannot extract all required output fields, it returns `{:error, {:missing_required_outputs, missing}}`. In practice, LMs sometimes return the “right information” but in a slightly different format (extra prose, missing wrapper keys, etc.), so a second try with a stricter formatting reminder typically succeeds.

The codebase already has the beginnings of an output-retry mechanism in `Dspy.Signature.Adapter.Pipeline`, but it is currently gated in a way that prevents it from helping common “required output key missing” failures for untyped output fields.

## Goals / Non-Goals

**Goals:**
- Provide a library-level, bounded mechanism to retry when parsing fails due to retryable output-format issues (including `{:missing_required_outputs, ...}`), so downstream apps do not need bespoke retry loops.
- Make retry prompting **adapter-aware**, so the retry instruction matches how the adapter expects outputs (e.g. JSON object vs label-formatted fields).
- Keep backwards compatibility for:
  - success cases (same returned output map)
  - failure semantics when retries are disabled or exhausted (same error reason)

**Non-Goals:**
- Guarantee that every model/provider will succeed within the retry bound.
- Add provider-specific heuristics that “guess” missing values.
- Introduce any infinite/implicit loop; retries must be bounded and observable.

## Decisions

1) **Enable output-repair retries for required-output failures even when outputs are not typed**
- **Decision:** Remove the restriction that output-repair retries only apply when typed output schemas are present; allow retries for retryable parsing errors as long as the adapter can provide an appropriate retry prompt.
- **Rationale:** The common failure mode we see (`{:missing_required_outputs, ...}`) occurs frequently for untyped outputs (e.g. a single `output_json: string` field) and should still benefit from a stricter second attempt.
- **Alternatives considered:**
  - Keep retry only for typed schemas (status quo): doesn’t solve the frequent real-world flake.
  - Force users to attach schemas to every output: good long-term, but not realistic for all downstream integrations.

2) **Adapter-aware retry prompt**
- **Decision:** Introduce a small abstraction so each adapter (or the pipeline) can build a retry prompt that matches the adapter’s expected output format.
- **Rationale:** The existing retry prompt text assumes a JSON-schema section is present and instructs “Return JSON only”. That’s correct for JSON adapters, but not for label-based adapters.
- **Alternatives considered:**
  - Always instruct JSON: can break integrations using label parsing.
  - Only enable retries for JSON adapters: simpler and acceptable as a first step if scoping requires it.

3) **Configuration and defaults**
- **Decision:** Keep retries explicitly configurable (e.g. `max_output_retries`) and document the latency/cost trade-off. Consider a conservative default (e.g. 1) for adapters that already generate JSON-schema prompts.
- **Rationale:** Retries improve reliability but add cost/latency. A conservative default reduces UX flakes while limiting extra calls.

## Risks / Trade-offs

- **[Extra tokens/latency]** retries add an extra LM call on failures → **Mitigation:** bounded retries, conservative default, clear documentation.
- **[Behavior surprises]** enabling retries for label-based parsing could change outputs → **Mitigation:** adapter-aware prompts; if needed, initially scope retries to JSON adapters only.
- **[Debuggability]** retries can hide the initial “bad” completion → **Mitigation:** surface attempt counts via callbacks/log metadata and preserve final error reason when exhausted.
