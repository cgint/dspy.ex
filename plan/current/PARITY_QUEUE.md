# PARITY_QUEUE.md — ordered slice queue (single source of truth)

Regenerated 2026-09-28 by Greta **from the milestones approved by the user on 2026-09-28** (`plan/current/GAP_ANALYSIS_3.4.0.md` §Phase C v2; data: `plan/research/pi_handoffs/phaseB/inventory_final.csv`, column `milestone`). Loop + gates: `plan/SLICE_LOOP.md`, `plan/HOW_WE_WORK.md`.
Current reference: [DSPy 3.5.0 recount](UPSTREAM_RECOUNT.md). The milestone
tables below retain the 3.4.0 delivery estimates for context. Current
classifications are in [UPSTREAM_INVENTORY.csv](UPSTREAM_INVENTORY.csv).

Stabilization still needs a reproducible consumer canary and the release gate.
The next product milestone is M2, focused on program persistence and history.
Keep the three Elixir-specific metric and result contracts partial until their
compatibility decisions are recorded.

## Safety net + foundations
| # | Slice | Upstream | Effort | Status |
|---|---|---|---|---|
| S0 | Consumer contract tests `test/consumer_contract/` (14 items; 33 tests; `{:parse_failed,_}` not producible offline) | – | M | done (2026-09-26) |
| S0b | `scripts/consumer_canary.sh`: copy each consumer into gitignored `tmp/canary/`, swap dep to `path:` this checkout, `mix deps.get && mix compile --warnings-as-errors`; allowlist copy; warnings diffed vs baseline (WARN-BASELINE = pass) | – | M | done (2026-09-26) |

