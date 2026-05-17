# UPSTREAM_PARITY_2026-05.md — R3 upstream alignment matrix

## Summary

This is the control artifact for **R3: Interface alignment + expansion** after fetching upstream Python DSPy on **2026-05-17**.

We found **170 upstream commits** since our previous local baseline (`970721b9` → `661a612c`). This does **not** mean we should bulk-port Python DSPy. It means our adoption-critical surface must be audited and aligned where user-visible behavior changed.

Source scan:
- `plan/research/upstream_dspy_python_2026-05-17.md`

Guiding rule:
- Preserve **end-user-facing parity** for common workflows.
- Prefer Elixir/BEAM implementation idioms internally.
- Do not port Python-specific infrastructure, LiteLLM internals, pickle semantics, or Deno/RLM implementation details unless they affect our public contract.

## Priority definitions

- **P0 — adoption-critical contract parity**: users will notice; affects signatures, Predict/CoT, adapters, output parsing, state/persistence safety, or deterministic eval.
- **P1 — important parity / next stable slice**: useful for familiarity or optimizer behavior, but not blocking core adoption.
- **P2 — later / optional / Python-specific**: document, demote, or keep in extras unless strategy changes.

## Status definitions

- **Covered**: behavior is already backed by a deterministic test/evidence path.
- **Partial**: related behavior exists, but not the upstream-specific behavior or edge case.
- **Missing**: no known implementation/evidence yet.
- **Not applicable**: Python-specific mechanism; record conceptual lesson only.
- **Unknown**: needs inspection before classification.

## R3.1 target slice — Core Contract Hardening

Immediate next implementation slice should focus on P0 user-visible contract behavior:

1. `Dspy.Signature` duplicate-field rejection / validation behavior.
2. `Dspy.Signature` input type validation where feasible and non-breaking.
3. `Dspy.ChainOfThought` rationale-field semantics versus upstream restored behavior.
4. Adapter behavior for empty/nil LM responses: explicit parse/error result, not silent success.
5. JSON output preservation for non-ASCII / diacritics.

Done criteria for R3.1:
- Matrix rows for these P0 items move from `Unknown`/`Partial`/`Missing` to `Covered` or explicitly documented divergence.
- Each `Covered` row has a concrete verification path.
- If an upstream P0 behavior conflicts with Elixir/BEAM idioms or would be breaking, document the divergence in `plan/INTERFACE_COMPATIBILITY.md` before changing behavior.

## Parity matrix

