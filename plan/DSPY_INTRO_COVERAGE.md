# DSPY_INTRO_COVERAGE.md — What `dspy-intro/src` scripts are covered here

## Summary
We use `dspy-intro/src` as a **behavior reference suite** to prioritize which end-user-facing workflows must work early.

- Local checkout in this dev environment: `../../dev/dspy-intro/src` (path varies for contributors).
- Coverage is measured by **deterministic, offline** ExUnit acceptance tests in `test/acceptance/*` (and a small number of supporting unit tests).

This document answers:
1) Which `dspy-intro` scripts are already mirrored by deterministic acceptance tests?
2) Which remain unported (and are they in-scope / high-leverage)?

## Coverage map (by script)

Legend:
- ✅ covered (deterministic acceptance test exists)
- 🟡 partial (we cover the core workflow, but not every variant in `dspy-intro`)
- ⛔ out-of-scope / not DSPy-core (for now)
- ❓ candidate (not covered yet; likely worth porting)

### `simplest/`

| `dspy-intro` script | Status | `dspy.ex` proof artifact | Notes |
|---|---|---|---|
| `simplest/simplest_dspy.py` | ✅ | `test/acceptance/simplest_predict_test.exs` | Predict + arrow signatures + int parsing |
| `simplest/simplest_dspy_with_signature_onefile.py` | ✅ | `test/acceptance/json_outputs_acceptance_test.exs` | JSONAdapter-style structured outputs |
| `simplest/simplest_tool_logging.py` | ✅ | `test/acceptance/simplest_tool_logging_acceptance_test.exs` | ReAct tools + callback logging |
| `simplest/simplest_dspy_refine.py` | ✅ | `test/acceptance/simplest_refine_acceptance_test.exs` | Refine loop |
| `simplest/simplest_dspy_with_attachments.py` | ✅ | `test/acceptance/simplest_attachments_acceptance_test.exs` | Multimodal request parts |
| `simplest/simplest_dspy_with_contracts.py` | ✅ | `test/acceptance/simplest_contracts_acceptance_test.exs` | PDF attachment → JSON extraction → Q&A |
| `simplest/simplest_dspy_with_transcription.py` | ✅ | `test/acceptance/simplest_transcription_acceptance_test.exs` | Image attachment → transcription → postprocess |
| `simplest/simplest_dspy_rlm.py` | ❓ | (none yet) | Uses `dspy.RLM` (sandboxed Python execution). We currently have Tools/ReAct, but no equivalent “code-in-sandbox” runner. Explicitly low priority for now (deferred; needs strong safety story). |
| `simplest/simplest_functai.py` | ⛔ | (none) | Not DSPy; uses `functai`. Treat as external/adjacent experimentation. |

### `classifier_credentials/`

| `dspy-intro` script | Status | `dspy.ex` proof artifact | Notes |
|---|---|---|---|
| `classifier_credentials/dspy_agent_classifier_credentials_passwords.py` | ✅ | `test/acceptance/classifier_credentials_acceptance_test.exs` | Constrained outputs via `one_of:` |
| `classifier_credentials/*_optimized.py` | 🟡 | (covered indirectly) | We cover the core behavior; “optimized” artifacts are not directly mirrored (teleprompt optimization is tested separately). |
| `classifier_credentials/*_examples.py` | 🟡 | (covered indirectly) | Treated as usage variants; not individually mirrored. |

### `knowledge_graph/`

| `dspy-intro` script | Status | `dspy.ex` proof artifact | Notes |
|---|---|---|---|
| `knowledge_graph/simple_build_kg_triplets.py` | 🟡 | `test/acceptance/knowledge_graph_triplets_test.exs` | We mirror the core workflow: chunk-by-chunk extraction + reuse existing_triplets |
| `knowledge_graph/simple_build_kg_triplets_multi_dimension.py` | 🟡 | `test/acceptance/knowledge_graph_triplets_test.exs` | Multi-dimension specifics aren’t explicitly asserted yet |
| `knowledge_graph/simple_build_kg_triplets_optimized.py` | 🟡 | (covered indirectly) | Optimization/persistence are covered elsewhere; KG-specific “optimized” script isn’t ported 1:1 |
| `knowledge_graph/*prompts.py`, `markdown_splitter.py`, etc. | 🟡 | (covered indirectly) | Supporting utilities; porting focus is on end-to-end behavior |

### `text_component_extract/`

| `dspy-intro` script | Status | `dspy.ex` proof artifact | Notes |
|---|---|---|---|
| `text_component_extract/extract_prompt_parts_101_guide.py` | ✅ | `test/acceptance/text_component_extract_acceptance_test.exs` | Structured extraction + LabeledFewShot improvement |
| `text_component_extract/extract_sentence_parts_grammatical.py` | ✅ | `test/acceptance/text_component_extract_acceptance_test.exs` | Uses Pydantic-typed nested outputs (list of typed components) via `schema:` + JSV. Bounded retry-on-parse/validation failure is also supported via `max_output_retries` (proof: `test/typed_output_retry_test.exs`). |

## What to prioritize next (recommended)

1) **Typed nested outputs story** (Pydantic-like)
   - This is a key adoption feature for “rely on structure + types”.
   - Plan/proposal: `plan/PYDANTIC_MODELS_IN_SIGNATURES.md`.

2) **Decide scope for `RLM`-style workflows** (`simplest_dspy_rlm.py`)
   - Explicitly **low priority for now** (deferred).
   - If/when we pick it up: we need a strong safety story for sandboxed execution.

3) **Multi-dimension KG coverage**
   - If users rely on it, add one acceptance assertion that the multi-dimension shape is preserved.

## Notes
- We do **not** aim to port every `dspy-intro` file 1:1. The goal is to cover the most common end-user workflows first.
- A script can be “covered” even if we don’t match the exact code structure; the contract is **observable behavior**.