| # | Slice | Status |
|---|---|---|
| H0b-1 | Crash/timeout hardening, runtime sites (`openspec/changes/h0b-crash-hardening`) | **done — v0.3.46** |
| H0b-2 | Crash hardening Evaluate + `max_errors`/`failure_score` + Q2/Q3 raises (D-U1/D-U2 = upstream, approved 2026-09-28) | **done — v0.3.48** |
| H0b-3 | Verify that MIPROv2 trial scoring and GEPA baseline and candidate scoring propagate `MaxErrorsExceeded` and `InvalidMetricResult` through public compile calls. An injected rescue at each site fails its two [regression tests](../../test/h0b2/direct_compile_error_propagation_test.exs). | Implemented |
| H12 | **Strict parsing of `:number` and `:integer` outputs — a live bug in shipped code, blocks the M1-d release.** `signature.ex:645-652` (`:number`) and `:632-636` (`:integer`) accept whatever number the text *starts* with and discard the rest (`{num, _rest} -> {:ok, num}`). So a judge answering `"80%"` becomes `80.0` and is clipped to a **perfect 1.0**, and `"1/2"` becomes `1.0` — silently wrong values, not errors. We also reject valid input that Python accepts (`".5"`). **Target = upstream 3.4.0's own verdicts**, measured by running `dspy.adapters.utils.parse_value(s, float)` (probe `ck_parse_float.py`, 2026-09-28). **Must accept** (with value): `"0.8"`→0.8, `" 0.8 "` and `"0.8\n"`→0.8, `"1"`→1.0, `"-0.2"`, `".5"`→0.5, `"5."`→5.0, `"1e-1"`→0.1, `"1E3"`→1000.0, `"+0.5"`→0.5, `"\"0.8\""` (quoted)→0.8, `"1_000"`→1000.0. **Must reject** (→ `{:error, {:invalid_output_value, field, _}}`, so a judge metric raises and Evaluate scores a failed example): `"80%"`, `"1/2"`, `"0.8 (high)"`, `"0.8/1.0"`, `"about 0.8"`, `"0,8"`, `"N/A"`, `""`, `"[0.8]"`, `"0.8.1"`, `"null"`. **Three upstream acceptances need Horst's ruling under the corrupt-or-lose-data principle** (HOW_WE_WORK): (a) **`"NaN"`, `"nan"`, `"inf"`, `"-inf"`** — upstream accepts, and its judge clamp then turns them into a **perfect 1.0** (`max(0, min(1, nan))` = 1.0, verified); BEAM floats cannot represent NaN/inf at all, so **reject** is both forced and principled; (b) **`"true"`→1.0** — pydantic coerces a boolean word into a number, so a judge answering "true" scores perfect; recommend **reject**, same species as "80%"; (c) **`"0x10"`→16.0** — a Python literal accident via `ast.literal_eval`, harmless; recommend **match**. `:integer` gets the same treatment, with its golden generated the same way (`parse_value(s, int)`). **Public-entry test per case** through a Predict whose scripted LM answers that exact string, via the committed golden generator (`plan/research/`, E1/F1 ruling). **Behaviour change for consumers** with `:number`/`:integer` outputs (lenient answers that used to parse now fail): grep the 5 consumers for such fields, run the canary, and a `RELEASES`/`COMPATIBILITY` note. Size S–M | **done — v0.4.3** (2026-09-30) |
| H13 | **Trace protocol for metrics, and what BootstrapFewShot accepts** (booked on D2, 2026-09-28). Upstream calls `metric(example, prediction, trace)` while bootstrapping (`teleprompt/bootstrap.py:206`); judge metrics then return `Prediction(score = f1 >= threshold)` (`auto_evaluation.py:62,123`). Upstream then decides with `success = metric_val >= metric_threshold` if `metric_threshold` is set, else **`success = metric_val` by truthiness** (`bootstrap.py:207-210`). **Correction to what Greta first reported:** upstream `Prediction` defines `__len__` but no `__bool__`, so `Prediction(score=False)` is **truthy** (verified: `bool(Prediction(score=False))` is `True`). **Without `metric_threshold`, upstream accepts every judge-scored demo, whatever the score** — it does *not* reject a 0.3. The basic native BootstrapFewShot still accepts a demo iff `is_number(score) and score > 0` and then `score >= metric_threshold` (default 0). **Real divergences:** (1) a judge metric with no `metric_threshold` — upstream accepts all, ours accepts f1 > 0; (2) with `metric_threshold: t` — upstream compares the judge's *boolean* (0/1) against `t`, ours compares the *F1* against `t`; (3) a plain numeric metric returning a negative score — upstream accepts it (truthy), ours rejects. Until this lands, `threshold_metric/1` (M1-d) is the explicit way to get "accept iff f1 ≥ the judge's threshold". Decision needed when booked: port the trace protocol, and **do not** port Prediction-truthiness (it silently ignores the score — the corrupt-or-lose principle says don't import it). Size M | partial — BootstrapRS, BootstrapFewShot, and KNNFewShot support attempt-local trace metrics. Evaluate supplies `nil`. The legacy positive-score and threshold contract is preserved. Structured judge results still need an explicit score policy. |
| H14 | Numeric parsing and mutation-harness follow-up. The H12 runner uses shared signal recovery, preflights both numeric types and injected guard forms, and checks a green base. Verified 18 mutations and three public parsing paths. The parser preserves signed exponents and accepts the tested nested parentheses, quotes, and radix separators. | Implemented |
| H15 | **String-key audit — two live bugs in shipped code, one class: atom-only field lookup on `attrs`** (Greta, M1-e refresh 2026-09-30; ruled T3/T4 by Horst 2026-09-30). **P1 (loud, shipped v0.4.1):** `Dspy.Metrics.answer_exact_match/2,3` and `answer_passage_match/2` read `Map.fetch(attrs, :answer)`/`(:context)` (`fetch_field!/2`, `fetch_context!/2`, `lib/dspy/metrics.ex`) → a string-keyed example raises `"example[:answer] is missing"`, so in `Evaluate` every loaded example scores `failure_score`. **P2 (silent, worst):** `Dspy.Signature.format_example/3` (`lib/dspy/signature.ex:470-480`) reads `Map.get(example.attrs \|\| example, field.name, "")` → a string-keyed demo renders with **empty values** in the Default adapter and JSONAdapter; ChatAdapter is correct (`Dspy.Example.get/2`). Probe `plan/research/m1e-refresh-2026-09-30/demo_probe*.exs`: string-keyed demo in prompt = false/false/true. A few-shot optimiser over a loaded trainset trains on blank demos and reports nothing. **Scope:** P1, P2, the ~12 other atom-only `attrs` call sites (`trainset.ex` 4, `metrics.ex` 4, `ensemble.ex` 2, `signature.ex` 1, `multi_chain_comparison.ex` 1) and pattern-matched `%{attrs: %{k: _}}` heads — **every site through ONE canonical accessor** (the `Prediction.fetch/2`/`Example.get/2` atom→string fallback), not 12 separate fixes (the H12 three-parsers lesson). **Plus T4:** `majority` accepts string-keyed maps (reverses the M1-c atom-only boundary; keep "both `"k"` and `:k`" raising); update its COMPATIBILITY entry and remove the now-wrong atom-keys hint. Each site: a string-keyed test through the public entry, mutation-proven. Size M | **done 2026-10-02 v0.4.5** |
| H16 | **Explicit random state for core sampling.** At v0.4.11, nine process-local seeds across Evaluate, Trainset, BootstrapFewShot, and Ensemble altered caller state. The four paths now share the CPython-compatible generator. Public tests pin fold order, sampling strategies, bootstrap aggregation sizes, BootstrapFewShot candidate draws, and caller state. Outputs for a fixed seed can change from v0.4.11. See the release notes. | Implemented for M2. Release pending. |

## History (done before regeneration)
| # | Slice | Upstream | Effort | Status |
|---|---|---|---|---|
| P0 | `Dspy.context/2` process-scoped settings overrides (foundation for BestOfN/Parallel; `Dspy.Settings.get` consults overlay) | `dsp/utils/settings.py` context | S/M | done (2026-09-26, v0.3.40) |
| P1 | `Dspy.BestOfN` (uses P0; per-attempt temperature 1.0 and `rollout_id` in the cache key) (N rollouts, reward fn, threshold, fail_count) | `predict/best_of_n.py` | S | done (2026-09-26, v0.3.41) |
| P2 | `Dspy.Parallel` (batch-run module/example pairs, `num_threads`→`max_concurrency`, error budget) | `predict/parallel.py` | S | done (2026-09-26, v0.3.42) |
| H0 | Carry caller context (overrides, callbacks) into all 13 library spawn sites | `utils/parallelizer.py` | M | done (2026-09-26, v0.3.44) |
| P3 | `Dspy.MultiChainComparison` (M completions → comparison signature) | `predict/multi_chain_comparison.py` | S/M | done (2026-09-26, v0.3.43) |

