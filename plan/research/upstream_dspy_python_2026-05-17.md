# Upstream Python DSPy scan — 2026-05-17

## Summary

Fetched `../dspy` (`https://github.com/stanfordnlp/dspy.git`) and compared the previously local/fetched `origin/main` baseline to current upstream.

- Baseline before fetch: `970721b9` — 2026-01-21 — `Update gepa[dspy] version to 0.0.25 adding python==3.14 support (#9224)`
- Current upstream `origin/main`: `661a612c` — 2026-05-17 — `fix: correct mismatched closing code fence in README (#9771)`
- New commits on `origin/main`: 170
- New tags observed: `3.1.3`, `3.2.0`, `3.2.1`
  - `3.1.3`: `4ef729d2` — ChainOfThought legacy rationale behavior restored
  - `3.2.0`: `d3a890c0` — release tag on release workflow fix
  - `3.2.1`: `29448ae1` — release branch patch release; not merged into `origin/main` at scan time

## Command evidence

```bash
git -C ../dspy fetch --prune origin
git -C ../dspy rev-list --count 970721b9..origin/main
git -C ../dspy log --reverse --date=short --pretty=format:'%h %ad %s' 970721b9..origin/main
git -C ../dspy diff --stat 970721b9..origin/main
```

## High-impact upstream changes for `dspy.ex` parity

### Signatures / adapters / structured output

Relevant commits:
- `4ef729d2` — Revert ChainOfThought to pre-`dspy.Reasoning` behavior.
- `35c19acb` — Skip JSON schema for DSPy custom types in prompt.
- `fed54d0a` — Pass `use_native_function_calling` in `JSONAdapter.acall`.
- `b833bc55` — Raise `AdapterParseError` on empty LM response instead of silent `None`.
- `7e02cc8e` — Deprecate `prefix`, `format`, and `parser` args in `InputField`/`OutputField`.
- `71493dba` — Add type validation for input fields.
- `3278e0f8` — Reject duplicate input and output field names.
- `a3874e34` — JSONAdapter preserves diacritics (`ensure_ascii=False`).
- `dda0e617` — Add `XMLAdapter` to `dspy.ai`.

Porting implications:
- Check `dspy.ex` ChainOfThought semantics against restored Python rationale field behavior.
- Consider explicit tests for empty LM responses returning parse errors, not silent partial predictions.
- Check duplicate field/input validation parity.
- Check JSON serialization with non-ASCII/diacritics.
- XMLAdapter is new upstream surface; likely later/optional unless adoption-priority changes.

### Predict / modules / state loading

Relevant commits:
- `0a4097c1` — Fix `ProgramOfThought._parse_code` corruption.
- `c3424073` — Run evaluation on main thread when `num_threads=1`.
- `c88b2790` — Make `load_state` transactional: validate then deepcopy.
- `fcb648de` — Fix cloudpickle serialization of Signature on Python 3.14.

Porting implications:
- `dspy.ex` should keep evaluation deterministic when concurrency is disabled.
- Parameter/state apply/import should be transactional: validate before mutating if not already guaranteed.

### LM / provider / cache / history

Relevant commits:
- `c811792d` — Fix request header in streaming mode.
- `26bfd249` — Fix rollout_id warning for default LM temperature.
- `af2a955f` — Block unsafe LM loading keys.
- `30ebe34f` / `f5a62732` — Litellm local model cost map env var fix and revert.
- `0d390ad2` — Introduce DSPy-owned `ContextWindowExceededError`.
- `d0b89320` / `94062912` — Move capability checks to `BaseLM`; adapters no longer depend on litellm.
- `8d12bdaf` — Fix cache bugs: `os.fspath(None)` crash, double disk lookups, lazy logging.
- `02ce8b24` — Add `restrict_pickle` safe disk cache deserialization.
- `92e7f43e` / `faa99d1f` — Guard missing/None usage metadata.
- `48b08d73` — Preserve per-message structure in Responses API conversion.
- `50fd9ea7` — Forward headers in async litellm streaming.
- `b0baa1d1` — Honor `caching=False` per-call in `dspy.Embedder`.
- `621c3a61` — Make LiteLLM imports lazy.

