# PARITY_QUEUE.md — ordered slice queue (single source of truth)

Regenerated 2026-09-28 by Greta **from the milestones approved by the user on 2026-09-28** (`plan/current/GAP_ANALYSIS_3.4.0.md` §Phase C v2; data: `plan/research/pi_handoffs/phaseB/inventory_final.csv`, column `milestone`). Loop + gates: `plan/SLICE_LOOP.md`, `plan/HOW_WE_WORK.md`.
Reference: Python DSPy 3.4.0 (`../dspy-3.4.0`). Ids S###/U### = inventory rows. Status: `todo` | `doing` | `done (date, tag)` | `blocked (why)`. Order inside a milestone: dependencies first, then score (value÷effort). Slicing into contracts happens when each milestone starts (Clarity Gate).

## Safety net + foundations
| # | Slice | Upstream | Effort | Status |
|---|---|---|---|---|
| S0 | Consumer contract tests `test/consumer_contract/` (14 items; 33 tests; `{:parse_failed,_}` not producible offline) | – | M | done (2026-09-26) |
| S0b | `scripts/consumer_canary.sh`: copy each consumer into gitignored `tmp/canary/`, swap dep to `path:` this checkout, `mix deps.get && mix compile --warnings-as-errors`; allowlist copy; warnings diffed vs baseline (WARN-BASELINE = pass) | – | M | done (2026-09-26) |

| # | Slice | Status |
|---|---|---|
| H0b-1 | Crash/timeout hardening, runtime sites (`openspec/changes/h0b-crash-hardening`) | doing |
| H0b-2 | Crash hardening Evaluate + `max_errors`/`failure_score` (D-U1/D-U2 = upstream, approved 2026-09-28) | todo (after H0b-1) |

## History (done before regeneration)
| # | Slice | Upstream | Effort | Status |
|---|---|---|---|---|
| P0 | `Dspy.context/2` process-scoped settings overrides (foundation for BestOfN/Parallel; `Dspy.Settings.get` consults overlay) | `dsp/utils/settings.py` context | S/M | done (2026-09-26, v0.3.40) |
| P1 | `Dspy.BestOfN` (uses P0; per-attempt temperature 1.0 + `rollout_id` in cache key; note `Dspy.Refine` today repeats identical calls, which collapse under `cache: true`) (N rollouts, reward fn, threshold, fail_count) | `predict/best_of_n.py` | S | done (2026-09-26, v0.3.41) |
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
| S044 | majority | missing | H | S | 3.00 | <=2.6 | - | N | - | No Dspy.majority; ensemble :majority_vote is a different teleprompter mechanism | todo |
| S031 | Evaluate | partial | H | S | 3.00 | <=2.6 | U008 | N | - | [reclassified done->partial] missing display_table/max_errors/failure_score/save_as_csv+js | todo |
| U010 | answer_exact_match | partial | H | S | 3.00 | <=2.6 | U011 U012 | N | - | add frac param + list-of-answers dispatch | todo |
| U011 | answer_passage_match | missing | M | S | 2.00 | <=2.6 | U012 | N | - | no Elixir equivalent | todo |
| U006 | CompleteAndGrounded | missing | M | M | 1.00 | <=2.6 | - | N | - | no Elixir equivalent | todo |
| U009 | SemanticF1 | missing | M | M | 1.00 | <=2.6 | - | N | - | no Elixir equivalent | todo |
| U012 | normalize_text | partial | L | S | 1.00 | <=2.6 | - | N | - | make public; upstream API is dspy.evaluate.normalize_text | todo |
| U003 | Dataset | missing | M | M | 1.00 | <=2.6 | U002 | N | - | No Dataset base (train/dev/test, shuffle_and_sample, prepare_by_seed, reset_seeds) | todo |
| U008 | EvaluationResult | missing | M | M | 1.00 | 3.1.0 | S031 | N (was Y; struct + Access keeps old reads, checked 2026-09-26) | - | struct with Access + all current keys | todo |
| U002 | DataLoader | missing | H | L | 0.75 | <=2.6 | DEP:datasets;DEP:pandas | N | - | No dataset loaders (from_huggingface/from_csv/from_json/from_pandas/from_rm) | todo |

