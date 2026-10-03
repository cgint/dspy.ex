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
| H0b-1 | Crash/timeout hardening, runtime sites (`openspec/changes/h0b-crash-hardening`) | **done — v0.3.46** |
| H0b-2 | Crash hardening Evaluate + `max_errors`/`failure_score` + Q2/Q3 raises (D-U1/D-U2 = upstream, approved 2026-09-28) | **done — v0.3.48** |
| H0b-3 | **Pin the mipro_v2 / gepa propagation invariant.** Both call `Evaluate.evaluate` outside any stream, so `MaxErrorsExceeded` / `InvalidMetricResult` escape `compile/3` raw. That is correct per D5 and verified uncaught at v0.3.48 — but it holds by *absence of a rescue*, not by a test, so a future edit could add one and silently swallow the error with nothing going red. One public-entry pinning test per site, mutation-proven by adding a rescue and watching it go red. Declared in `docs/COMPATIBILITY.md`. Size S | todo (not urgent — behaviour is already correct) |
| H12 | **Strict parsing of `:number` and `:integer` outputs — a live bug in shipped code, blocks the M1-d release.** `signature.ex:645-652` (`:number`) and `:632-636` (`:integer`) accept whatever number the text *starts* with and discard the rest (`{num, _rest} -> {:ok, num}`). So a judge answering `"80%"` becomes `80.0` and is clipped to a **perfect 1.0**, and `"1/2"` becomes `1.0` — silently wrong values, not errors. We also reject valid input that Python accepts (`".5"`). **Target = upstream 3.4.0's own verdicts**, measured by running `dspy.adapters.utils.parse_value(s, float)` (probe `ck_parse_float.py`, 2026-09-28). **Must accept** (with value): `"0.8"`→0.8, `" 0.8 "` and `"0.8\n"`→0.8, `"1"`→1.0, `"-0.2"`, `".5"`→0.5, `"5."`→5.0, `"1e-1"`→0.1, `"1E3"`→1000.0, `"+0.5"`→0.5, `"\"0.8\""` (quoted)→0.8, `"1_000"`→1000.0. **Must reject** (→ `{:error, {:invalid_output_value, field, _}}`, so a judge metric raises and Evaluate scores a failed example): `"80%"`, `"1/2"`, `"0.8 (high)"`, `"0.8/1.0"`, `"about 0.8"`, `"0,8"`, `"N/A"`, `""`, `"[0.8]"`, `"0.8.1"`, `"null"`. **Three upstream acceptances need Horst's ruling under the corrupt-or-lose-data principle** (HOW_WE_WORK): (a) **`"NaN"`, `"nan"`, `"inf"`, `"-inf"`** — upstream accepts, and its judge clamp then turns them into a **perfect 1.0** (`max(0, min(1, nan))` = 1.0, verified); BEAM floats cannot represent NaN/inf at all, so **reject** is both forced and principled; (b) **`"true"`→1.0** — pydantic coerces a boolean word into a number, so a judge answering "true" scores perfect; recommend **reject**, same species as "80%"; (c) **`"0x10"`→16.0** — a Python literal accident via `ast.literal_eval`, harmless; recommend **match**. `:integer` gets the same treatment, with its golden generated the same way (`parse_value(s, int)`). **Public-entry test per case** through a Predict whose scripted LM answers that exact string, via the committed golden generator (`plan/research/`, E1/F1 ruling). **Behaviour change for consumers** with `:number`/`:integer` outputs (lenient answers that used to parse now fail): grep the 5 consumers for such fields, run the canary, and a `RELEASES`/`COMPATIBILITY` note. Size S–M | **done — v0.4.3** (2026-09-30) |
| H13 | **Trace protocol for metrics, and what BootstrapFewShot accepts** (booked on D2, 2026-09-28). Upstream calls `metric(example, prediction, trace)` while bootstrapping (`teleprompt/bootstrap.py:206`); judge metrics then return `Prediction(score = f1 >= threshold)` (`auto_evaluation.py:62,123`). Upstream then decides with `success = metric_val >= metric_threshold` if `metric_threshold` is set, else **`success = metric_val` by truthiness** (`bootstrap.py:207-210`). **Correction to what Greta first reported:** upstream `Prediction` defines `__len__` but no `__bool__`, so `Prediction(score=False)` is **truthy** (verified: `bool(Prediction(score=False))` is `True`). **Without `metric_threshold`, upstream accepts every judge-scored demo, whatever the score** — it does *not* reject a 0.3. Ours never passes a trace; BootstrapFewShot accepts a demo iff `is_number(score) and score > 0` (`bootstrap_few_shot.ex:328`) and then `score >= metric_threshold` (`:296`, default 0). **Real divergences:** (1) a judge metric with no `metric_threshold` — upstream accepts all, ours accepts f1 > 0; (2) with `metric_threshold: t` — upstream compares the judge's *boolean* (0/1) against `t`, ours compares the *F1* against `t`; (3) a plain numeric metric returning a negative score — upstream accepts it (truthy), ours rejects. Until this lands, `threshold_metric/1` (M1-d) is the explicit way to get "accept iff f1 ≥ the judge's threshold". Decision needed when booked: port the trace protocol, and **do not** port Prediction-truthiness (it silently ignores the score — the corrupt-or-lose principle says don't import it). Size M | todo — before M6 |
| H14 | **Harness hardening follow-ups (Greta, H12 verdict 2026-09-29, none blocking).** (a) `SIGTERM`/`SIGHUP` handlers raising `SystemExit` so `finally` also runs on a kill or pane close — she *proved* a SIGTERM mid-run leaves debris the pre-flight does not recognise, though base-green catches it on the next run, so this is insurance not a hole. (b) Complete the pre-flight: it checks only the `parse_integer` call at each site, not `parse_number`, and matches `if t ==` but not the `if t in [...]` that three mutations inject; its docstring should name base-green as the backstop. (c) The H12 deviation table does not say which type each row applies to — the NaN/inf rows apply to `:number` only, since upstream already rejects them for `:integer`, so as written it lists a difference that does not exist. (d) Three exotic forms upstream accepts and we reject: nested parens `((5))`, quotes inside parens `("5")`, and an underscore after the prefix `0o_17`, on both paths — match via the generator or add one declaration line. Size S | todo |
| H15 | **String-key audit — two live bugs in shipped code, one class: atom-only field lookup on `attrs`** (Greta, M1-e refresh 2026-09-30; ruled T3/T4 by Horst 2026-09-30). **P1 (loud, shipped v0.4.1):** `Dspy.Metrics.answer_exact_match/2,3` and `answer_passage_match/2` read `Map.fetch(attrs, :answer)`/`(:context)` (`fetch_field!/2`, `fetch_context!/2`, `lib/dspy/metrics.ex`) → a string-keyed example raises `"example[:answer] is missing"`, so in `Evaluate` every loaded example scores `failure_score`. **P2 (silent, worst):** `Dspy.Signature.format_example/3` (`lib/dspy/signature.ex:470-480`) reads `Map.get(example.attrs \|\| example, field.name, "")` → a string-keyed demo renders with **empty values** in the Default adapter and JSONAdapter; ChatAdapter is correct (`Dspy.Example.get/2`). Probe `plan/research/m1e-refresh-2026-09-30/demo_probe*.exs`: string-keyed demo in prompt = false/false/true. A few-shot optimiser over a loaded trainset trains on blank demos and reports nothing. **Scope:** P1, P2, the ~12 other atom-only `attrs` call sites (`trainset.ex` 4, `metrics.ex` 4, `ensemble.ex` 2, `signature.ex` 1, `multi_chain_comparison.ex` 1) and pattern-matched `%{attrs: %{k: _}}` heads — **every site through ONE canonical accessor** (the `Prediction.fetch/2`/`Example.get/2` atom→string fallback), not 12 separate fixes (the H12 three-parsers lesson). **Plus T4:** `majority` accepts string-keyed maps (reverses the M1-c atom-only boundary; keep "both `"k"` and `:k`" raising); update its COMPATIBILITY entry and remove the now-wrong atom-keys hint. Each site: a string-keyed test through the public entry, mutation-proven. Size M | **done 2026-10-02 v0.4.5** |
| H16 | **`Dspy.Random` for all library sampling — a real bug, not tidiness** (Greta, M1-e refresh R4 2026-09-30; ruled T2). **6 seeded `:rand.seed(:exsss, …)` calls** (`lib/dspy/evaluate.ex:908`, `lib/dspy/trainset.ex:103,144,184`, `lib/dspy/teleprompt/bootstrap_few_shot.ex:234,365`) **change the CALLER's random state**: a user who seeds their own randomness has it silently perturbed by our library; and each seeded result depends on the OTP/Elixir release. Plus **4 unseeded** `Enum.shuffle`/`Enum.random` calls (`trainset.ex:187,377,385,391`). Migrate all to M1-e's `Dspy.Random` (CPython MT19937); seeded results change → RELEASES/COMPATIBILITY note. Decide whether `Dspy.Trainset.split/sample` are deprecated in favour of `DataLoader.train_test_split/sample`. Test: `:rand.export_seed/0` identical before and after each call, seeded and unseeded caller. Size M | todo — after M1-e |

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
| S044 | majority | missing | H | S | 3.00 | <=2.6 | - | N | - | No Dspy.majority; ensemble :majority_vote is a different teleprompter mechanism | done 2026-09-29 v0.4.2 (M1-c) |
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
| H5 | **`Dspy.Metrics.create_metric/2` swallows every error and every non-number into `0.0`** (`lib/dspy/metrics.ex:222-249`: `if is_number(score), do: score, else: 0.0` plus `rescue _ -> 0.0`). This is the exact pattern H0b-2 spent two slices removing from `run_metric`: a broken metric silently scores zero instead of surfacing as a failed example (D-U1) or `InvalidMetricResult` (Q2). **Must be done before M6**, when optimizers lean on composed metrics. Fix direction: let errors raise and non-numbers pass through, so Evaluate's H0b-2 semantics apply; a behaviour change for `create_metric` callers → public-entry tests + mutation proof + COMPATIBILITY note. Found in the M1-b contract review (F8, Greta 2026-09-28; booked on Horst's ruling). Size S | todo (before M6) |
| H6 | **`test/adapter_selection_test.exs` is `async: true` and calls global `Dspy.configure/1`** — a pre-existing flakiness hazard, deliberately left untouched during M1-a to honour "zero diff to existing tests" (A5.2). M1-a's own three new files were fixed to `async: false`; this one still races. Fix: `async: false`, or port it to process-scoped `Dspy.context/2`. Evidence: an unchanged tree produced 1, 85, 0 and 3 failures across four runs before the M1-a files were fixed | **done 2026-09-29 (H12)** — set to `async: false` (Horst ruling 2026-09-29, root-cause fix landed inside H12 because this test was the CAUSE of the H12 flake: its global `Dspy.configure(adapter: ...)` mutated the default adapter that H12's async fixture test relied on). 20× plain `mix test` = 20/20 clean. H7 (process-scoped `with_mock_lm/2`) remains the cleaner long-term home for this class of test. |
| H7 | **Test-side `with_mock_lm/2` helper** wrapping calls at the call site via process-scoped `Dspy.context/2`, so the `test/evaluate/*` files can go back to `async: true` and stop mutating global settings via `Dspy.configure/1`. Verified viable: `Evaluate` is one of the 13 sites wired in v0.3.44 (`lib/dspy/evaluate.ex:151` `Dspy.Context.capture/0`, `:161` `with_context/2`), so context **does** reach the per-item children — no lib change needed. Ilse's idea, booked rather than built mid-review. Would also close H6 cleanly. Size S | todo *(merged 2026-09-30: this item was booked twice, by Horst and by Ilse; the duplicate row was removed)* |
| H17 | **`run_metric/3` treats any non-2-arity function as arity 1** (`teleprompt.ex:158-164`), so a user-supplied **arity-3 metric fails silently on every example** instead of raising. Upstream metrics take `(example, pred, trace)`, so anyone porting a metric from Python hits this immediately and gets a suite of silent failures with no diagnostic. Fix: detect arity explicitly and raise naming the expected arities. Found in the M1-b contract review (F4, Nadja 2026-09-29). Size S | todo | *(renumbered from a duplicate H12, 2026-09-30)*
| H18 | **Legacy `Dspy.Metrics.exact_match`/`f1_score` diverge from upstream AND are optimizer defaults.** No NFD normalisation, no article removal, and `[^\w\s]` **without the `u` flag strips every non-ASCII letter** — `"Straße"` → `"strae"`, i.e. a correctness bug for every non-English user. Also set-based F1 and both-empty → `1.0`. Upstream optimizers have no default metric at all. Changing these is a **behaviour change for optimizer users**, so it needs its own decision: switch the defaults to the M1-b functions, deprecate, or keep and document. Found in the M1-b contract review (F7, Greta/Nadja 2026-09-29). Size M | todo (needs a decision first) | *(renumbered from a duplicate H13, 2026-09-30 — the user decision package is `plan/research/decisions/2026-09-29-h13-legacy-metrics.md`, filed under the old id)*
| H19 | **Re-count the 150 against the shipped code — at the end of M1.** The dashboard figure (32/150) was measured 2026-09-26 and has not been re-measured through v0.4.0–v0.4.3. The lead had been quoting "~39" in chat as an estimate (+1 per slice), which is not a count. Re-run the inventory rows touched by M1 against the shipped code and the tests that pin them, apply the same done/partial rules, and publish a measured number. Also re-check every row marked **done**, since `dspy.inspect_history` (S028) turned out to be partial. Size S | todo — end of M1 |
| H20 | **Mechanical checks, stage 1: C2 — one shared mutation library** (Greta design `plan/research/2026-09-30-mechanical-checks.md`, ruled by Horst 2026-09-30). Each mutation **declares the tests it must kill**; verdicts `KILLED` / `SURVIVED-TARGET` (a claimed test passed) / `BLUNT` (failures outside the declared set) / `INVALID` (non-zero exit with no failing test named — which is exactly how the ENFILE outage produced two false kills). Reads a JSON test formatter, not console text. Built-in signal handlers, leftover pre-flight, base-green check, no disk state. **Why first:** three of M1-d's five blocking findings were rules already written in HOW_WE_WORK that did not transfer; the rules that never recur are the ones turned into tooling. C3a (every acceptance test claimed by some mutation) follows almost free. **Sequencing:** built before the M1-d fix round, which adopts it; older harnesses migrate when next touched. Later stages: C5 `deviations.json` per slice (required artifact), C1a ordered-text helpers refuse maps, C3b vacuous-assertion lint, C4 duplicate-code warning. Rejected as noisy: a map-order lint over `lib/`. Size M | **stage 1 (C2+C3a) done 2026-10-02 `5369372`** (Greta PASS after 2 blocks); later stages C5, C1a, C3b, C4 todo. **mutlib follow-ups (2026-10-03):** (a) reject an `also` name matching no test (H15 had 8); (b) build coverage from the base run's formatter records, not a source regex (`describe` names mismatch, M1-e); (c) a harness must declare its contract's mutation-ID list and fail when defined IDs differ (M1-e phase 2 shipped 17 mislabeled mutations of ~40; my 17/17 check did not catch it) |
| H8 | **O(n²) in `Dspy.Evaluate`: `Enum.at` inside index loops.** `finish_evaluation`'s `results` build and `rows_for/3` call `Enum.at(items, i)` inside an `Enum.with_index`/`Enum.map` over the testset — O(n²) on large testsets (each `Enum.at` walks from the start). Pure performance, no behaviour change; trivial to fix (zip or `Enum.split` once). Found in the M1-a fix-round-2 review (booked on Horst's "book only, not in this round" ruling, 2026-09-29). Size S | todo |
| H9 | ~~`failure_score` option unvalidated / `lookup_attr` metric-pair match~~ **SUPERSEDED by BB1 (2026-09-29):** the name-based routing (including the `is_number(in_key)` metric check) is deleted in the fix-round-3 brief, so the empty-cell path Ilse described no longer exists as code. The remaining real issue is split out as H10 (validate `failure_score` up front). No action here. | superseded |
| H10 | **Validate `failure_score` up front.** As shipped, `failure_score: :custom` (an atom) survives to the mean computation and raises `ArithmeticError` — AFTER all the LM calls, so a misconfigured option costs a whole expensive run. Rule (Horst, 2026-09-29): validate it is a number in `evaluate/4` so it raises `ArgumentError` BEFORE any LM call. One test (atom → `ArgumentError`, raised before the mock LM sees anything; number → behaves as today), mutation-proven. Size S | todo |
| H11 | **Two pre-existing crashes in the save path — contract violations, not M1-a bugs.** (a) A `%Prediction{}` built with `attrs: nil` → `BadMapError` in the save path; (b) a plain map returned from `forward` (instead of a `Dspy.Prediction`) → `KeyError`. Both break the documented module contract (`lib/dspy/module.ex:11` says `forward` returns `Dspy.Prediction.t()`), so they are user-contract violations — book with that note (fix = a friendly error at the contract boundary, or document + add a guard clause). Found in the M1-a fix-round-2 review, 2026-09-29. Size S | todo |
