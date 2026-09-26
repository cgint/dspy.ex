# PARITY_QUEUE.md — ordered slice queue (single source of truth)

Created 2026-09-26. Loop + gates: `plan/SLICE_LOOP.md`.
This queue supersedes older ledgers as the **work queue**. They stay as background:
`plan/UPSTREAM_PARITY_2026-05.md` (delta audit vs upstream `661a612c`), `plan/INTERFACE_COMPARISON_MATRIX.md` (partly stale, e.g. typed outputs now exist), `plan/RELEASE_MILESTONES.md` (phase charter; R3 is effectively done).
Active OpenSpec changes are listed as rows so the queue sees them.

Status: `todo` | `doing` | `done (date, tag)` | `blocked (why)` | `dropped (why)`.
Effort: S/M/L. Upstream paths are relative to `../dspy/dspy/`.

## Safety net (must come first)

| # | Slice | Upstream | Effort | Status |
|---|---|---|---|---|
| S0 | Consumer contract tests `test/consumer_contract/` (14 items; 33 tests; `{:parse_failed,_}` not producible offline) | – | M | done (2026-09-26) |
| S0b | `scripts/consumer_canary.sh`: copy each consumer into gitignored `tmp/canary/`, swap dep to `path:` this checkout, `mix deps.get && mix compile --warnings-as-errors`; allowlist copy; warnings diffed vs baseline (WARN-BASELINE = pass) | – | M | done (2026-09-26) |

## Parity slices (additive)

| # | Slice | Upstream | Effort | Status |
|---|---|---|---|---|
| P0 | `Dspy.context/2` process-scoped settings overrides (foundation for BestOfN/Parallel; `Dspy.Settings.get` consults overlay) | `dsp/utils/settings.py` context | S/M | done (2026-09-26, v0.3.40) |
| P1 | `Dspy.BestOfN` (uses P0; per-attempt temperature 1.0 + `rollout_id` in cache key; note `Dspy.Refine` today repeats identical calls, which collapse under `cache: true`) (N rollouts, reward fn, threshold, fail_count) | `predict/best_of_n.py` | S | done (2026-09-26, v0.3.41) |
| P2 | `Dspy.Parallel` (batch-run module/example pairs, `num_threads`→`max_concurrency`, error budget) | `predict/parallel.py` | S | done (2026-09-26, v0.3.42) |
| P3 | `Dspy.MultiChainComparison` (M completions → comparison signature) | `predict/multi_chain_comparison.py` | S/M | done (2026-09-26, v0.3.43) |
| P4 | Program-level `save/load` of module state to JSON (on top of parameter export/apply) | `primitives/base_module.py` save/load_state | M | todo |
| P5 | Module-level `inspect_history` over existing `Dspy.LM.History` | `utils/inspect_history.py`, `clients/base_lm.py` | S/M | todo |
| P6 | `Dspy.Teleprompt.KNNFewShot` + `Dspy.KNN` (reuse retrieval/embeddings) | `predict/knn.py`, `teleprompt/knn_fewshot.py` | M | todo |
| P7 | `Dspy.Teleprompt.RandomSearch` (BootstrapFewShotWithRandomSearch) | `teleprompt/random_search.py` | M | todo |
| P8 | Public callback API (telemetry-backed module/LM/adapter start/end events) | `utils/callback.py` | M | todo |
| P9 | `Dspy.ProgramOfThought` — needs sandbox decision (Elixir code eval is unsafe) | `predict/program_of_thought.py` | M | blocked (sandbox design) |
| P10 | XML adapter (OpenSpec `signature-xml-adapter`) | `adapters/xml_adapter.py` | M | todo |
| P11 | BAML schema rendering (OpenSpec `adapter-baml-schema-rendering`) | `adapters/baml_adapter.py` | M | todo |
| P12 | LM streaming | `streaming/` | L | todo (scope first) |
| P13 | Disk-backed LM cache | `clients/cache.py` | S/M | todo |

## Hygiene (low priority, non-blocking)

| # | Slice | Status |
|---|---|---|
| H1 | Public-API snapshot guard for stable modules (complements S0) | todo |
| H2 | `Dspy.Adapters` characterization tests (from `plan/COVERAGE_AUDIT_2026-05.md`) | todo |
| H3 | Reconcile stale plan docs (RELEASE_MILESTONES R3, matrix typed-outputs row, STRATEGIC_ROADMAP upstream pin) | todo |
| H4 | OpenSpec `attach-raw-output-to-parse-failures`: archive after user-verification tasks 4.1/4.2 | todo |

## Out of scope unless strategy changes

CodeAct / RLM / PythonInterpreter (Python sandbox), GRPO / BootstrapFinetune (training infra), Avatar optimizer, full MIPROv2/GEPA algorithm parity (L; decide scope explicitly first).