## M1 — Evaluation you can trust
After this you can …measure your program reliably: failed examples count against the score as in Python, results can be saved and shown as a table, and standard metrics and data loaders are ready to use. Reported scores can drop.
- **Depends on:** **H0b-2** (Evaluate crash semantics; D-U1/D-U2 approved 2026-09-28)
- **Exit example:** Load a CSV with DataLoader, then evaluate a CoT program with SemanticF1, `max_errors: 2` and one failing example. Expected: failure_score counted, an `EvaluationResult` struct (Access-compatible), JSON saved.
- **Size:** 10 items, 17 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S044 | majority | partial | H | S | 3.00 | <=2.6 | S050 | N | - | Parsed inputs support signature-based field selection and typed votes. List inputs keep the v0.4.2 contract, including atom field options and text-only default normalization. | Parsed voting implemented. Release pending. |
| S031 | Evaluate | partial | H | S | 3.00 | <=2.6 | U008 | N | - | [reclassified done->partial] missing display_table/max_errors/failure_score/save_as_csv+js | done 2026-09-29 v0.4.0 (M1-a; failure_score/max_errors since v0.3.48) |
| U010 | answer_exact_match | partial | H | S | 3.00 | <=2.6 | U011 U012 | N | - | add frac param + list-of-answers dispatch | done v0.4.1 (M1-b) |
| U011 | answer_passage_match | missing | M | S | 2.00 | <=2.6 | U012 | N | - | no Elixir equivalent | done v0.4.1 (M1-b) |
| U006 | CompleteAndGrounded | missing | M | M | 1.00 | <=2.6 | - | N | - | no Elixir equivalent | done 2026-10-02 v0.4.4 (M1-d) |
| U009 | SemanticF1 | missing | M | M | 1.00 | <=2.6 | - | N | - | no Elixir equivalent | done 2026-10-02 v0.4.4 (M1-d) |
| U012 | normalize_text | partial | L | S | 1.00 | <=2.6 | - | N | - | make public; upstream API is dspy.evaluate.normalize_text | done v0.4.1 (M1-b) |
| U003 | Dataset | missing | M | M | 1.00 | <=2.6 | U002 | N | - | No Dataset base (train/dev/test, shuffle_and_sample, prepare_by_seed, reset_seeds) | **done 2026-10-03 v0.4.6 (M1-e)** |
| U008 | EvaluationResult | missing | M | M | 1.00 | 3.1.0 | S031 | N (was Y; struct + Access keeps old reads, checked 2026-09-26) | - | struct with Access + all current keys | done 2026-09-29 v0.4.0 (M1-a) |
| U002 | DataLoader | missing | H | L | 0.75 | <=2.6 | DEP:datasets;DEP:pandas | N | - | No dataset loaders (from_huggingface/from_csv/from_json/from_pandas/from_rm) | **partial 2026-10-03 v0.4.6 (M1-e):** from_csv/from_json/from_list, sample, train_test_split done; from_huggingface / from_pandas / from_rm not ported (need Python-ecosystem equivalents — out of M1-e scope) |

## M2 — Programs you can save, inspect, reuse
After this you can …optimize a program once, save it, load it later or elsewhere and get the same behaviour, and see exactly which LM calls one program made.
- **Depends on:** M1 (BootstrapRS scores via Evaluate)
- **Exit evidence:** The fresh-process BootstrapRS checkpoint test reproduces the program's requests and prediction. An explicit `Dspy.capture_history/2` scope can retain the program's calls for `Dspy.inspect_history/2`.
- **Size:** 12 items, 15 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S002 | configure | partial | H | S | 3.00 | <=2.6 | - | N | - | Shared `num_threads` settings reach Evaluate and Parallel. Evaluate already reads the shared `max_errors` budget. Global retrieval, tracing, and other execution settings remain. | Shared concurrency implemented. Included in v0.5.0. |
| S051 | Example | partial | H | S | 3.00 | <=2.6 | - | N | - | Labels, field removal, and recursive dictionaries for `Example`, `Prediction`, and `History` are implemented. Legacy `inputs/1` still falls back to all attributes when inputs are unset or empty. | M2 example slices implemented. Included in v0.5.0. |
| S054 | Module | partial | H | S | 3.00 | <=2.6 | - | N | P5 (Module.inspect_history = facet S054.f7), P4 | Named discovery, immutable slot updates, shared LM bindings, and reset copies implemented. BootstrapRS records private teacher traces. Public diagnostics use an explicit capture scope for immutable programs. | M2 traversal and reset in v0.5.0. Scoped history in M3b. |
| S055 | Prediction | partial | H | S | 3.00 | <=2.6 | S051 | N | - | `from_completions` exposes the first row and retains parsed alternatives. Score conversion, arithmetic and comparisons remain. | M2 parsed-completion slice implemented. Included in v0.5.0. |
| S067 | Signature | partial | H | S | 3.00 | <=2.6 | - | N | - | [facet rule: done->partial] pydantic-model validation, annotated types, and field constrai | todo |
| S077 | BootstrapFewShotWithRandomSearch | partial | H | S | 3.00 | <=2.6 | S075 | N | P7 | Search, ranking, and per-slot teacher demos work for composite programs. Custom programs can still use `predict.examples`. Arity-three metrics receive ordered teacher steps and can score candidates with a `nil` trace. Exact upstream acceptance for non-scalar results remains open. | M2 composite slice implemented. Included in v0.5.0. |
| S060 | EmbeddingsWithScores | partial | M | S | 2.00 | 3.2.0 | S059 | N | - | No EmbeddingsWithScores class; closest: InMemoryRetriever Document.score (cosine) | todo |
| S038 | Predict | partial | H | M | 1.50 | <=2.6 | S033 | N | - | Stored and call config support temperature, token limits, rollout IDs and explicit counts for compatible LMs. Native predictors can reset demos and LM bindings. Built-in multi-choice providers, the Python temperature fallback, dump/load_state, and criteria remain. | M2 native generation counts implemented. Included in v0.5.0. |
| S113 | load | partial | H | M | 1.50 | <=2.6 | S059 | N | P4 | Native JSON v1 restores learned state into a caller-built program with matching typed predictor slots and named LM bindings. Python file exchange and whole-program serialization remain separate. | Native checkpoint implemented. Included in v0.5.0. |
| S050 | Completions | partial | L | S | 1.00 | <=2.6 | S055 | N | - | Standalone parsed collection supports ordered rows, indexed access, field columns, signatures, Majority voting, and opt-in generation counts for compatible LMs. Built-in multi-choice provider support remains. | M2 parsed-completion and generation slices implemented. Included in v0.5.0. |
| S021 | Embedder | partial | M | M | 1.00 | <=2.6 | S022 | N | - | Hosted and callable embedders support ordered batches, per-call options, and validated result shapes. Embedding caching and async parity remain. | Synchronous batch slice implemented. Included in v0.5.0. |
| S004 | load_settings | missing | L | S | 1.00 | 3.2.0 | - | N | - | Dspy.Settings.save/load (upstream settings.py:266,299) not ported | todo |
| S001 | *also:* `:bootstrap_rs` optimizer alias | idiom | | | | | S077 | N | P7 | Routes to `Dspy.Teleprompt.BootstrapFewShotWithRandomSearch`. | M2 first slice implemented. Included in v0.5.0. |