Porting implications:
- Good alignment with `dspy.ex` decision to keep provider quirks in `req_llm` adapter.
- Check whether `Dspy.LM` needs explicit capability flags like `supports_function_calling`, `supports_response_schema`, `supported_params` rather than ad hoc adapter/provider checks.
- Ensure usage tracking tolerates missing/nil usage.
- Treat unsafe state/LM loading as a security concern if/when adding richer persistence.

### RLM / tools / Python interpreter / sandbox

Relevant commits:
- `98a11726` — CodeInterpreter messaging format converted to JSONRPC.
- `aa3a2cd6`, `815f92a0`, `6f8e8e9c`, `586156eb`, `3109c61f`, `d8fae34b`, `a8041dae`, `295e2b35` — RLM/interpreter serialization, parsing, restart, and safety improvements.
- `ed4d479a` — Add `SandboxSerializable` protocol for custom RLM types.
- `62f5c43e` — Await async tool functions in PythonInterpreter.
- `b175ef87` — Resolve symlinks for Deno `--allow-read` paths.

Porting implications:
- Mostly Python-specific, but relevant conceptually to tool execution safety.
- For `dspy.ex` ReAct/tools: test observable tool-call behavior and timeouts; avoid unsupervised background work.

### Teleprompt / optimizers

Relevant commits:
- `631085c0`, `73b26249`, `b3ee96fa`, `9e8a323d` — GEPA dependency/API updates; remove tool optimization; cached evals; result/docs changes.
- `90a9dd81` — Pass `metric_threshold` to BootstrapFewShot in unshuffled (`seed=-1`) case.
- `bb110a02` — Make BetterTogether compatible with all optimizers; large BetterTogether redesign.
- `0ae2ca09` — Fix demo index assignment in MIPROv2.
- `edd0a5b2` — Only suggest reducing GEPA valset when large.
- `43bf2c59` — Make Optuna optional.

Porting implications:
- Check `dspy.ex` BootstrapFewShot unshuffled/seed behavior.
- Check MIPROv2 demo index handling.
- BetterTogether is substantially expanded upstream; probably later/optional unless milestone priorities change.
- GEPA parity should be revisited separately; upstream moved beyond toy behavior.

### Retrieval / embeddings

Relevant commits:
- `8ccaaa35` — Handle error responses from ColBERTv2 server.
- `b26b2378` — Fix ColBERTv2RetrieverLocal forward scoping bug.
- `b0ea262c` — Add `EmbeddingsWithScores` for similarity score access.
- `da1f0871` — Make numpy optional.

Porting implications:
- `dspy.ex` InMemoryRetriever/RAG could expose scores if not already.
- Optional dependency posture matches `dspy.ex` core-minimal principle.

### Security / dependency / CI posture

Relevant commits:
- `e5cf186e`, `02ce8b24`, `0af442e2`, `39a477d3`, `0d390ad2`, `9cdb0aac`, `0af442e2`, `75befbe0`, `9ebd38f5` — security hardening, CI hardening, dependency pinning/replacement.
- `0af442e2` — Added `SECURITY.md`.
- `9b0834c0` — Added AI-generated code policy.

Porting implications:
- Consider adding/aligning public security/contribution policy docs before broader OSS release.
- Continue avoiding unsafe deserialization and unpinned mutable artifacts.

## Suggested follow-up slices for `dspy.ex`

1. **Upstream parity audit: Predict/CoT/adapters**
   - ChainOfThought rationale field behavior.
   - Empty LM response behavior.
   - duplicate input/output field validation.
   - JSON diacritics preservation.

2. **State/persistence safety audit**
   - Ensure parameter/state import is validate-before-mutate.
   - Document or test unsafe loading keys if applicable.

3. **Teleprompt parity audit**
   - BootstrapFewShot `metric_threshold` + `seed=-1` behavior.
   - MIPROv2 demo index behavior.
   - GEPA upstream delta versus `dspy.ex` toy/proven subset.

4. **Retrieval/RAG score parity**
   - Decide whether to expose scores in retriever outputs.

5. **OSS hygiene**
   - Consider SECURITY.md and AI-generated-code policy if public release posture requires it.
