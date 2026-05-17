# COVERAGE_AUDIT_2026-05.md — meaningful coverage hardening audit

## Summary

Date: 2026-05-17

Command:

```bash
mix test --cover
```

Result after coverage hardening slices 1–3:

- Tests: 325 passing, 8 excluded (`:integration` / `:network`)
- Total line coverage: **66.23%**
- Mix cover threshold: **90%** (not met)
- Important interpretation: this repo should not chase 90% blindly yet. The better near-term target is **evidence-backed coverage of supported/adoption-critical behavior** and explicit demotion of placeholder/legacy surfaces.

Warning observed:

```text
Module Dspy.Retrieve.Embeddings.ReqLLM: Failed to collect coverage information. Has it been reloaded or unloaded?
```

This should be investigated separately before using coverage as a strict CI gate.

## 0% / near-0% module classification

| Module | Coverage | Classification | Rationale | Recommendation |
|---|---:|---|---|---|
| `Dspy.Adapters` | 0.00% | Legacy/utility namespace; supported indirectly | Generic JSON/XML/chat utility, distinct from the current signature adapter pipeline. Used by `Dspy.Tools` JSON parsing, but planning docs warn not to confuse it with Python DSPy signature adapters. | Add small utility tests for `Dspy.Adapters.parse/3`, `format/3`, `validate/3`, and `auto_parse/2` if we keep it public. Otherwise mark as legacy utility in docs. |
| `Dspy.Adapters.JSONAdapter` | 0.00% | Supported-test-needed if `Dspy.Adapters` remains public | Nested generic adapter has JSON extraction/lenient-fix behavior that is not the main `Dspy.Signature.Adapters.JSONAdapter`. | Add focused unit tests or demote public claims to avoid confusion. |
| `Dspy.Adapters.ChatAdapter` | 0.00% | Supported-test-needed if `Dspy.Adapters` remains public | Nested generic chat parser/formatter, not part of current Predict/CoT adapter path. | Add lightweight parser/formatter tests or document as legacy utility. |
| `Dspy.Adapters.XMLAdapter` | 0.00% | Optional / demote candidate | Placeholder-ish XML utility; upstream XMLAdapter is a signature adapter, not this generic helper. | Do not invest until XML output becomes a priority; consider moving to extras or explicitly marking experimental. |
| `Dspy.Retrieve.ChromaDB` | 0.00% | Placeholder / quarantine-demote candidate | Core explicitly says ChromaDB client is not shipped; methods return `{:error, ...}`. | Keep out of stable docs; optionally add one characterization test for error shape, or move to extras/quarantine later. |
| `Dspy.Retrieve.OpenAIEmbeddings` | 0.00% | Placeholder / optional-extras candidate | Core intentionally does not ship OpenAI embeddings implementation; returns unavailable errors. | Add characterization tests for explicit unavailable errors if kept; prefer custom provider / `Dspy.Retrieve.Embeddings.ReqLLM` for real surface. |
| `String.Chars.Dspy.Attachments` | 0.00% | Supported-test-needed / tiny protocol coverage | Formatting protocol is small but user-visible when attachments are inspected/interpolated. | Add one tiny test if useful; low priority. |
| `Dspy.Retrieve` | 16.67% | Mixed namespace; partially supported | Contains stable nested modules (`Document`, `VectorStore`, `DocumentProcessor`, `RAGPipeline`) plus placeholder backends. Low aggregate coverage is misleading. | Prefer tests against stable submodules; do not use aggregate `Dspy.Retrieve` coverage alone as quality signal. |
| `Dspy.Retrieve.ColBERTv2` | 30.00% | Placeholder characterization | Placeholder retriever now has deterministic error behavior; some tests exist. | Existing `test/retrieve/colbert_stub_test.exs` likely enough unless docs advertise more. |
| `Dspy.Teleprompt` | 32.35% | Facade/dispatcher; supported-test-needed only if needed | Most real optimizer behavior lives in concrete modules. Dispatcher coverage can be improved cheaply. | Add small dispatcher tests later if chasing facade confidence; not a blocker. |
| `Dspy.Application` | 43.75% | Low-risk startup surface | Library-first startup is tested, but not every branch. | Existing `test/application_core_startup_test.exs` likely enough; add only if startup behavior changes. |
| `Dspy.Teleprompt.Ensemble.Program` | 45.00% | Supported-test-needed / targeted | Ensemble program is a real returned program struct. | Add tests for unsupported voting/edge prediction behavior if needed; lower priority than adapter/retrieval cleanup. |

## Recommended follow-up order

1. **Do not enable 90% coverage as a hard gate yet.** It would incentivize testing placeholders/legacy code before product-critical behavior.
2. **Short cleanup win:** add `Dspy.Adapters` utility characterization tests if we keep the namespace public, because these modules account for several 0% rows and are used by tools.
3. **Retrieval cleanup decision:** keep `ChromaDB` / `OpenAIEmbeddings` as explicit placeholders with characterization tests, or move/demote them into extras/quarantine.
4. **Coverage configuration:** if we later enforce coverage, configure coverage expectations around supported modules rather than all compiled modules.
5. **Investigate coverage warning:** `Dspy.Retrieve.Embeddings.ReqLLM` coverage collection warning should be understood before relying on coverage reports in CI.

## Current conclusion

Meaningful coverage has improved in the current goal:

- Parameter/state safety: `test/parameter_state_safety_test.exs`
- R3.2 teleprompter parity: `test/r3_2_teleprompter_parity_test.exs`
- Adapter pipeline edge cases: `test/adapter_pipeline_edge_cases_test.exs`

The remaining low/zero coverage is concentrated in generic utility/placeholder/optional surfaces, not the primary Predict/CoT path. The next value-positive coverage work is **classification-driven cleanup**, not raw percentage chasing.