## M3 — Production LM

`v0.6.0` covers M3a provider hardening. The
[offline acceptance example](../../examples/offline/provider_retry_disk_cache_offline.exs)
exercises 429 recovery and persistent cache reuse across application restart.
The disk tier currently supports the stock OpenAI `gpt-4.1-mini` Responses
route. Wider eligibility and M3b lifecycle hooks remain in scope.

The first provider retry slice classifies known HTTP, transport, and local
failures internally. It preserves caller error tuples and keeps structured
fallback for explicit schema or capability failures. Public error types remain
open in the inventory below.
After this you can …run against real providers robustly: clear error types, automatic retries, a cache that survives restarts, and hooks that trace every call.
- **Depends on:** M2 (LM state in save/load)
- **Exit example:** A fake provider returns 429 then 200: a typed error, then a retry. After a restart the cache hits. A callback module records module/LM/adapter start/end events.
- **Size:** 28 items, 37 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S090 | ContextWindowExceededError | missing | M | S | 2.00 | 3.2.0 | - | N | - | [reclassified na->missing] No detection/classification of context-window-exceeded response | todo |
| S096 | LMError | missing | M | S | 2.00 | 3.3.0 | S099 | N | - | [reclassified na->missing] Base LM exception absent; errors are {:error, atom/term} on the | todo |
| S012 | JSONAdapter | partial | H | M | 1.50 | <=2.6 | S005,S016 | N | - | output_contract in request map ≠ upstream response_format; no json_repair | todo |
| U026 | BaseCallback | partial | H | M | 1.50 | <=2.6 | U036 | N | P8 | Elixir behaviours cover evaluation, module, LM, adapter, and tool events. Compile and interpreter hooks remain. | todo |
| U036 | with_callbacks | partial | H | M | 1.50 | <=2.6 | U026 | N | P8 | Settings `:callbacks` and `with_callbacks/2` register evaluation, module, LM, adapter, and tool handlers. Events link observed calls across captured worker contexts. | todo |
| S025 | configure_cache | partial | H | M | 1.50 | 3.0.0 | S022 | N | P13 | Bounded LRU memory and opt-in, byte-bounded JSON disk storage for the stock OpenAI gpt-4.1-mini Responses route. Wider provider and model eligibility remains. | todo |
| S110 | configure_dspy_loggers | missing | L | S | 1.00 | <=2.6 | - | N | - | DSPy diagnostics use the host's Elixir Logger levels and handlers. | todo |
| S111 | disable_logging | done | L | S | 1.00 | <=2.6 | S112 | N | - | `Dspy.disable_logging/0` silences DSPy diagnostics across processes. | Implemented in M3b |
| S112 | enable_logging | done | L | S | 1.00 | <=2.6 | S111 | N | - | `Dspy.enable_logging/0` restores DSPy diagnostics under the host logger configuration. | Implemented in M3b |
| S092 | LMAuthError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Auth failures (401/403) not classified; req_llm {:error, term}  | todo |
| S093 | LMBillingError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Billing failures not classified in port | todo |
| S095 | LMConfigurationError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Misconfiguration detected at LM construction (ArgumentError); n | todo |
| S097 | LMInvalidRequestError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] 400-class provider errors not classified in port | todo |
| S100 | LMProviderError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Provider 5xx/generic errors not classified; req_llm term propag | todo |
| S101 | LMRateLimitError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Rate-limit (429) classification/retry policy absent | todo |
| S102 | LMServerError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Server (5xx) errors not classified in port | todo |
| S104 | LMTimeoutError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Timeout classification absent; req/finch errors propagate | todo |
| S105 | LMTransportError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Network/DNS/TLS errors not classified in port | todo |
| S106 | LMUnexpectedError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] No catch-all exception class; unexpected errors propagate as ra | todo |
| S107 | LMUnsupportedFeatureError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Unsupported-feature (e.g. tools on a provider) classification a | todo |
| S108 | LMUnsupportedModelError | missing | L | S | 1.00 | 3.3.0 | - | N | - | [reclassified na->missing] Unsupported model → {:error, :invalid_model} at LM.new; no runt | todo |
| S109 | is_retryable_lm_error | missing | L | S | 1.00 | 3.3.0 | S089 | N | - | [reclassified na->missing] No LM-error retryability classifier; retry applies to output de | todo |
| S094 | LMCollectionLimitError | missing | L | S | 1.00 | 3.4.0 | - | N | - | [reclassified na->missing] Collector budget errors belong to 3.4.0 LM collector, not prese | todo |
| S098 | LMLockTimeoutError | missing | L | S | 1.00 | 3.4.0 | - | N | - | [reclassified na->missing] Credential lock contention (Python threading/file lock) has no  | todo |
| S103 | LMStreamAssemblyError | missing | L | S | 1.00 | 3.4.0 | - | N | - | [reclassified na->missing] Streaming/assembly errors belong to 3.4.0 streaming LM, not pre | todo |
| S022 | LM | partial | H | L | 0.75 | <=2.6 | S020 S025 U037 DEP:req_llm | N | - | Dspy.LM.new+ReqLLM covers model/temperature/max_tokens; missing cache/call/callbacks/num_r | todo |
| S023 | Provider | missing | L | M | 0.50 | <=2.6 | S022 | N | - | no provider base (finetunable/reinforceable/launch/kill/finetune/is_provider_model) anywhe | todo |
| S024 | TrainingJob | missing | L | M | 0.50 | <=2.6 | S023 | N | - | no fine-tuning job type; concurrent.futures.Future has no dspy.ex counterpart | todo |

