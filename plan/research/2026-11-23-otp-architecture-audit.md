# OTP & Architecture Audit (`01e5777..2873481`)

- **Date:** 2026-11-23
- **Audited range:** `01e5777` (2026-11-18) → `origin/main` `2873481` (2026-11-22)
- **Contributors:** Firstmate (`gemini-4-neon`), Sol (`gpt-6.2-sol`, OTP/BEAM runtime & static audit), Fable (`claude-fable-5-2`, Elixir architecture & downstream consumer audit), External Elixir/OTP Architect (`overview-app` review).
- **Status:** Read-only audit complete. Feature implementation (`history_suppression`, `Prediction` scores) paused pending owner alignment on the proposed hardening waves.

## Executive Verdict

1. **Live OTP/transport defects beat new parity work:** Runtime probes reproduced **two indefinite hangs** (trapping caller in `Dspy.Evaluate`; worker trapping `:shutdown` in `Dspy.ProgramStream`) and **16× HTTP retry amplification** on persistent OpenAI `429`s.
2. **Ambient state was doubled down on:** 7 of the 11 process-dictionary modules landed in this 3-day window because `@callback forward(module, inputs)` has no context/opts argument.
3. **Zero downstream validation + high upgrade friction:** All five inspected local consumers (`elix-live-chat`, `agent-coding-gui`, `third-eye-liveview`, `finance-partner`, `my-speech-google`) lock `dspy.ex` at or before `01e5777`. Upgrading currently forces an `llm_db` rollback (via the June `req_llm` git SHA pin) and a `swoosh 1.30.0` bump (via `idna ~> 8.0`).
4. **Heavy low-fan-in surface:** Much of the +15,209 `lib/` LOC (`XMLAdapter` union decoding, deep `GEPA` variants, `ColBERTv2`, and `BootstrapFinetune`/`BetterTogether` which cannot run on any shipped LM) has zero consumer usage.

---

## 1. Inventory (`01e5777..2873481`)

- **Volume:** 119 commits, 115 PRs (`#1`–`#115`), 252 files changed, **+41,287 / −2,637 LOC** (~+15,209 `lib/`, ~+22,911 `test/`).
- **Modified/new `lib/` modules > 400 lines (24 files):** `evaluate.ex` (1159), `retrieve.ex` (1108), `signature.ex` (1006), `signature/adapter/pipeline.ex` (994), `lm.ex` (991), `lm/req_llm.ex` (841), `tools.ex` (820), `signature/adapters/xml_value.ex` (775), `signature/adapter_pipeline.ex` (733), `teleprompt/mipro_v2.ex` (695), `teleprompt/gepa/reflective.ex` (668), `signature/adapters/xml.ex` (661), `dspy.ex` (660), `teleprompt/ensemble.ex` (655), `signature/adapters/chat.ex` (582), `teleprompt/bootstrap_few_shot.ex` (557), `teleprompt/bootstrap_few_shot_with_random_search.ex` (536), `trainset.ex` (495), `module/program_state.ex` (448), `module.ex` (442), `teleprompt/copro.ex` (434), `teleprompt/gepa.ex` (433), `teleprompt/better_together.ex` (426), `random.ex` (402).
  - *Note:* Largest in-range growth was `adapter/pipeline.ex` (+588), `lm.ex` (+398), `retrieve.ex` (+361), `lm/req_llm.ex` (+336), plus new `xml_value.ex` (775), `gepa/reflective.ex` (668), `xml.ex` (661).
- **Stateful processes (`lib/`):**
  - `> 250 lines`: `retrieve.ex` (`VectorStore`, 1108), `tools.ex` (`ToolRegistry`, 820), `lm/disk_cache.ex` (362), `settings.ex` (314), `retrieve/in_memory_retriever.ex` (257, unchanged).
  - `<= 250 lines`: `lm/cache.ex` (160), `embeddings/batcher.ex` (140), `lm/history_capture.ex` (122), `lm/history.ex` (83).

---

## 2. Verified Findings (`file:line`)