## M2 — Programs you can save, inspect, reuse
After this you can …optimize a program once, save it, load it later or elsewhere and get the same behaviour, and see exactly which LM calls one program made.
- **Depends on:** M1 (BootstrapRS scores via Evaluate)
- **Exit example:** Compile with BootstrapRS, save, then load in a fresh process: the outputs are the same. `Module.inspect_history` shows only that program's calls.
- **Size:** 12 items, 15 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S002 | configure | partial | H | S | 3.00 | <=2.6 | - | N | - | [facet rule: done->partial] Parsimonious keys unported: rm/trace/num_threads/max_errors/ma | todo |
| S051 | Example | partial | H | S | 3.00 | <=2.6 | - | N | - | [facet rule: done->partial] labels/without/toDict-named variants: labels and without/2 mis | todo |
| S054 | Module | partial | H | S | 3.00 | <=2.6 | - | N | P5 (Module.inspect_history = facet S054.f7), P4 | [facet rule: done->partial] named_predictors/predictors/map_named_predictors, set_lm/get_l | todo |
| S055 | Prediction | partial | H | S | 3.00 | <=2.6 | S051 | N | - | [facet rule: done->partial] score float()/arithmetic/comparison ops and from_completions m | todo |
| S067 | Signature | partial | H | S | 3.00 | <=2.6 | - | N | - | [facet rule: done->partial] pydantic-model validation, annotated types, and field constrai | todo |
| S077 | BootstrapFewShotWithRandomSearch | missing | H | S | 3.00 | <=2.6 | S075 | N | P7 | no Elixir equivalent | todo |
| S060 | EmbeddingsWithScores | partial | M | S | 2.00 | 3.2.0 | S059 | N | - | No EmbeddingsWithScores class; closest: InMemoryRetriever Document.score (cosine) | todo |
| S038 | Predict | partial | H | M | 1.50 | <=2.6 | S033 | N | - | Missing **config (temperature/rollout_id), set_lm/get_lm, reset, dump/load_state, criteria | todo |
| S113 | load | partial | H | M | 1.50 | <=2.6 | S059 | N | P4 | No program-level load (upstream cloudpickle); only parameter-state JSON persistence; no ve | todo |
| S050 | Completions | partial | L | S | 1.00 | <=2.6 | S055 | N | - | No standalone Completions type: just a list on Prediction; from_completions, int-index, cr | todo |
| S021 | Embedder | partial | M | M | 1.00 | <=2.6 | S022 | N | - | provider behaviour exists but no Dspy.Embedder facade, no batch_size, no caching, no calla | todo |
| S004 | load_settings | missing | L | S | 1.00 | 3.2.0 | - | N | - | Dspy.Settings.save/load (upstream settings.py:266,299) not ported | todo |
| S001 | *also:* `BootstrapRS` alias (idiom today) moves with S077 | idiom | | | | | S077 | N | P7 | alias must point at real random search | todo |