## M4 — Agents & multimodal
After this you can …build tool-using agents that also take images or audio, refine answers with feedback, and pick the XML or BAML output format.
- **Depends on:** M3 (typed errors, callbacks)
- **Exit example:** A ReAct agent with a tool and an image input via ChatAdapter, plus one Refine round with feedback.
- **Size:** 16 items, 34 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S008 | Code | partial | M | S | 2.00 | 3.0.0 | S018 | N | - | untested :code field type; no language param; not a content-part Type | todo |
| S017 | TwoStepAdapter | partial | M | S | 2.00 | 3.0.0 | S005 | N | - | extraction LM/adapter from settings, not constructor; extractor is JSONAdapter not chat | todo |
| S007 | ChatAdapter | partial | H | M | 1.50 | <=2.6 | S005,S015,S016 | N | - | Typed history replays multimodal user turns, assistant calls and tool-role results. Opt-in ReAct preserves native IDs, accepts JSON tool calls from marker sections, and validates submit on the OpenAI Responses route. Wider provider support and an adapter fallback flag remain open. | Typed replay and structured ReAct implemented |
| S011 | Image | done | H | M | 1.50 | <=2.6 | S018 | N | - | done: Dspy.Image + :image field (0d7b0d1); :image now declared+validatable, docs everywhere | done 2026-10-10 v0.4.7 (align-image-input-with-python) |
| S061 | Retrieve | partial | H | M | 1.50 | <=2.6 | S059;U032 | N | - | No dspy.Retrieve Parameter (k, callbacks) wrapping settings.rm; dspy.ex Dspy.Retrieve is a | todo |
| S043 | Refine | partial | H | M | 1.50 | 3.0.0 | S038 | N | - | Distinct rollouts and per-call failure budget. Explicit `feedback_lm:` receives bounded declared fields and returns slot-specific advice for one attempt. Native opt-in remains a deliberate difference from upstream's automatic feedback. | Scoped feedback implemented |
| U032 | dummy_rm | missing | L | S | 1.00 | <=2.6 | S061 | N | - | No dummy_rm stub retriever | todo |
| S006 | Audio | missing | M | M | 1.00 | 3.0.0 | S018 | N | - | no audio input type; Attachments is file-only, no base64/audio parts | todo |
| S019 | XMLAdapter | partial | M | M | 1.00 | 3.0.0 | S007 | N | P10 | Opt-in signature adapter handles schema-directed containers, repeated lists, scalar literals, record unions, and mixed string and record unions. JSON inside a tag makes the type explicit. Typed history retains media and tool call IDs across retries. Other scalar and collection union combinations remain open. | Field adapter, typed schemas, and typed history replay implemented |
| S059 | Embeddings | partial | M | M | 1.00 | 3.0.0 | S060;DEP:faiss-cpu | N | - | No corpus Embeddings retriever (embed(corpus), k, normalize, save/load/from_saved, FAISS f | todo |
| S015 | ToolCallResults | missing | L | S | 1.00 | 3.3.0 | S007,S016 | N | - | no way to pass tool results back through history | todo |
| S005 | Adapter | partial | H | L | 0.75 | <=2.6 | - | N | - | class pipeline options + native-response-type planning missing | todo |
| S029 | ColBERTv2 | partial | H | L | 0.75 | <=2.6 | - | Y | - | deliberate stub returning {:error}; v2 GET/POST request functions and ColBERTv2RetrieverLo | todo |
| S013 | Reasoning | missing | L | M | 0.50 | 3.1.0 | S005,S018 | N | - | no dspy.Reasoning type; CoT :reasoning field and LM reasoning_effort opt exist but are sep | todo |
| S018 | Type | missing | L | L | 0.25 | 3.0.0 | - | N | - | no custom-type framework; Dspy.TypedOutputs JSON schemas cover output-side only | todo |
| +1 | BAMLAdapter (public class, not in `__all__`; added +1) | missing | M | M | | 3.x | S012 | N | P11 | OpenSpec `adapter-baml-schema-rendering` | todo |

## M5 — Streaming
After this you can …show answers as they are generated (token streaming plus status messages), e.g. in a LiveView.
- **Depends on:** M3 callbacks, M4 adapters
- **Exit example:** Stream a field's tokens and status messages from a CoT program in a form a LiveView can consume.
- **Size:** 7 items, 16 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| U020 | StatusMessage | done | M | S | 2.00 | 3.0.0 | S072 | N | - | A message value carries provider-formatted progress text in the program stream. | M5 status messages |
| U021 | StatusMessageProvider | partial | M | M | 1.00 | 3.0.0 | U020 S072 | N | - | Opt-in formatters receive module and LM lifecycle phases and allowlisted metadata. Tool progress defaults and composite routing remain. | M5 status provider |
| U023 | StreamResponse | partial | L | S | 1.00 | 3.0.0 | S072 | N | - | Field chunks name the predictor and signature field and signal field completion. Standalone Chat string outputs are covered. | M5 Chat field chunks |
| S072 | streamify | partial | H | L | 0.75 | <=2.6 | S022 | N | P12 | Lazy standalone Predict and ChainOfThought streams deliver raw or selected Chat field chunks, optional progress events, and a final prediction. Halting consumption closes the HTTP stream. Composite programs and broader adapter support remain. | M5 program streaming |
| U022 | StreamListener | partial | H | L | 0.75 | 3.0.0 | U023 | N | P12 | Standalone Chat field selection accepts declared string output names. Composite predictor resolution and other adapters remain. | M5 Chat field listeners |
| U024 | apply_sync_streaming | missing | L | M | 0.50 | 3.0.0 | U020 S072 | N | - | no async-generator-to-sync bridge; Task.async_stream exists but is not dspy-streaming | todo |
| U025 | streaming_response | missing | L | M | 0.50 | 3.0.0 | U023 S072 | N | - | no streaming_response wrapper | todo |

## M6 — Optimizers+
After this you can …use the stronger optimizers: real GEPA, example selection by similarity (KNNFewShot), and the remaining upstream optimizers.
- **Depends on:** M1, M2, M3
- **Exit example:** GEPA improves a toy program's metric on DummyLM with a reflection LM. KNNFewShot selects demos by embedding.
- **Size:** 9 items, 28 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S035 | KNN | partial | M | M | 1.00 | <=2.6 | - | N | P6 | Native index and dot-product lookup use declared examples and Dspy.Embedder. Field ordering, numeric precision, and ties follow the documented Elixir contract. | M6 native lookup |
| S083 | KNNFewShot | partial | M | M | 1.00 | <=2.6 | S035 S075 | N | P6 | One index and per-query BootstrapFewShot demo construction through the native compile interface. Metrics can inspect the neighbor's teacher trace. Exact upstream demo selection remains open. | M6 query-time demos |
| S082 | InferRules | missing | M | M | 1.00 | 3.0.0 | S031 | N | - | no Elixir equivalent | todo |
| S078 | BootstrapFinetune | missing | H | L | 0.75 | <=2.6 | - | N | - | no Elixir equivalent | todo |
| S081 | GEPA | partial | H | L | 0.75 | 3.0.0 | S031 S087 | Y | - | Reflection LM, custom instruction proposer, five-argument feedback, typed slot mutation, opt-in Pareto selection, budgeted ancestor-based merges, and format-failure feedback. Additional frontier objectives and configurable built-in proposals remain open. | M6 GEPA custom proposer |
| S074 | BetterTogether | missing | M | L | 0.50 | <=2.6 | - | N | - | no Elixir equivalent | todo |
| S087 | bootstrap_trace_data | partial | L | M | 0.50 | 3.1.0 | S031 | N | - | Concurrent indexed traces and opt-in typed-slot parse-failure records with a configured score. Crash capture and partial-format scoring remain open. | M6 batch trace collection |
| S073 | AvatarOptimizer | missing | L | L | 0.25 | <=2.6 | - | N | - | no Elixir equivalent | todo |
| S076 | BootstrapFewShotWithOptuna | missing | L | L | 0.25 | <=2.6 | S075 | N | - | no Elixir equivalent | todo |

## M7+ pool — not a milestone; cut later after scope decisions
Historical 3.4.0 pool. Removed upstream capabilities are recorded in the recount.

| id | symbol | status | V | E | introduced | old P |
|---|---|---|---|---|---|---|
| S047 | CodeExecutionError | missing | L | S | 3.3.0 | - |
| S048 | CodeInterpreter | missing | L | L | 3.2.0 | - |
| S049 | CodeInterpreterError | missing | L | S | 3.2.0 | - |
| S052 | FinalOutput | missing | L | S | 3.2.0 | - |
| S053 | LocalInterpreter | missing | L | L | 3.4.0 | - |
| S056 | PythonInterpreter | missing | M | L | <=2.6 | - |
| S057 | resolve_interpreter_factory | missing | L | S | 3.4.0 | - |
| S058 | SandboxSerializable | missing | L | M | 3.3.0 | - |
| S040 | RLM | missing | M | L | 3.2.0 | - |
| S045 | Flex | missing | M | L | 3.3.0 | - |
| U038 | AnthropicCompat | missing | L | M | 3.4.0 | - |
| U039 | ModelSupport | missing | L | S | 3.4.0 | - |
| U040 | OpenAIChatCompat | missing | L | M | 3.4.0 | - |
| U041 | OpenAIResponsesCompat | missing | L | M | 3.4.0 | - |
| U042 | ProviderDefinition | missing | L | L | 3.4.0 | - |
| U043 | RegisteredProvider | missing | L | M | 3.4.0 | - |
| U044 | RouterConfig | missing | L | M | 3.4.0 | - |
| U045 | register_provider | missing | L | M | 3.4.0 | - |
| U046 | registered_providers | missing | L | S | 3.4.0 | - |
| U047 | unregister_provider | missing | L | S | 3.4.0 | - |
| U001 | Colors | missing | L | S | <=2.6 | - |
| U004 | HotPotQA | missing | L | S | <=2.6 | - |
| U005 | MATH | missing | L | S | <=2.6 | - |
| U013 | Choice | missing | L | L | 3.4.0 | - |
| U014 | Citations | missing | M | M | 3.1.0 | - |
| U015 | Document | missing | L | M | 3.1.0 | - |
| U016 | Noul | missing | L | L | 3.4.0 | - |
| U017 | ReAnchor | missing | L | L | 3.4.0 | - |
| U018 | Score | missing | L | L | 3.4.0 | - |
| U027 | DummyLM | missing | L | M | <=2.6 | - |
| U028 | DummyVectorizer | missing | L | S | <=2.6 | - |
| U031 | download | missing | M | S | <=2.6 | - |
| U035 | pretty_print_history | partial | L | S | 3.0.0 | - |

## Old P-id mapping
P4→M2 (S113, S054) · P5→M2 (S054.f7) · P6→M6 (S035, S083) · P7→M2 (S077, S001) · P8→M3 (U026, U036) · P9 closed as upstream removed ProgramOfThought · P10→M4 (S019) · P11→M4 (+1 BAMLAdapter) · P12→M5 (S072, U022…) · P13→M3 (S025). The old section "Out of scope unless strategy changes" is **superseded**: BootstrapFinetune, Avatar and GEPA are now in M6; RLM and interpreters are in the M7+ pool.

## Hygiene (low priority, non-blocking)

| # | Slice | Status |
|---|---|---|
| H1 | Public-API snapshot guard for stable modules (complements S0) | todo |
| H2 | `Dspy.Adapters` characterization tests (from `plan/COVERAGE_AUDIT_2026-05.md`) | todo |
| H3 | Reconcile stale plan docs (RELEASE_MILESTONES R3, matrix typed-outputs row, STRATEGIC_ROADMAP upstream pin) | todo |
| H4 | OpenSpec `attach-raw-output-to-parse-failures`: archive after user-verification tasks 4.1/4.2 | todo |
| H5 | **`Dspy.Metrics.create_metric/2` swallows every error and every non-number into `0.0`** (`lib/dspy/metrics.ex:222-249`: `if is_number(score), do: score, else: 0.0` plus `rescue _ -> 0.0`). This is the exact pattern H0b-2 spent two slices removing from `run_metric`: a broken metric silently scores zero instead of surfacing as a failed example (D-U1) or `InvalidMetricResult` (Q2). **Must be done before M6**, when optimizers lean on composed metrics. Fix direction: let errors raise and non-numbers pass through, so Evaluate's H0b-2 semantics apply; a behaviour change for `create_metric` callers → public-entry tests + mutation proof + COMPATIBILITY note. Found in the M1-b contract review (F8, Greta 2026-09-28; booked on Horst's ruling). Size S | todo (before M6) |
| H6 | **`test/adapter_selection_test.exs` is `async: true` and calls global `Dspy.configure/1`** — a pre-existing flakiness hazard, deliberately left untouched during M1-a to honour "zero diff to existing tests" (A5.2). M1-a's own three new files were fixed to `async: false`; this one still races. Fix: `async: false`, or port it to process-scoped `Dspy.context/2`. Evidence: an unchanged tree produced 1, 85, 0 and 3 failures across four runs before the M1-a files were fixed | **done 2026-09-29 (H12)** — set to `async: false` (Horst ruling 2026-09-29, root-cause fix landed inside H12 because this test was the CAUSE of the H12 flake: its global `Dspy.configure(adapter: ...)` mutated the default adapter that H12's async fixture test relied on). 20× plain `mix test` = 20/20 clean. H7 (process-scoped `with_mock_lm/2`) remains the cleaner long-term home for this class of test. |
| H7 | **Test-side `with_mock_lm/2` helper** wrapping calls at the call site via process-scoped `Dspy.context/2`, so the `test/evaluate/*` files can go back to `async: true` and stop mutating global settings via `Dspy.configure/1`. Verified viable: `Evaluate` is one of the 13 sites wired in v0.3.44 (`lib/dspy/evaluate.ex:151` `Dspy.Context.capture/0`, `:161` `with_context/2`), so context **does** reach the per-item children — no lib change needed. Ilse's idea, booked rather than built mid-review. Would also close H6 cleanly. Size S | todo *(merged 2026-09-30: this item was booked twice, by Horst and by Ilse; the duplicate row was removed)* |
| H17 | Evaluation, the shared metric runner, and metric-consuming optimizers report unsupported arities before scoring. Trace-aware metrics remain H13. [Regression tests](../../test/teleprompt/metric_arity_test.exs) | Implemented |
| H18 | **Legacy `Dspy.Metrics.exact_match`/`f1_score` diverge from upstream AND are optimizer defaults.** No NFD normalisation, no article removal, and `[^\w\s]` **without the `u` flag strips every non-ASCII letter** — `"Straße"` → `"strae"`, i.e. a correctness bug for every non-English user. Also set-based F1 and both-empty → `1.0`. Upstream optimizers have no default metric at all. Changing these is a **behaviour change for optimizer users**, so it needs its own decision: switch the defaults to the M1-b functions, deprecate, or keep and document. Found in the M1-b contract review (F7, Greta/Nadja 2026-09-29). Size M | todo (needs a decision first) | *(renumbered from a duplicate H13, 2026-09-30 — the user decision package is `plan/research/decisions/2026-09-29-h13-legacy-metrics.md`, filed under the old id)*
| H19 | **Re-count the 150 against the shipped code — at the end of M1.** The dashboard figure (32/150) was measured 2026-09-26 and has not been re-measured through v0.4.0–v0.4.3. The lead had been quoting "~39" in chat as an estimate (+1 per slice), which is not a count. Re-run the inventory rows touched by M1 against the shipped code and the tests that pin them, apply the same done/partial rules, and publish a measured number. Also re-check every row marked **done**, since `dspy.inspect_history` (S028) turned out to be partial. Size S | todo — end of M1 |
| H20 | **Mechanical checks, stage 1: C2 — one shared mutation library** (Greta design `plan/research/2026-09-30-mechanical-checks.md`, ruled by Horst 2026-09-30). Each mutation **declares the tests it must kill**; verdicts `KILLED` / `SURVIVED-TARGET` (a claimed test passed) / `BLUNT` (failures outside the declared set) / `INVALID` (non-zero exit with no failing test named — which is exactly how the ENFILE outage produced two false kills). Reads a JSON test formatter, not console text. Built-in signal handlers, leftover pre-flight, base-green check, no disk state. **Why first:** three of M1-d's five blocking findings were rules already written in HOW_WE_WORK that did not transfer; the rules that never recur are the ones turned into tooling. C3a (every acceptance test claimed by some mutation) follows almost free. **Sequencing:** built before the M1-d fix round, which adopts it; older harnesses migrate when next touched. Later stages: C5 `deviations.json` per slice (required artifact), C1a ordered-text helpers refuse maps, C3b vacuous-assertion lint, C4 duplicate-code warning. Rejected as noisy: a map-order lint over `lib/`. Size M | **stage 1 (C2+C3a) done 2026-10-02 `5369372`** (Greta PASS after 2 blocks); later stages C5, C1a, C3b, C4 todo. **mutlib follow-ups (2026-10-03):** (a) reject an `also` name matching no test (H15 had 8); (b) build coverage from the base run's formatter records, not a source regex (`describe` names mismatch, M1-e); (c) a harness must declare its contract's mutation-ID list and fail when defined IDs differ (M1-e phase 2 shipped 17 mislabeled mutations of ~40; my 17/17 check did not catch it) |
| H8 | **O(n²) in `Dspy.Evaluate`: `Enum.at` inside index loops.** `finish_evaluation`'s `results` build and `rows_for/3` call `Enum.at(items, i)` inside an `Enum.with_index`/`Enum.map` over the testset — O(n²) on large testsets (each `Enum.at` walks from the start). Pure performance, no behaviour change; trivial to fix (zip or `Enum.split` once). Found in the M1-a fix-round-2 review (booked on Horst's "book only, not in this round" ruling, 2026-09-29). Size S | todo |
| H9 | ~~`failure_score` option unvalidated / `lookup_attr` metric-pair match~~ **SUPERSEDED by BB1 (2026-09-29):** the name-based routing (including the `is_number(in_key)` metric check) is deleted in the fix-round-3 brief, so the empty-cell path Ilse described no longer exists as code. The remaining real issue is split out as H10 (validate `failure_score` up front). No action here. | superseded |
| H10 | **Validate `failure_score` up front.** As shipped, `failure_score: :custom` (an atom) survives to the mean computation and raises `ArithmeticError` — AFTER all the LM calls, so a misconfigured option costs a whole expensive run. Rule (Horst, 2026-09-29): validate it is a number in `evaluate/4` so it raises `ArgumentError` BEFORE any LM call. One test (atom → `ArgumentError`, raised before the mock LM sees anything; number → behaves as today), mutation-proven. Size S | done (2026-11-21, PR #8) |
| H11 | **Two pre-existing crashes in the save path — contract violations, not M1-a bugs.** (a) A `%Prediction{}` built with `attrs: nil` → `BadMapError` in the save path; (b) a plain map returned from `forward` (instead of a `Dspy.Prediction`) → `KeyError`. Both break the documented module contract (`lib/dspy/module.ex:11` says `forward` returns `Dspy.Prediction.t()`), so they are user-contract violations — book with that note (fix = a friendly error at the contract boundary, or document + add a guard clause). Found in the M1-a fix-round-2 review, 2026-09-29. Size S | todo |
