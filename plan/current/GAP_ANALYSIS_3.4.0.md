# GAP ANALYSIS — dspy.ex vs Python DSPy 3.4.0 (`2413b67a4d`)

Status: **v1 baseline, Greta 2026-09-26, awaiting Horst sample verification.** The denominator is frozen at **160** symbols; later finds are recorded as "added +n".
Method: PLAN.md §6. Step-0 script (`plan/research/pi_handoffs/phaseB/step0_symbols.py`) → 6 read-only scouts (B1–B6) → adversarial checker over all 61 done/idiom/na rows → Greta overrides. Raw data: `plan/research/pi_handoffs/phaseB/` (`all_symbols.csv`, `B1..B6.md`, `checker.md`, `inventory_final.csv`, which holds every column, refs and deps).

## Headline (revised in phase C, 2026-09-26)
| done | idiom | **done+idiom** | partial | missing | n/a |
|---|---|---|---|---|---|
| 13 | 19 | **32 / 150 in-scope (21%)** | 27 | 91 | 10 |

**Facets** (value-H done/partial symbols only): 24 done + 1 idiom out of 68 classified, which is **37%**. 4 facet rows could not be parsed.
Revision: five value-H symbols were marked "done" although their own facet rows show gaps. **configure, Example, Module, Prediction and Signature** are moved done→partial by the facet rule. The checker missed this, and so did the first version of this file. Per-area/per-release tables below are **v1** (before this revision; B1 −5 done). The authoritative per-row state is `inventory_final.csv`.

## Per area
| Area | total | done | idiom | partial | missing | n/a |
|---|---|---|---|---|---|---|
| B1 Top-level, settings, primitives, signatures, exceptions | 49 | 7 | 9 | 1 | 27 | 5 |
| B2 Predict modules | 14 | 4 | 1 | 2 | 7 | 0 |
| B3 Adapters & types | 15 | 0 | 4 | 5 | 6 | 0 |
| B4 LM clients, lm15, cache, streaming | 28 | 1 | 2 | 4 | 19 | 2 |
| B5 Evaluate & optimizers | 23 | 6 | 1 | 3 | 13 | 0 |
| B6 Retrievers, utils, datasets, experimental | 31 | 0 | 2 | 7 | 19 | 3 |

## Per DSPy release (where the symbol was introduced)
| Introduced in | total | done+idiom | partial | missing | n/a |
|---|---|---|---|---|---|
| <=2.6 | 79 | 28 | 15 | 29 | 7 |
| 3.0.0 | 25 | 6 | 6 | 12 | 1 |
| 3.1.0 | 7 | 1 | 0 | 5 | 1 |
| 3.2.0 | 7 | 0 | 1 | 6 | 0 |
| 3.3.0 | 22 | 2 | 0 | 19 | 1 |
| 3.4.0 | 20 | 0 | 0 | 20 | 0 |

We roughly cover 2.6-era DSPy. The 3.3 and 3.4 additions (typed LM errors, lm15, Flex, interpreters, experimental) are almost entirely missing.

## Per value
| Value | done+idiom | partial | missing |
|---|---|---|---|
| H | 9 | 8 | 0 |
| M | 18 | 9 | 7 |
| L | 10 | 5 | 84 |

## Corrections made during checking
- **Evaluate (S031): done→partial** (checker, confirmed). Missing: max_errors, failure_score, provide_traceback, save_as_csv/json, display_table, and the `EvaluationResult` struct (U008, a breaking change to the return shape). It is the rank-1 backlog item.
- **15 LM*Error rows: na→missing** (checker). A typed error classification is real functionality, not a Python-only mechanism. Greta additionally moved S094/S098/S103 (collector, lock, stream-assembly errors) to missing on the same rule.
- **GEPA (S081): partial→missing (Greta overrides the checker).** The port only searches a user-supplied instruction list. Reflective mutation with a feedback LM, the Pareto frontier and auto budget are all absent, so the name exists but not the capability. **breaking=Y**: the options and result shape change.
- The checker spot-checked 5 partial/missing rows and found none wrongly marked missing.

## n/a list (needs user approval, E5)
OldField, OldInputField, OldOutputField, infer_prefix (deprecated upstream shims); DSPyError (the base class; the Elixir error-tuple idiom — revisit together with the LM error family); disable/enable_litellm_logging (LiteLLM-only); asyncify, syncify (asyncio mechanics); `dspy.utils.experimental` (a decorator module).