| Feature / Commit | Upstream behavior | dspy.ex status | Priority | Verification path | Next action |
|---|---|---:|---:|---|---|
| ChainOfThought rationale semantics — `4ef729d2` | Restores pre-`dspy.Reasoning` legacy rationale-field behavior; configurable `rationale_field` / `rationale_field_type`; prepends `reasoning` field with string-like rationale by default. | Covered | P0 | `test/r3_1_core_contract_hardening_test.exs`; existing acceptance: `test/acceptance/chain_of_thought_acceptance_test.exs`, `test/acceptance/chain_of_thought_attachments_acceptance_test.exs` | `dspy.ex` defaults to required string `:reasoning` prepended before declared outputs and supports custom rationale naming through existing `reasoning_field:` option. |
| Empty LM response adapter error — `b833bc55` | Adapters raise/return explicit parse error on empty/null LM response instead of producing silent `None`/success. | Covered | P0 | `test/r3_1_core_contract_hardening_test.exs` | Empty string returns `{:error, {:missing_required_outputs, [...]}}`; nil content returns `{:error, {:missing_content, nil}}`; neither succeeds silently. |
| Duplicate input/output field names — `3278e0f8` | Signature construction rejects duplicate field names across input/output definitions. | Covered | P0 | `test/r3_1_core_contract_hardening_test.exs` | Implemented duplicate input/output field rejection in `Dspy.Signature.new/2`, which also covers DSL modules and string/arrow signatures. |
| Input field type validation — `71493dba` | Python signatures validate input field types more strictly. | Covered | P0 | `test/r3_1_core_contract_hardening_test.exs`; existing attachment acceptance tests | Implemented typed input validation using the existing field validator. Scope: scalar values are validated/coerced consistently with output parsing; `%Dspy.Attachments{}` remains intentionally accepted as a multimodal input escape hatch. |
| JSONAdapter async native function calling — `fed54d0a` | Async JSONAdapter passes `use_native_function_calling`; affects tool-call/structured-output path. | Not applicable / Unknown | P1 | Existing tool tests: `test/tools_*`, adapter tests | We do not mirror Python async adapter internals directly; audit tool-call request behavior only. |
| JSON schema for DSPy custom types — `35c19acb` | Prompt avoids JSON schema for DSPy custom/native types. | Unknown | P1 | Candidate: typed output/schema prompt test | Check `Dspy.TypedOutputs` + signature prompt hints; only align if equivalent custom-type concept exists. |
| JSON diacritics preservation — `a3874e34` | JSON serialization uses `ensure_ascii=False`, preserving non-ASCII/diacritics. | Covered | P0 | `test/r3_1_core_contract_hardening_test.exs` | Verified JSONAdapter and default parser preserve non-ASCII output values such as diacritics and CJK text. |
| XMLAdapter — `dda0e617` | Adds XMLAdapter to Python DSPy. | Missing | P2 | None | Demote unless users request XML-style outputs; note as optional adapter candidate. |
| Field arg deprecations — `7e02cc8e` | Deprecates Python `prefix`, `format`, `parser` args in `InputField`/`OutputField`. | Not applicable / Partial | P2 | None | Elixir DSL differs; avoid importing Python deprecation mechanics unless public API overlap appears. |
| Evaluation `num_threads=1` main-thread behavior — `c3424073` | Evaluation avoids worker thread when single-threaded. | Covered / Partial | P0 | Existing: `test/evaluate_golden_path_test.exs`, `test/evaluate_detailed_results_test.exs` | Confirm `Dspy.Evaluate` deterministic single-thread semantics; add focused test only if gap found. |
| Transactional state loading — `c88b2790` | `load_state` validates then deep-copies to avoid partial mutation. | Unknown | P0 | Existing persistence tests: `test/module_parameter_*`, `test/parameter_file_persistence_test.exs` | Audit `Dspy.Module.apply_parameters/2` and `Dspy.Parameter.decode_json/1`; add invalid-input no-mutation test if missing. |
| Signature serialization Python 3.14 — `fcb648de` | Fixes cloudpickle serialization of Signature. | Not applicable | P2 | None | Python-specific; conceptually reinforces stable parameter/signature persistence tests. |
| BaseLM capability flags — `d0b89320`, `94062912` | Moves function-calling/response-schema capability checks to `BaseLM`, decoupling adapters from LiteLLM. | Partial | P1 | Existing: `test/lm/*`, `test/req_llm_adapter_test.exs` | Evaluate whether `Dspy.LM.supports?/2` is enough or needs richer capabilities (`:function_calling`, `:response_schema`, supported params). |
| Missing/nil usage metadata — `92e7f43e`, `faa99d1f` | LM usage handling tolerates missing/None usage. | Covered / Partial | P0 | Existing: `test/lm/usage_tracking_test.exs`, `test/lm/history_test.exs` | Confirm nil usage path in tests; add focused regression if not explicit. |
| Preserve per-message Responses API structure — `48b08d73` | LM conversion preserves message structure. | Partial | P1 | Existing: `test/lm/req_llm_multimodal_test.exs`, attachments acceptance tests | Keep provider-specific conversion in `req_llm`; verify request-map/multipart shape remains stable. |
| Cache bugs and safe disk deserialization — `8d12bdaf`, `02ce8b24` | Fixes disk cache edge cases; adds restricted pickle option. | Not applicable / Partial | P1 | Existing: `test/lm/cache_test.exs` | Python pickle is not applicable; audit Elixir cache for nil-path/no-double-lookup/security footguns. |
| Unsafe LM loading keys — `af2a955f` | Blocks unsafe LM loading keys. | Unknown | P1 | Candidate persistence/security test | Audit whether `dspy.ex` loads LM/provider state from persisted parameter files; document/security-test if it does. |
| LiteLLM lazy imports / dependency cleanup — `621c3a61`, dependency commits | Reduces import-time/dependency cost. | Covered | P1 | `mix.exs`, `test/core_deps_guardrail_test.exs` | Keep core dependencies minimal; do not port LiteLLM concepts into core. |
| BootstrapFewShot `seed=-1` + `metric_threshold` — `90a9dd81` | Passes `metric_threshold` in unshuffled seed=-1 path. | Unknown | P1 | Existing: `test/bootstrap_few_shot_smoke_test.exs`, `test/teleprompt/bootstrap_few_shot_determinism_test.exs` | Audit Elixir BootstrapFewShot seed/threshold behavior; add deterministic test if relevant. |
| MIPROv2 demo index assignment — `0ae2ca09` | Fixes demo index assignment in optimizer. | Unknown | P1 | Existing: `test/teleprompt/mipro_v2_*` | Audit Elixir MIPROv2 candidate/demo indexing; add regression if equivalent exists. |
| GEPA updates — `631085c0`, `73b26249`, `b3ee96fa`, `9e8a323d` | GEPA dependency/API moved: cached evals, removed tool optimization, result/docs changes. | Partial | P1 | Existing: `test/teleprompt/gepa_*`, `plan/GEPA.md` | Keep current GEPA documented as toy/proven subset; perform separate GEPA parity review before stronger claims. |
| BetterTogether redesign — `bb110a02` | BetterTogether becomes broad meta-optimizer compatible with arbitrary optimizers. | Missing | P2 | None | Do not implement now; optional later after core optimizer parity stabilizes. |
| RLM / PythonInterpreter JSONRPC + sandbox — many commits | Python RLM tool execution/sandboxing hardened. | Mostly not applicable | P2 | Existing ReAct/tool tests | Apply conceptual safety lesson only: explicit tool timeouts, no unsupervised background work, observable tool events. |
| Async tool functions — `62f5c43e` | PythonInterpreter awaits async tool functions. | Not applicable / P2 | Existing ReAct/tool tests | Elixir concurrency model differs; only audit if tool API supports async callbacks. |
| Deno symlink allow-read hardening — `b175ef87` | Resolves symlinks for Deno read allowlist. | Not applicable | P2 | None | Python/Deno-specific. Keep attachment file reading disabled by default in `dspy.ex`. |
| EmbeddingsWithScores — `b0ea262c` | Adds retriever output scores in addition to passages/indices. | Partial / Missing | P1 | Existing: `test/acceptance/retrieve_rag_in_memory_retriever_acceptance_test.exs`, retrieve tests | Decide whether to expose scores in `Dspy.Retrieve.InMemoryRetriever` or equivalent. |
| ColBERTv2 error handling/scoping — `8ccaaa35`, `b26b2378` | Handles ColBERT server errors and local forward scoping bug. | Unknown / likely P2 | P2 | `test/retrieve/colbert_stub_test.exs` | Audit only if ColBERT surface is advertised in docs. |
| SECURITY.md — `0af442e2` | Adds upstream security policy. | Missing | P1 | Candidate doc check | Consider before broader open-source push; align with contribution UX. |
| AI-generated code policy — `9b0834c0` | Adds AI contribution policy. | Missing | P1 | Candidate docs | Consider policy doc because this repo explicitly uses agents/sub-agents. |
| CI/security hardening — `75befbe0`, `9ebd38f5`, dependency pins | Adds zizmor/actionlint, tightens permissions and pins. | Partial | P1 | `.github/*`, `scripts/verify_all.sh` | Later OSS hardening slice; avoid mixing with core parity implementation. |

## Deliberate non-goals for R3.1

- Full Python DSPy parity.
- Bulk-porting all upstream commits.
- Porting LiteLLM internals into core.
- Implementing XMLAdapter or BetterTogether before P0 contract behavior is verified.
- Rebuilding Python RLM/Deno sandbox mechanics in Elixir.

## Review questions for the next planning checkpoint

1. Is ChainOfThought rationale compatibility important enough to change existing `dspy.ex` output shape if it differs?
2. Should R3.1 favor strict validation even if it breaks permissive current behavior?
3. Do we need a public compatibility statement distinguishing **adoption-slice parity** from **full upstream parity**?
4. Should SECURITY.md / AI contribution policy happen before or after the P0 code hardening slice?