## M3 — Production LM
After this you can …run against real providers robustly: clear error types, automatic retries, a cache that survives restarts, and hooks that trace every call.
- **Depends on:** M2 (LM state in save/load)
- **Exit example:** A fake provider returns 429 then 200: a typed error, then a retry. After a restart the cache hits. A callback module records module/LM/adapter start/end events.
- **Size:** 28 items, 37 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S090 | ContextWindowExceededError | missing | M | S | 2.00 | 3.2.0 | - | N | - | [reclassified na->missing] No detection/classification of context-window-exceeded response | todo |
| S096 | LMError | missing | M | S | 2.00 | 3.3.0 | S099 | N | - | [reclassified na->missing] Base LM exception absent; errors are {:error, atom/term} on the | todo |
| S012 | JSONAdapter | partial | H | M | 1.50 | <=2.6 | S005,S016 | N | - | output_contract in request map ≠ upstream response_format; no json_repair | todo |
| U026 | BaseCallback | partial | H | M | 1.50 | <=2.6 | U036 | N | P8 | Elixir behaviours cover adapter + tool events only; module/LM/evaluate/compile/interpreter | todo |
| U036 | with_callbacks | partial | H | M | 1.50 | <=2.6 | U026 | N | P8 | Functional equivalent exists (with_callbacks(callbacks, fun) + Settings :callbacks); event | todo |
| S025 | configure_cache | partial | H | M | 1.50 | 3.0.0 | S022 | N | P13 | only boolean Dspy.configure(cache:) exists; no disk cache, size limit, memory_max_entries, | todo |
| S110 | configure_dspy_loggers | missing | L | S | 1.00 | <=2.6 | - | N | - | No logger setup API; ad-hoc Logger.info/debug calls only (application.ex:41) | todo |
| S111 | disable_logging | missing | L | S | 1.00 | <=2.6 | S112 | N | - | No silencing toggle for event logs | todo |
| S112 | enable_logging | missing | L | S | 1.00 | <=2.6 | S111 | N | - | No enabling toggle for event logs | todo |
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
| S007 | ChatAdapter | partial | H | M | 1.50 | <=2.6 | S005,S015,S016 | N | - | no assistant tool_calls / tool-role history rendering; no fallback flag | todo |
| S011 | Image | missing | H | M | 1.50 | <=2.6 | S018 | N | - | no image input type; Attachments has image mime-types but file parts only | todo |
| S061 | Retrieve | partial | H | M | 1.50 | <=2.6 | S059;U032 | N | - | No dspy.Retrieve Parameter (k, callbacks) wrapping settings.rm; dspy.ex Dspy.Retrieve is a | todo |
| S043 | Refine | partial | H | M | 1.50 | 3.0.0 | S038 | N | - | No OfferFeedback advice loop; no temperature-1.0/rollout_id per attempt; no fail_count | todo |
| S042 | ReActV2 | missing | H | M | 1.50 | 3.3.0 | S041 | N | - | No Dspy.ReActV2; multi_tool_name/args batch execution unported | todo |
| U032 | dummy_rm | missing | L | S | 1.00 | <=2.6 | S061 | N | - | No dummy_rm stub retriever | todo |
| S006 | Audio | missing | M | M | 1.00 | 3.0.0 | S018 | N | - | no audio input type; Attachments is file-only, no base64/audio parts | todo |
| S019 | XMLAdapter | missing | M | M | 1.00 | 3.0.0 | S007 | N | P10 | no XML signature adapter; Dspy.Adapters.XMLAdapter.parse is an unimplemented stub | todo |
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
| U020 | StatusMessage | missing | M | S | 2.00 | 3.0.0 | S072 | N | - | no streaming message types at all | todo |
| U021 | StatusMessageProvider | missing | M | M | 1.00 | 3.0.0 | U020 S072 | N | - | no status provider behaviour; Dspy.Tools.Callback is a different (callback) shape | todo |
| U023 | StreamResponse | missing | L | S | 1.00 | 3.0.0 | S072 | N | - | no stream response struct | todo |
| S072 | streamify | missing | H | L | 0.75 | <=2.6 | S022 | N | P12 | no program-level streaming wrapper; only low-level ReqLLM.stream_text exists (integration  | todo |
| U022 | StreamListener | missing | H | L | 0.75 | 3.0.0 | U023 | N | P12 | no listener concept; find_predictor_for_stream_listeners has no counterpart | todo |
| U024 | apply_sync_streaming | missing | L | M | 0.50 | 3.0.0 | U020 S072 | N | - | no async-generator-to-sync bridge; Task.async_stream exists but is not dspy-streaming | todo |
| U025 | streaming_response | missing | L | M | 0.50 | 3.0.0 | U023 S072 | N | - | no streaming_response wrapper | todo |

## M6 — Optimizers+
After this you can …use the stronger optimizers: real GEPA, example selection by similarity (KNNFewShot), and the remaining upstream optimizers.
- **Depends on:** M1, M2, M3
- **Exit example:** GEPA improves a toy program's metric on DummyLM with a reflection LM. KNNFewShot selects demos by embedding.
- **Size:** 9 items, 28 effort pts

| id | symbol | status | V | E | score | introduced | deps | breaking | old P | gap | queue status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S035 | KNN | missing | M | M | 1.00 | <=2.6 | - | N | P6 | No Dspy.KNN; k/trainset/vectorizer + __call__ retrieval loop absent | todo |
| S083 | KNNFewShot | missing | M | M | 1.00 | <=2.6 | DEP:embedder S075 | N | P6 | no Elixir equivalent | todo |
| S082 | InferRules | missing | M | M | 1.00 | 3.0.0 | S031 | N | - | no Elixir equivalent | todo |
| S078 | BootstrapFinetune | missing | H | L | 0.75 | <=2.6 | - | N | - | no Elixir equivalent | todo |
| S081 | GEPA | missing | H | L | 0.75 | 3.0.0 | S031 | Y | - | [reclassified partial->missing] metric must become 5-arg (gold, pred, trace, pred_name, pr | todo |
| S074 | BetterTogether | missing | M | L | 0.50 | <=2.6 | - | N | - | no Elixir equivalent | todo |
| S087 | bootstrap_trace_data | missing | L | M | 0.50 | 3.1.0 | S031 | N | - | no Elixir equivalent | todo |
| S073 | AvatarOptimizer | missing | L | L | 0.25 | <=2.6 | - | N | - | no Elixir equivalent | todo |
| S076 | BootstrapFewShotWithOptuna | missing | L | L | 0.25 | <=2.6 | S075 | N | - | no Elixir equivalent | todo |

## M7+ pool — not a milestone; cut later after scope decisions
36 items, 83 pts. Includes P9 ProgramOfThought (sandbox decision) and the 3.3/3.4 surface.

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
| S034 | CodeAct | missing | M | L | 3.0.0 | - |
| S039 | ProgramOfThought | missing | H | L | <=2.6 | P9 |
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
| U019 | TypeSafe | missing | L | M | 3.4.0 | - |
| U027 | DummyLM | missing | L | M | <=2.6 | - |
| U028 | DummyVectorizer | missing | L | S | <=2.6 | - |
| U031 | download | missing | M | S | <=2.6 | - |
| U035 | pretty_print_history | partial | L | S | 3.0.0 | - |

## Old P-id mapping
P4→M2 (S113, S054) · P5→M2 (S054.f7) · P6→M6 (S035, S083) · P7→M2 (S077, S001) · P8→M3 (U026, U036) · P9→M7+ pool (S039) · P10→M4 (S019) · P11→M4 (+1 BAMLAdapter) · P12→M5 (S072, U022…) · P13→M3 (S025). The old section "Out of scope unless strategy changes" is **superseded**: BootstrapFinetune, Avatar and GEPA are now in M6; CodeAct/RLM/interpreters are in the M7+ pool.

## Hygiene (low priority, non-blocking)

| # | Slice | Status |
|---|---|---|
| H1 | Public-API snapshot guard for stable modules (complements S0) | todo |
| H2 | `Dspy.Adapters` characterization tests (from `plan/COVERAGE_AUDIT_2026-05.md`) | todo |
| H3 | Reconcile stale plan docs (RELEASE_MILESTONES R3, matrix typed-outputs row, STRATEGIC_ROADMAP upstream pin) | todo |
| H4 | OpenSpec `attach-raw-output-to-parse-failures`: archive after user-verification tasks 4.1/4.2 | todo |