### P1 — Task & Stream Lifetime (Reproduced Hangs)
- **`Dspy.Evaluate` hangs trapping callers / kills normal callers** (`lib/dspy/evaluate.ex:183-195,273`): Raw `spawn_link` coordinator running unsupervised `Task.async_stream` and an unref-tagged `receive` with no `:EXIT`/`:DOWN` branch. Killing an item task kills the coordinator; non-trapping callers exit `:killed`, trapping callers (GenServers/LiveViews) block forever.
- **`Dspy.ProgramStream` cancellation hangs & leaks** (`lib/dspy/program_stream.ex:171,190,319`, `lib/dspy/program_stream/channel.ex:4,13-79`): `Enum.take(1)` hangs indefinitely if a direct stream worker traps `:shutdown` while waiting for demand; rejected foreign continuations leave `:DOWN` in the original consumer's mailbox. `Channel`'s 4-message offer/grant/ack backpressure stops at the DSPy boundary because pinned `ReqLLM.StreamServer` (`deps/req_llm/lib/req_llm/stream_server.ex:391,839`) queues chunks with an unused `high_watermark`.
- **Unsupervised processes & ordered `Task.async_stream` pitfalls:** `GenServer.start/2` (`lib/dspy/lm/history_capture.ex:35`), raw `spawn/1` watchers (`lib/dspy/process_ownership.ex:5`, `lib/dspy/lm/req_llm.ex:160-162`), `spawn_monitor` (`lib/dspy/refine/advice.ex:111,136`), and zero `Task.Supervisor` usage across `Evaluate`, `Parallel`, `Retrieve`, `Tools`, and teleprompters. Ordered `Task.async_stream` (`evaluate.ex:249`, `parallel.ex:161`) delays failure-budget accounting behind blocked earlier items while still launching later tasks; `BootstrapFewShot` (`bootstrap_few_shot.ex:285-290`) applies a 30s chunk timeout that drops already-completed results.

### P1 — Transport Retry Amplification
- **16× HTTP attempts on persistent OpenAI `429`** (`deps/req_llm/lib/req_llm/providers/openai.ex:722`, `deps/req_llm/lib/req_llm/step/retry.ex:97`, `lib/dspy/signature/adapter/pipeline.ex:878-906,930-932`): Pinned `ReqLLM` OpenAI attaches `Req`'s retry step *after* merging request opts (4 attempts even when budgets are `0`). DSPy's outer loop repeats that 4× by default (`max_retries: 3`), sleeps a fixed `Process.sleep(1000)` with no backoff/jitter, ignores `Retry-After`, and undercounts telemetry attempts.

### P2 — Ambient State & Python-isms
- **11 process-dictionary modules** (4 pre-existing: `settings.ex`, `context.ex`, `usage_acc.ex`, `adapter/callbacks.ex`; 7 new: `lifecycle.ex`, `telemetry.ex`, `lm/history_capture.ex`, `program_stream.ex`, `program_stream/composite.ex`, `program_stream/status_callback.ex`, `lm/req_llm/structured_stream.ex`). Root cause: `@callback forward(module, inputs)` (`lib/dspy/module.ex:21`) has no context/opts argument.
- **Argument smuggling & struct pollution:** Stream callbacks stashed in process dict (`program_stream.ex:375-378` → `module.ex:56`); non-streaming `Predict.forward/2` routed through `ProgramStream` (`predict.ex:106-107`, `chain_of_thought.ex:126`); undeclared tuple keys injected into `%Predict{}` (`composite.ex:81`, `advice.ex:31`, `predictor_trace.ex:25`).
- **Torn reads, silent typos, restart loss:** 10+ separate `Dspy.Settings.get/1` `GenServer.call`s per unbound `Predict` (`settings.ex:100`, `lm.ex:395,822,856,973-975`); `struct(settings, opts)` (`settings.ex:273`) silently drops typos; `Settings` crash resets to `[]` (`application.ex:19-21`).

### P2 — Serialized GenServer I/O & Durability
- **Cache serialization & eviction-before-publish** (`lib/dspy/lm/disk_cache.ex:59-78,263-276`, `lib/dspy/lm/cache.ex:41,67-85`): `DiskCache.init/1` synchronously scans/evicts disk; `Cache` runs `File.rename/2` inside its GenServer loop (stalling memory hits and `Settings.configure/1`); `Cache.fetch/3` serializes every read through `GenServer.call` to bump LRU; `DiskCache` evicts valid records before publication succeeds.
- **`Embeddings.Batcher` blocks inside GenServer** (`lib/dspy/embeddings/batcher.ex:67-84,116-139`): Runs `Embeddings.query_batch/3` synchronously inside the GenServer with unbounded mailbox and no dead-caller pruning.
- **Checkpoint durability gap** (`lib/dspy/module/program_state.ex:436-444`, `lib/dspy/embeddings/checkpoint.ex:114-122`): Temp write + close + rename without `:file.sync/1` (unlike `disk_cache.ex:256`).