## Ranked backlog (top 30, score = value÷effort, ties → earlier release)
| # | id | symbol | status | V | E | score | introduced | deps | gap |
|---|---|---|---|---|---|---|---|---|---|
| 1 | S031 | Evaluate | partial | H | S | 3.00 | <=2.6 | U008 | [reclassified done->partial] missing display_table/max_errors/failure_score/save |
| 2 | U010 | answer_exact_match | partial | M | S | 2.00 | <=2.6 | U011 U012 | add frac param + list-of-answers dispatch |
| 3 | S017 | TwoStepAdapter | partial | M | S | 2.00 | 3.0.0 | S005 | extraction LM/adapter from settings, not constructor; extractor is JSONAdapter n |
| 4 | S060 | EmbeddingsWithScores | partial | M | S | 2.00 | 3.2.0 | S059 | No EmbeddingsWithScores class; closest: InMemoryRetriever Document.score (cosine |
| 5 | S038 | Predict | partial | H | M | 1.50 | <=2.6 | S033 | Missing **config (temperature/rollout_id), set_lm/get_lm, reset, dump/load_state |
| 6 | S012 | JSONAdapter | partial | H | M | 1.50 | <=2.6 | S005,S016 | output_contract in request map ≠ upstream response_format; no json_repair |
| 7 | U026 | BaseCallback | partial | H | M | 1.50 | <=2.6 | U036 | Elixir behaviours cover adapter + tool events only; module/LM/evaluate/compile/i |
| 8 | U036 | with_callbacks | partial | H | M | 1.50 | <=2.6 | U026 | Functional equivalent exists (with_callbacks(callbacks, fun) + Settings :callbac |
| 9 | S025 | configure_cache | partial | H | M | 1.50 | 3.0.0 | S022 | only boolean Dspy.configure(cache:) exists; no disk cache, size limit, memory_ma |
| 10 | S050 | Completions | partial | L | S | 1.00 | <=2.6 | S055 | No standalone Completions type: just a list on Prediction; from_completions, int |
| 11 | S044 | majority | missing | L | S | 1.00 | <=2.6 | - | No Dspy.majority; ensemble :majority_vote is a different teleprompter mechanism |
| 12 | S007 | ChatAdapter | partial | M | M | 1.00 | <=2.6 | S005,S015,S016 | no assistant tool_calls / tool-role history rendering; no fallback flag |
| 13 | S011 | Image | missing | M | M | 1.00 | <=2.6 | S018 | no image input type; Attachments has image mime-types but file parts only |
| 14 | S021 | Embedder | partial | M | M | 1.00 | <=2.6 | S022 | provider behaviour exists but no Dspy.Embedder facade, no batch_size, no caching |
| 15 | S077 | BootstrapFewShotWithRandomSearch | missing | L | S | 1.00 | <=2.6 | S075 | no Elixir equivalent |
| 16 | U011 | answer_passage_match | missing | L | S | 1.00 | <=2.6 | U012 | no Elixir equivalent |
| 17 | U012 | normalize_text | partial | L | S | 1.00 | <=2.6 | - | make public; upstream API is dspy.evaluate.normalize_text |
| 18 | S061 | Retrieve | partial | M | M | 1.00 | <=2.6 | S059;U032 | No dspy.Retrieve Parameter (k, callbacks) wrapping settings.rm; dspy.ex Dspy.Ret |
| 19 | S110 | configure_dspy_loggers | missing | L | S | 1.00 | <=2.6 | - | No logger setup API; ad-hoc Logger.info/debug calls only (application.ex:41) |
| 20 | S111 | disable_logging | missing | L | S | 1.00 | <=2.6 | S112 | No silencing toggle for event logs |
| 21 | S112 | enable_logging | missing | L | S | 1.00 | <=2.6 | S111 | No enabling toggle for event logs |
| 22 | S113 | load | partial | M | M | 1.00 | <=2.6 | S059 | No program-level load (upstream cloudpickle); only parameter-state JSON persiste |
| 23 | U001 | Colors | missing | L | S | 1.00 | <=2.6 | - | No Colors dataset module/constants |
| 24 | U003 | Dataset | missing | M | M | 1.00 | <=2.6 | U002 | No Dataset base (train/dev/test, shuffle_and_sample, prepare_by_seed, reset_seed |
| 25 | U004 | HotPotQA | missing | L | S | 1.00 | <=2.6 | U003;DEP:datasets | No HotPotQA loader |
| 26 | U005 | MATH | missing | L | S | 1.00 | <=2.6 | U003;DEP:datasets | No MATH loader |
| 27 | U028 | DummyVectorizer | missing | L | S | 1.00 | <=2.6 | - | No DummyVectorizer |
| 28 | U031 | download | missing | L | S | 1.00 | <=2.6 | - | No URL download helper |
| 29 | U032 | dummy_rm | missing | L | S | 1.00 | <=2.6 | S061 | No dummy_rm stub retriever |
| 30 | S043 | Refine | partial | M | M | 1.00 | 3.0.0 | S038 | No OfferFeedback advice loop; no temperature-1.0/rollout_id per attempt; no fail |

Open total: 113 items, effort points 225 (S=1, M=2, L=4).

## Caveats (read before using the numbers)
1. **Value-rubric bias:** "H" requires current consumer use or the core path, so missing features can almost never be H. Flagships therefore rank low: streamify/StreamListener, ProgramOfThought, XMLAdapter, Reasoning. **Phase C must re-rate value for missing flagships using upstream docs prominence**; do not rank on the score alone.
2. Scout-judged values: ChainOfThought/ReAct are rated M. Arguably they are H (core path); this doesn't change their status (done).
3. Facets were done only for value-H done/partial rows (amendment). Value-M "done" rows (MIPROv2, COPRO, SIMBA, ReAct) are symbol-level judgements, so parameter gaps there may be understated.
4. One weak model (qwen3.8-27b) did all scouting. Confidence columns are in the CSV. Horst's 12-row sample is still pending.


## Phase C v1 — value re-rating + milestones (Greta draft 2026-09-26, NOT agreed)

### Value re-rating (fixes caveat 1)
The rule is mechanical and applies only to partial/missing rows (`phaseC` columns `docs_hits`, `docs_front` and `api_nav` in the CSV). It counts upstream `docs/` files outside `api/` that mention `dspy.<Sym>` or `Sym(`:
- **→H** if it appears in at least 2 front docs (getting-started / learn / index / cheatsheet) or in at least 8 docs files.
- **L→M** if it appears in at least 3 docs files, or is in the API nav with at least 1 docs file.

Result: **36 re-rated.** Examples: streamify, StreamListener, ProgramOfThought, Image, GEPA, BootstrapRS, BootstrapFinetune, majority, load and DataLoader go to **H**; XMLAdapter only reaches **M**, since it appears in 1 docs file. **Reasoning stays L** (0 docs hits), so my earlier guess for it was wrong. The open value mix is now H 24 / M 26 / L 63.

### Milestones (scripted assignment: `plan/research/pi_handoffs/phaseB/phaseC_milestones.py`, column `milestone`)
| M | Bundle — what a user can do afterwards | open items | value H/M/L | effort pts | depends on | breaking | exit example (runnable, DummyLM/fake provider, + canary green) |
|---|---|---|---|---|---|---|---|
| **M1** | **Evaluation you can trust**: Evaluate max_errors/failure_score/provide_traceback/save_as_csv/json/display_table + EvaluationResult; metrics answer_exact_match(frac, lists), answer_passage_match, normalize_text, majority, SemanticF1, CompleteAndGrounded; Dataset/DataLoader (local CSV/JSON only) | 10 | 4/5/1 | 17 | **H0b-2** (Evaluate crash semantics, D-U1/D-U2) | EvaluationResult | load a CSV with DataLoader → evaluate a CoT program with SemanticF1, max_errors=2, one failing example → failure_score shown, result struct, JSON saved |
| **M2** | **Programs you can save, inspect, reuse**: Module named_predictors/set_lm/get_lm/batch/**inspect_history (= queue P5)**/dump_state/load_state/save/load (P4); Predict config/reset; Example/Prediction/Signature/configure facet gaps; load_settings; BootstrapRS (P7); Embedder/Embeddings facade | 12 | 8/2/2 | 15 | M1 (BootstrapRS scores via Evaluate) | – | compile with BootstrapRS → save → load in a fresh process → same outputs; `Module.inspect_history` shows only that program's calls |
| **M3** | **Production LM**: typed LM error family + is_retryable + num_retries; LM facets (copy, dump/load_state, capabilities); configure_cache disk/size (P13); full callbacks BaseCallback/with_callbacks (P8); JSONAdapter response_format/repair; logging toggles | 28 | 5/2/21 | 37 | M2 (LM state in save/load) | – | fake provider returns 429 then 200 → typed error + retry; restart → cache hit; a callback module records module/LM/adapter start/end events |
| **M4** | **Agents & multimodal**: Adapter options; ChatAdapter tool-call history; Image/Audio/Code/Type/ToolCallResults; TwoStepAdapter ctor; Refine feedback loop; ReActV2; XMLAdapter (P10); Reasoning; Retrieve/Embeddings/ColBERTv2 | 16 | 7/5/4 | 34 | M3 (typed errors, callbacks) | ColBERTv2 | ReAct agent with a tool + image input via ChatAdapter, one Refine round with feedback |
| **M5** | **Streaming** (P12): streamify, StreamListener, StreamResponse, StatusMessage(+Provider), streaming_response | 7 | 2/2/3 | 16 | M3 callbacks (status messages), M4 adapters | – | stream a field's tokens + status messages from a CoT program (LiveView-consumable) |
| **M6** | **Optimizers+**: real GEPA (reflection LM, Pareto), KNN + KNNFewShot (P6), BootstrapFinetune, InferRules, BetterTogether, AvatarOptimizer, Optuna | 9 | 2/4/3 | 28 | M1, M2, M3; Optuna = DEP → likely n/a | GEPA | GEPA improves a toy program's metric on DummyLM with a reflection LM; KNNFewShot selects demos by embedding |
| **M7** | **3.3/3.4 surface + code execution** (scope decisions first): interpreters/ProgramOfThought/CodeAct/RLM (P9, sandbox decision), lm15 provider registry, Flex, experimental types, HF datasets, DummyLM/pretty_print_history | 36 | 1/6/29 | 83 | sandbox decision; M3 | – | per sub-bundle, defined when scoped |

Total open: 118 items (`missing`+`partial`), 230 effort points.
The order follows dependencies first, then value÷effort. M1+M2 take 32 points and cover 12 of the 24 open value-H items, which is the cheap, high-value core. Almost all 3.4-only items sit in M7, consistent with "3.4.0 parity is the endpoint".

### Breaking items — one batch for the user now (E14)
1. **EvaluationResult** (M1): `Evaluate` returns a struct instead of today's shape. A compatible path, where the struct keeps the old keys and the old shape is deprecated for 1 minor version, needs checking against the consumer_contract tests.
2. **GEPA** (M6): options and result shape change (today: a user-supplied `candidates` list).
3. **ColBERTv2** (M4): the constructor/return shape changes.

### Out-of-denominator finds ("added +n", E3)
- **+1 BAMLAdapter** (`dspy/adapters/baml_adapter.py:174`): public class, but not exported in `__all__`, so step 0 missed it. The queue has it as P11. Proposal: count it as added +1 (M4).

### PARITY_QUEUE reconciliation
The queue should be regenerated from milestones once M1..M7 are agreed. Mapping of today's open items:
- P4 save/load → M2 (S113 + S054 facets)
- **P5 → M2 as Module facet S054.f7.** The inventory's S028 `dspy.inspect_history` (global) is correctly done. The B1 facet f7 wrongly credited the global function to Module, so Module is now partial.
- P6 → M6
- P7 → M2
- P8 → M3
- P9 → M7 (sandbox decision)
- P10 → M4
- P11 → M4 (+1)
- P12 → M5
- P13 → M3

## Full inventory (refs truncated; full columns in the CSV)
| id | area | symbol | status | V | E | introduced | score | breaking | dspy.ex ref | gap |
|---|---|---|---|---|---|---|---|---|---|---|
| S001 | B1 | BootstrapRS | idiom | M | S | <=2.6 |  | N | lib/dspy/teleprompt/bootstrap_few_shot.ex:346 | No separate BootstrapRS class/alias; random-search behavior (candidate sets, random demo counts, metric_thresh |
| S002 | B1 | configure | done | H | S | <=2.6 |  | N | lib/dspy.ex:88 | Parsimonious keys unported: rm/trace/num_threads/max_errors/max_history_size/async_max_workers/stream keys (se |
| S003 | B1 | context | done | M | S | <=2.6 |  | N | lib/dspy.ex:126 | No cross-Task propagation (documented); helper Dspy.Context.with_context/2 (lib/dspy/context.ex:132) covers it |
| S004 | B1 | load_settings | missing | L | S | 3.2.0 | 1.00 | N | - | Dspy.Settings.save/load (upstream settings.py:266,299) not ported |
| S030 | B1 | settings | idiom | H | S | <=2.6 |  | N | lib/dspy/settings.ex:74 | Attribute-style mutation (dspy.settings.lm = x) has no Elixir analog; reads via Settings.get/0,1 + context ove |
| S046 | B1 | BaseModule | idiom | L | S | <=2.6 |  | N | lib/dspy/module.ex:1 | Python class hierarchy (BaseModule→Module) collapsed into Elixir behaviour; named_parameters→parameters callba |
| S047 | B1 | CodeExecutionError | missing | L | S | 3.3.0 | 1.00 | N | - | Interpreter error class (code_interpreter.py:34) missing with whole code-execution subsystem |
| S048 | B1 | CodeInterpreter | missing | L | L | 3.2.0 | 0.25 | N | - | CodeInterpreter protocol (code_interpreter.py:58: start/execute/shutdown/tools) not ported |
| S049 | B1 | CodeInterpreterError | missing | L | S | 3.2.0 | 1.00 | N | - | Interpreter error base class (code_interpreter.py:24) missing |
| S050 | B1 | Completions | partial | L | S | <=2.6 | 1.00 | N | lib/dspy/prediction.ex:161 | No standalone Completions type: just a list on Prediction; from_completions, int-index, cross-key length check |
| S051 | B1 | Example | done | H | S | <=2.6 |  | N | lib/dspy/example.ex:32 | labels/without/toDict-named variants: labels and without/2 missing; to_map covers toDict |
| S052 | B1 | FinalOutput | missing | L | S | 3.2.0 | 1.00 | N | - | FinalOutput sentinel (code_interpreter.py:38) missing |
| S053 | B1 | LocalInterpreter | missing | L | L | 3.4.0 | 0.25 | N | - | LocalInterpreter (local_interpreter.py:47, subprocess JSON-RPC Python kernel) not ported |
| S054 | B1 | Module | done | H | S | <=2.6 |  | N | lib/dspy/module.ex:50 | named_predictors/predictors/map_named_predictors, set_lm/get_lm, __getattr__ delegation missing (global settin |
| S055 | B1 | Prediction | done | H | S | <=2.6 |  | N | lib/dspy/prediction.ex:37 | score float()/arithmetic/comparison ops and from_completions missing; container + completions + lm_usage prese |
| S056 | B1 | PythonInterpreter | missing | L | L | <=2.6 | 0.25 | N | - | PythonInterpreter (python_interpreter.py, deno subprocess JSON-RPC) not ported |
| S057 | B1 | resolve_interpreter_factory | missing | L | S | 3.4.0 | 1.00 | N | - | Interpreter factory resolution (code_interpreter.py:172) missing |
| S058 | B1 | SandboxSerializable | missing | L | M | 3.3.0 | 0.50 | N | - | RLM sandbox-serializable ABC (sandbox_serializable.py:41, dill-based to_sandbox/rlm_preview) not ported |
| S062 | B1 | InputField | idiom | H | S | <=2.6 |  | N | lib/dspy/signature/dsl.ex:36 | input_field/4 macro (name/type/desc/required/default/one_of/schema); pydantic constraint kwargs have no analog |
| S063 | B1 | OldField | na | L | S | <=2.6 |  | N | - | Deprecated legacy field datatype (field.py:97) for old class-based signatures; DSL replaces it; keep as charac |
| S064 | B1 | OldInputField | na | L | S | <=2.6 |  | N | - | Deprecated legacy (field.py:120); Elixir-native DSL is the replacement shape |
| S065 | B1 | OldOutputField | na | L | S | <=2.6 |  | N | - | Deprecated legacy (field.py:125); Elixir-native DSL is the replacement shape |
| S066 | B1 | OutputField | idiom | H | S | <=2.6 |  | N | lib/dspy/signature/dsl.ex:57 | output_field/4 macro incl. :schema for typed outputs; pydantic-only constraints N/A (prefix deprecated upstrea |
| S067 | B1 | Signature | done | H | S | <=2.6 |  | N | lib/dspy/signature.ex:40 | pydantic-model validation, annotated types, and field constraints not available; core typed fields + parse/val |
| S068 | B1 | SignatureMeta | idiom | L | S | <=2.6 |  | N | lib/dspy/signature/dsl.ex:86 | class-based string signatures via metaclass (signature.py:41) replaced by `use Dspy.Signature` + field macros |
| S069 | B1 | ensure_signature | idiom | L | L | <=2.6 |  | N | lib/dspy/signature.ex:66 | No single public ensure_signature/1; string normalization folded into Signature.define/1 and Predict.get_signa |
| S070 | B1 | infer_prefix | na | L | S | <=2.6 |  | N | - | Deprecated: prefix arg deprecated and no-effect upstream (field.py _DEPRECATED_FIELD_ARGS); nothing to port |
| S071 | B1 | make_signature | done | L | S | <=2.6 |  | N | lib/dspy/signature.ex:66 | Supports 'f(in: t, ...) -> out: t' and arrow forms; upstream _parse_field_string type nodes (list[X], annotate |
| S089 | B1 | AdapterParseError | idiom | L | S | 3.3.0 |  | N | lib/dspy/signature/adapter/pipeline.ex:308 | No exception; parse failures surface as error tuples ({:output_decode_failed/:output_validation_failed}) + ret |
| S090 | B1 | ContextWindowExceededError | missing | L | S | 3.2.0 | 1.00 | N | - | [reclassified na->missing] No detection/classification of context-window-exceeded responses (e.g. 413/insuffic |
| S091 | B1 | DSPyError | na | L | S | 3.3.0 |  | N | - | No exception hierarchy; dspy.ex returns {:error, term} tuples (see lm.ex:253, pipeline.ex:308) |
| S092 | B1 | LMAuthError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Auth failures (401/403) not classified; req_llm {:error, term} propagates unclassif |
| S093 | B1 | LMBillingError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Billing failures not classified in port |
| S094 | B1 | LMCollectionLimitError | missing | L | S | 3.4.0 | 1.00 | N | - | [reclassified na->missing] Collector budget errors belong to 3.4.0 LM collector, not present in dspy.ex |
| S095 | B1 | LMConfigurationError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Misconfiguration detected at LM construction (ArgumentError); no runtime configurat |
| S096 | B1 | LMError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Base LM exception absent; errors are {:error, atom/term} on the LM path |
| S097 | B1 | LMInvalidRequestError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] 400-class provider errors not classified in port |
| S098 | B1 | LMLockTimeoutError | missing | L | S | 3.4.0 | 1.00 | N | - | [reclassified na->missing] Credential lock contention (Python threading/file lock) has no Elixir analog in por |
| S099 | B1 | LMNotConfiguredError | idiom | L | L | 3.3.0 |  | N | lib/dspy/lm.ex:253 | No exception; unconfigured LM returns {:error, :no_lm_configured}; no dedicated test |
| S100 | B1 | LMProviderError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Provider 5xx/generic errors not classified; req_llm term propagates |
| S101 | B1 | LMRateLimitError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Rate-limit (429) classification/retry policy absent |
| S102 | B1 | LMServerError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Server (5xx) errors not classified in port |
| S103 | B1 | LMStreamAssemblyError | missing | L | S | 3.4.0 | 1.00 | N | - | [reclassified na->missing] Streaming/assembly errors belong to 3.4.0 streaming LM, not present in dspy.ex |
| S104 | B1 | LMTimeoutError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Timeout classification absent; req/finch errors propagate |
| S105 | B1 | LMTransportError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Network/DNS/TLS errors not classified in port |
| S106 | B1 | LMUnexpectedError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] No catch-all exception class; unexpected errors propagate as raw terms |
| S107 | B1 | LMUnsupportedFeatureError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Unsupported-feature (e.g. tools on a provider) classification absent |
| S108 | B1 | LMUnsupportedModelError | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] Unsupported model → {:error, :invalid_model} at LM.new; no runtime exception |
| S109 | B1 | is_retryable_lm_error | missing | L | S | 3.3.0 | 1.00 | N | - | [reclassified na->missing] No LM-error retryability classifier; retry applies to output decode/validation tupl |
| S032 | B2 | BestOfN | done | L | - | 3.0.0 |  | N | lib/dspy/best_of_n.ex:1 | None: n/threshold/reward_fn/fail_count/rollout ids all ported and tested |
| S033 | B2 | ChainOfThought | done | M | - | <=2.6 |  | N | lib/dspy/chain_of_thought.ex:1 | Custom rationale_field desc/type unsupported; only :reasoning_field atom name |
| S034 | B2 | CodeAct | missing | L | L | 3.0.0 | 0.25 | N | - | No module; inherits ReAct+ProgramOfThought+CodeInterpreter |
| S035 | B2 | KNN | missing | L | M | <=2.6 | 0.50 | N | - | No Dspy.KNN; k/trainset/vectorizer + __call__ retrieval loop absent |
| S036 | B2 | MultiChainComparison | done | L | - | <=2.6 |  | N | lib/dspy/multi_chain_comparison.ex:1 | None material: M/temperature/attempt formatting/mismatch error all ported + tested |
| S037 | B2 | Parallel | idiom | M | - | <=2.6 |  | N | lib/dspy/parallel.ex:1 | Executor struct not Dspy.Module; no progress bar/provide_traceback/straggler_limit |
| S038 | B2 | Predict | partial | H | M | <=2.6 | 1.50 | N | lib/dspy/predict.ex:1 | Missing **config (temperature/rollout_id), set_lm/get_lm, reset, dump/load_state, criteria |
| S039 | B2 | ProgramOfThought | missing | M | L | <=2.6 | 0.50 | N | - | No Dspy.ProgramOfThought; code/code_error/code_outputs + interpreter loop absent |
| S040 | B2 | RLM | missing | L | L | 3.2.0 | 0.25 | N | - | No Dspy.RLM; recursive agent + CodeInterpreter factory unported |
| S041 | B2 | ReAct | done | M | - | <=2.6 |  | N | lib/dspy/react.ex:1 | Tools must be %Dspy.Tools.Tool{} (no fn auto-wrap); no per-call max_iters; no traj truncation |
| S042 | B2 | ReActV2 | missing | L | M | 3.3.0 | 0.50 | N | - | No Dspy.ReActV2; multi_tool_name/args batch execution unported |
| S043 | B2 | Refine | partial | M | M | 3.0.0 | 1.00 | N | lib/dspy/refine.ex:1 | No OfferFeedback advice loop; no temperature-1.0/rollout_id per attempt; no fail_count |
| S044 | B2 | majority | missing | L | S | <=2.6 | 1.00 | N | - | No Dspy.majority; ensemble :majority_vote is a different teleprompter mechanism |
| S045 | B2 | Flex | missing | L | L | 3.3.0 | 0.25 | N | - | No Dspy.Flex; program-code generation/dump_state surface unported |
| S005 | B3 | Adapter | partial | H | L | <=2.6 | 0.75 | N | lib/dspy/signature/adapter.ex:1, lib/dspy/sig | class pipeline options + native-response-type planning missing |
| S006 | B3 | Audio | missing | L | M | 3.0.0 | 0.50 | N | - | no audio input type; Attachments is file-only, no base64/audio parts |
| S007 | B3 | ChatAdapter | partial | M | M | <=2.6 | 1.00 | N | lib/dspy/signature/adapters/chat.ex:1 | no assistant tool_calls / tool-role history rendering; no fallback flag |
| S008 | B3 | Code | partial | L | S | 3.0.0 | 1.00 | N | lib/dspy/signature.ex:914 (:code type) | untested :code field type; no language param; not a content-part Type |
| S009 | B3 | File | idiom | M | M | 3.1.0 |  | N | lib/dspy/attachments.ex:1, lib/dspy/signature | Dspy.Attachments (path-based input_file parts) ≠ per-field dspy.File type |
| S010 | B3 | History | idiom | M | S | 3.0.0 |  | N | lib/dspy/history.ex:1 | :history field type + struct; no tool-call/result turns in history |
| S011 | B3 | Image | missing | M | M | <=2.6 | 1.00 | N | - | no image input type; Attachments has image mime-types but file parts only |
| S012 | B3 | JSONAdapter | partial | H | M | <=2.6 | 1.50 | N | lib/dspy/signature/adapters/json.ex:1 | output_contract in request map ≠ upstream response_format; no json_repair |
| S013 | B3 | Reasoning | missing | L | M | 3.1.0 | 0.50 | N | - | no dspy.Reasoning type; CoT :reasoning field and LM reasoning_effort opt exist but are separate concepts |
| S014 | B3 | Tool | idiom | M | S | <=2.6 |  | N | lib/dspy/tools.ex:16 (Dspy.Tools.Tool), lib/d | struct+registry + :tools input value instead of field annotation; MCP/langchain N/A |
| S015 | B3 | ToolCallResults | missing | L | S | 3.3.0 | 1.00 | N | - | no way to pass tool results back through history |
| S016 | B3 | ToolCalls | idiom | L | S | 3.0.0 |  | N | lib/dspy/signature/ex:1 is wrong; see lib/dsp | :tool_calls output field + provider tool_calls→list-of-maps; no ToolCalls struct |
| S017 | B3 | TwoStepAdapter | partial | M | S | 3.0.0 | 2.00 | N | lib/dspy/signature/adapters/two_step.ex:1 | extraction LM/adapter from settings, not constructor; extractor is JSONAdapter not chat |
| S018 | B3 | Type | missing | L | L | 3.0.0 | 0.25 | N | - | no custom-type framework; Dspy.TypedOutputs JSON schemas cover output-side only |
| S019 | B3 | XMLAdapter | missing | L | M | 3.0.0 | 0.50 | N | - (home-grown Dspy.Adapters.XMLAdapter at lib | no XML signature adapter; Dspy.Adapters.XMLAdapter.parse is an unimplemented stub |
| S020 | B4 | BaseLM | idiom | M | M | <=2.6 |  | N | lib/dspy/lm.ex:239 | Elixir behaviour Dspy.LM (generate/2, supports?/2) replaces base class; no shared struct, no kwargs merge/copy |
| S021 | B4 | Embedder | partial | M | M | <=2.6 | 1.00 | N | lib/dspy/retrieve/embeddings/req_llm.ex:26 | provider behaviour exists but no Dspy.Embedder facade, no batch_size, no caching, no callable-model support, l |
| S022 | B4 | LM | partial | H | L | <=2.6 | 0.75 | N | lib/dspy/lm.ex:72 | Dspy.LM.new+ReqLLM covers model/temperature/max_tokens; missing cache/call/callbacks/num_retries opts, copy, d |
| S023 | B4 | Provider | missing | L | M | <=2.6 | 0.50 | N | - | no provider base (finetunable/reinforceable/launch/kill/finetune/is_provider_model) anywhere in lib/ |
| S024 | B4 | TrainingJob | missing | L | M | <=2.6 | 0.50 | N | - | no fine-tuning job type; concurrent.futures.Future has no dspy.ex counterpart |
| S025 | B4 | configure_cache | partial | H | M | 3.0.0 | 1.50 | N | lib/dspy/lm/cache.ex:9 | only boolean Dspy.configure(cache:) exists; no disk cache, size limit, memory_max_entries, restrict_pickle/saf |
| S026 | B4 | disable_litellm_logging | na | L | S | <=2.6 |  | N | - | dspy.ex has no LiteLLM dependency (HTTP via req_llm); Elixir Logger owns levels |
| S027 | B4 | enable_litellm_logging | na | L | S | <=2.6 |  | N | - | same as S026: LiteLLM does not exist in the Elixir port |
| S028 | B4 | inspect_history | done | M | S | <=2.6 |  | N | lib/dspy.ex:170 | Dspy.inspect_history/1 + history/1 over global History GenServer (simpler than Python: no per-LM history) |
| S029 | B4 | ColBERTv2 | partial | L | L | <=2.6 | 0.25 | Y | lib/dspy/retrieve.ex:239 | deliberate stub returning {:error}; v2 GET/POST request functions and ColBERTv2RetrieverLocal/RerankerLocal un |
| S072 | B4 | streamify | missing | M | L | <=2.6 | 0.50 | N | - | no program-level streaming wrapper; only low-level ReqLLM.stream_text exists (integration test only) |
| U020 | B4 | StatusMessage | missing | L | S | 3.0.0 | 1.00 | N | - | no streaming message types at all |
| U021 | B4 | StatusMessageProvider | missing | L | M | 3.0.0 | 0.50 | N | - | no status provider behaviour; Dspy.Tools.Callback is a different (callback) shape |
| U022 | B4 | StreamListener | missing | L | L | 3.0.0 | 0.25 | N | - | no listener concept; find_predictor_for_stream_listeners has no counterpart |
| U023 | B4 | StreamResponse | missing | L | S | 3.0.0 | 1.00 | N | - | no stream response struct |
| U024 | B4 | apply_sync_streaming | missing | L | M | 3.0.0 | 0.50 | N | - | no async-generator-to-sync bridge; Task.async_stream exists but is not dspy-streaming |
| U025 | B4 | streaming_response | missing | L | M | 3.0.0 | 0.50 | N | - | no streaming_response wrapper |
| U037 | B4 | cache | idiom | M | S | <=2.6 |  | N | lib/dspy/lm/cache.ex:59 | lazy global ETS :dspy_lm_cache (ensure_table!) replaces lazy dspy.cache singleton; no exposed Cache object |
| U038 | B4 | AnthropicCompat | missing | L | M | 3.4.0 | 0.50 | N | - | no lm15 equivalent; Anthropic wire handled inside req_llm (DEP:req_llm) |
| U039 | B4 | ModelSupport | missing | L | S | 3.4.0 | 1.00 | N | - | no caller-declared model capability statements (function_calling/reasoning/response_schema) |
| U040 | B4 | OpenAIChatCompat | missing | L | M | 3.4.0 | 0.50 | N | - | no chat-wire compat policy type; req_llm owns OpenAI chat wire |
| U041 | B4 | OpenAIResponsesCompat | missing | L | M | 3.4.0 | 0.50 | N | - | no responses-API wire compat policy |
| U042 | B4 | ProviderDefinition | missing | L | L | 3.4.0 | 0.25 | N | - | no provider definition type; provider routing is the "provider:model" string passed to req_llm |
| U043 | B4 | RegisteredProvider | missing | L | M | 3.4.0 | 0.50 | N | - | no registered-provider binding struct |
| U044 | B4 | RouterConfig | missing | L | M | 3.4.0 | 0.50 | N | - | no router config; route = model-string prefix in req_llm |
| U045 | B4 | register_provider | missing | L | M | 3.4.0 | 0.50 | N | - | no custom provider registration; would need req_llm-level provider hooks (DEP:req_llm) |
| U046 | B4 | registered_providers | missing | L | S | 3.4.0 | 1.00 | N | - | no registry read API |
| U047 | B4 | unregister_provider | missing | L | S | 3.4.0 | 1.00 | N | - | no registry removal API |
| S031 | B5 | Evaluate | partial | H | S | <=2.6 | 3.00 | N | lib/dspy/evaluate.ex:88 | [reclassified done->partial] missing display_table/max_errors/failure_score/save_as_csv+json; returns map not  |
| S073 | B5 | AvatarOptimizer | missing | L | L | <=2.6 | 0.25 | N | - | no Elixir equivalent |
| S074 | B5 | BetterTogether | missing | L | L | <=2.6 | 0.25 | N | - | no Elixir equivalent |
| S075 | B5 | BootstrapFewShot | done | M | S | <=2.6 |  | N | lib/dspy/teleprompt/bootstrap_few_shot.ex:93 | missing teacher_settings/use_full_trace/bootstrap_trace_name; rollout temp=1.0 behavior not verified |
| S076 | B5 | BootstrapFewShotWithOptuna | missing | L | L | <=2.6 | 0.25 | N | - | no Elixir equivalent |
| S077 | B5 | BootstrapFewShotWithRandomSearch | missing | L | S | <=2.6 | 1.00 | N | - | no Elixir equivalent |
| S078 | B5 | BootstrapFinetune | missing | L | L | <=2.6 | 0.25 | N | - | no Elixir equivalent |
| S079 | B5 | COPRO | done | M | S | <=2.6 |  | N | lib/dspy/teleprompt/copro.ex:92 | missing max_bootstrapped/labeled_demos knobs and use_full_trace |
| S080 | B5 | Ensemble | done | M | S | <=2.6 |  | N | lib/dspy/teleprompt/ensemble.ex:251 | no reduce_fn/deterministic flags; own richer design |
| S081 | B5 | GEPA | missing | M | L | 3.0.0 | 0.50 | Y | lib/dspy/teleprompt/gepa.ex:25 | [reclassified partial->missing] metric must become 5-arg (gold, pred, trace, pred_name, pred_trace); no reflec |
| S082 | B5 | InferRules | missing | L | M | 3.0.0 | 0.50 | N | - | no Elixir equivalent |
| S083 | B5 | KNNFewShot | missing | L | M | <=2.6 | 0.50 | N | - | no Elixir equivalent |
| S084 | B5 | LabeledFewShot | done | M | S | <=2.6 |  | N | lib/dspy/teleprompt/labeled_few_shot.ex:61 | metric optional vs upstream positional k only; trivial |
| S085 | B5 | MIPROv2 | done | M | M | <=2.6 |  | N | lib/dspy/teleprompt/mipro_v2.ex:111 | missing teacher_settings/metric_threshold/log_dir/track_stats; seed default differs (time vs 9) |
| S086 | B5 | SIMBA | done | M | S | 3.0.0 |  | N | lib/dspy/teleprompt/simba.ex:57 | missing prompt_model/teacher_settings params; reads global LM instead |
| S087 | B5 | bootstrap_trace_data | missing | L | M | 3.1.0 | 0.50 | N | - | no Elixir equivalent |
| U006 | B5 | CompleteAndGrounded | missing | L | M | <=2.6 | 0.50 | N | - | no Elixir equivalent |
| U007 | B5 | EM | idiom | M | S | <=2.6 |  | N | lib/dspy/metrics.ex:51 | no list-of-answers form; returns float not bool |
| U008 | B5 | EvaluationResult | missing | M | M | 3.1.0 | 1.00 | Y | - | evaluate/4 returns plain map; struct would change teleprompters/tests reading .mean |
| U009 | B5 | SemanticF1 | missing | L | M | <=2.6 | 0.50 | N | - | no Elixir equivalent |
| U010 | B5 | answer_exact_match | partial | M | S | <=2.6 | 2.00 | N | lib/dspy/metrics.ex:51 | add frac param + list-of-answers dispatch |
| U011 | B5 | answer_passage_match | missing | L | S | <=2.6 | 1.00 | N | - | no Elixir equivalent |
| U012 | B5 | normalize_text | partial | L | S | <=2.6 | 1.00 | N | lib/dspy/metrics.ex:307 | make public; upstream API is dspy.evaluate.normalize_text |
| S059 | B6 | Embeddings | partial | M | M | 3.0.0 | 1.00 | N | lib/dspy/retrieve/in_memory_retriever.ex:1 | No corpus Embeddings retriever (embed(corpus), k, normalize, save/load/from_saved, FAISS fallback) |
| S060 | B6 | EmbeddingsWithScores | partial | M | S | 3.2.0 | 2.00 | N | lib/dspy/retrieve/in_memory_retriever.ex:125 | No EmbeddingsWithScores class; closest: InMemoryRetriever Document.score (cosine) |
| S061 | B6 | Retrieve | partial | M | M | <=2.6 | 1.00 | N | lib/dspy/retrieve.ex:1 | No dspy.Retrieve Parameter (k, callbacks) wrapping settings.rm; dspy.ex Dspy.Retrieve is a differently shaped  |
| S088 | B6 | asyncify | na | L | - | <=2.6 |  | N | - | Python anyio thread-pool wrapper; Elixir calls are sync in-process; Task + Dspy.context cover concurrency |
| S110 | B6 | configure_dspy_loggers | missing | L | S | <=2.6 | 1.00 | N | - | No logger setup API; ad-hoc Logger.info/debug calls only (application.ex:41) |
| S111 | B6 | disable_logging | missing | L | S | <=2.6 | 1.00 | N | - | No silencing toggle for event logs |
| S112 | B6 | enable_logging | missing | L | S | <=2.6 | 1.00 | N | - | No enabling toggle for event logs |
| S113 | B6 | load | partial | M | M | <=2.6 | 1.00 | N | lib/dspy/parameter.ex:101 | No program-level load (upstream cloudpickle); only parameter-state JSON persistence; no version-mismatch warni |
| S114 | B6 | syncify | na | L | - | 3.0.0 |  | N | - | Elixir programs are already synchronous in-process; no event loop to bridge |
| S115 | B6 | track_usage | idiom | H | - | 3.0.0 |  | N | lib/dspy/lm/usage_acc.ex:1 | Elixir-native shape: :track_usage setting + UsageAcc accumulator instead of Python context manager with nested |
| U001 | B6 | Colors | missing | L | S | <=2.6 | 1.00 | N | - | No Colors dataset module/constants |
| U002 | B6 | DataLoader | missing | M | L | <=2.6 | 0.50 | N | - | No dataset loaders (from_huggingface/from_csv/from_json/from_pandas/from_rm) |
| U003 | B6 | Dataset | missing | M | M | <=2.6 | 1.00 | N | - | No Dataset base (train/dev/test, shuffle_and_sample, prepare_by_seed, reset_seeds) |
| U004 | B6 | HotPotQA | missing | L | S | <=2.6 | 1.00 | N | - | No HotPotQA loader |
| U005 | B6 | MATH | missing | L | S | <=2.6 | 1.00 | N | - | No MATH loader |
| U013 | B6 | Choice | missing | L | L | 3.4.0 | 0.25 | N | - | No Choice decision type (typed options, probabilities, criteria) |
| U014 | B6 | Citations | missing | L | M | 3.1.0 | 0.50 | N | - | No Citations media type |
| U015 | B6 | Document | missing | L | M | 3.1.0 | 0.50 | N | - | No Document media type (lib/dspy/retrieve.ex:33 Dspy.Retrieve.Document is a different shape) |
| U016 | B6 | Noul | missing | L | L | 3.4.0 | 0.25 | N | - | No Noul boolean decision type |
| U017 | B6 | ReAnchor | missing | L | L | 3.4.0 | 0.25 | N | - | No ReAnchor teleprompter |
| U018 | B6 | Score | missing | L | L | 3.4.0 | 0.25 | N | - | No Score decision type (rubric, probabilities, level) |
| U019 | B6 | TypeSafe | missing | L | M | 3.4.0 | 0.50 | N | - | No TypeSafe client (guaranteed typed responses, inspect_history, copy) |
| U026 | B6 | BaseCallback | partial | H | M | <=2.6 | 1.50 | N | lib/dspy/signature/adapter/callback.ex:1 | Elixir behaviours cover adapter + tool events only; module/LM/evaluate/compile/interpreter events missing |
| U027 | B6 | DummyLM | missing | L | M | <=2.6 | 0.50 | N | - | No offline DummyLM (upstream examples/teleprompt tests depend on it) |
| U028 | B6 | DummyVectorizer | missing | L | S | <=2.6 | 1.00 | N | - | No DummyVectorizer |
| U031 | B6 | download | missing | L | S | <=2.6 | 1.00 | N | - | No URL download helper |
| U032 | B6 | dummy_rm | missing | L | S | <=2.6 | 1.00 | N | - | No dummy_rm stub retriever |
| U033 | B6 | exceptions | idiom | L | - | 3.0.0 |  | N | lib/dspy/lm.ex:252 (error tuples) | No Dspy exception module; Elixir error-tuple/raise idiom covers error propagation |
| U034 | B6 | experimental | na | L | - | 3.1.0 |  | N | - | No @experimental runtime annotation; Elixir moduledoc conveys status |
| U035 | B6 | pretty_print_history | partial | L | S | 3.0.0 | 1.00 | N | lib/dspy.ex:170 | Dspy.inspect_history prints summary lines only; no per-entry prompt/response detail or colours |
| U036 | B6 | with_callbacks | partial | H | M | <=2.6 | 1.50 | N | lib/dspy.ex:256 | Functional equivalent exists (with_callbacks(callbacks, fun) + Settings :callbacks); event surface is adapter+ |