### P2 — Dependencies, Consumer Friction & Toolchain Hygiene
- **`mix.exs:37-70`:** `req_llm` pinned to git SHA `66b40425` (2026-06-02, `llm_db ~> 2026.5.2`) blocks Hex releases, forces `llm_db` rollbacks on all 5 consumers, and causes the `zoi < 0.20.0` cap. Code couples to `ReqLLM` internals (`structured_stream.ex:4-10`, `retry_policy.ex:4,60-62`, `disk_cache/identity.ex:31-34`). `idna ~> 8.0` + `jsv >= 0.28.0` conflicts with `swoosh 1.29.3` in `elix-live-chat` and `agent-coding-gui` (requires `swoosh 1.30.0`). `mix.exs:61` falsely claims `lib/` never calls `Req` (`ColBERTv2` calls `Req.request` at `retrieve.ex:396,409`).
- **Tests & static analysis:** 133/223 test files lack `async: true` (84 explicit `async: false`; 59 call `Dspy.configure`). No Credo/Dialyzer/ExDoc configured; `@spec` covers 216/607 (36%) public functions in documented modules. `test/consumer_contract/` omits `Dspy.context`, `ReAct`, and `Tools`.

---

## 3. Keep / Fix / Stop Classification

- **Keep (lean, high value):** Per-predictor LM binding (`Predict.new(sig, lm:)` / `set_lm`), `LM.RetryPolicy` (76 LOC), immutable `Dspy.Embedder` & `Dspy.Embeddings`, SSE framing (`streaming_response.ex`, 55 LOC), supervised ETS cache & generation epochs, monitor-bound `capture_history`, `Telemetry` event names.
- **Fix / Simplify:** `Evaluate` & `Parallel` task supervision; single HTTP retry owner; unified cancellable `ProgramStream`; split `Adapter.Pipeline` (994 LOC, 12–14 arg helpers); move `File.rename/2` off `LM.Cache` and serve memory hits from ETS; isolate `Embeddings.Batcher` worker; add `:file.sync/1` to checkpoints; snapshot `Dspy.Settings` once per call into an explicit immutable context struct backed by ETS (`read_concurrency: true`); retire singleton `Retrieve.VectorStore` and `InMemoryRetriever`.
- **Stop / Freeze / Quarantine to `extras/`:** `BootstrapFinetune` + `BetterTogether` (~800 LOC, zero real `c:Dspy.LM.finetune/3` implementations), `XMLAdapter` + `xml_value.ex` (1,820 lib / 3,673 total LOC, zero consumer refs), `GEPA` expansion (1,830 lib / 3,274 test LOC, zero consumer refs), `ColBERTv2` (~200 LOC, placeholder callbacks + direct `Req`), dead retrieval stubs (`OpenAIEmbeddings`, `ChromaDB`).

---

## 4. Proposed Action Waves (Awaiting Owner Approval)

1. **Wave 0 — Guardrails:** `docs/stack-best-practices.md` (written), `AGENTS.md` / `LEAD.md` pointers (written), plus Credo/Dialyzer baseline.
2. **Wave 1 — P1 Runtime Correctness:** `Task.Supervisor` for `Evaluate`/`Parallel`/`HistoryCapture`/`Refine.Advice`/optimizers; unified cancellable `ProgramStream`; single HTTP retry owner + `Adapter.Pipeline` split.
3. **Wave 2 — Consumer Unblocking:** Unpin/upgrade `req_llm`, decouple from internals, re-test `zoi` cap, document `swoosh 1.30`, upgrade and verify a real consumer.
4. **Wave 3 — Idiomatic State, GenServer I/O & Durability:** Boundary context snapshot + ETS-backed `Dspy.Settings` (reloaded on restart), remove `Predict`→`ProgramStream` routing & tuple-key struct injection, non-blocking `Cache`/`DiskCache`/`Batcher`, `:file.sync/1` on checkpoints.

### Owner Standing Guidance (2026-11-23)
- **Dependencies:** Authorized to upgrade all Elixir Hex dependencies (including major versions) or pin specific versions when latest combinations break downstream projects, coordinating cleanly across repos.
- **Delegation:** Use **GPT-6.1 Terra (`gpt-6.1-terra`, `reasoningEffort: "medium"`)** for autonomous implementation and downstream/dependency resolution subagents so they can resolve cross-repo issues independently without babysitting.
- **Compatibility posture:** Both `dspy.ex` and all downstream consumers are owned and used exclusively by us — **no strict backwards-compatibility shims are required**. Prefer clean, idiomatic Elixir/OTP APIs and update consumers in lockstep when breaking changes improve simplicity and correctness.

### Owner Decisions (Resolved 2026-11-23)
- **Previously approved slices (`history_suppression`, `Prediction` scores):** **Held** until Waves 1–3 land.
- **Zero-consumer parity surface:** **Option A approved** — freeze `XMLAdapter` and `GEPA` in place; quarantine `BootstrapFinetune`, `BetterTogether`, and `ColBERTv2` to `extras/`; delete dead retrieval stubs (`OpenAIEmbeddings`, `ChromaDB`) and retire legacy singleton retrievers (`Retrieve.VectorStore`, `InMemoryRetriever`) in favor of immutable `Dspy.Embeddings`.
