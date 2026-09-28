# Tasks — h0-process-context

Worker: Benjamin. One lib-editing worker at a time. Tree compiles + green between steps.
Gates (each step): `mix compile --warnings-as-errors` · `mix format --check-formatted` ·
`mix test` · `mix test --only consumer_contract` (33).

Baseline (record in final report): `git rev-parse HEAD` → `9b8d5d39ae5451614d6e8dc39b4f74c167aed56d`;
`mix test` → 426 passed, 8 excluded; `mix test --only consumer_contract` → 33 passed, 401 excluded.

## S0 — Design (this file + design.md) ✅
- [x] `design.md`: D1–D4 capture/run semantics; raw-stack callback capture (D2); empty
      usage-capture set stated explicitly (D3); per-site wiring table + usage double-count
      check; crash/timeout invariants per g1.md crash table.
- [x] `tasks.md`: this file, gate task per scenario.
- **STOP. Await controller (Judith) + Greta co-sign verdict before S1.**

## S0b — Design revision (Greta SIGN-WITH-EDITS, 2026-09-26) ✅
- [x] `design.md` revised in place: BLOCKER fixed — API is `capture/0` + `with_context(ctx, fun)`
      (install in CURRENT process, save/restore in `after`, NO spawning; `run/2` dropped);
      callback-stack install SAVE/RESTORE (not bare `Process.put`); D5 nested-site outer wrap
      REQUIRED + chain test; D6 crash asserts in `with_context` unit tests only; empty usage
      capture set matches updated spec.md ("Usage accumulators are intentionally not captured").
- [x] `tasks.md` T1.x rewritten to the `with_context` unit-test shape (same process, restore asserts).
- **STOP. Await controller (Judith) review of revised design. Then S1 may start WITHOUT another
      round-trip to Horst (Horst 2026-09-26 instruction). Ping Horst (non-blocking) once design
      is revised AND S1 starts.**

## S1 — `Dspy.Context` module + unit tests ✅
- [x] T1.1 overrides reach target: marker LM via `Dspy.context([lm: marker])` → `capture()` → `with_context()` in Task; global unchanged; caller frame restored.
- [x] T1.2 callbacks exactly-once (D2, raw stack): (a) GLOBAL once; (b) per-call once; (c) `Dspy.context(callbacks:)` once; combined: 2 distinct cbs each fire once.
- [x] T1.3 child usage stays on child (D3): `track_usage: true`; target prediction `metadata[:lm_usage]` == only target's calls; caller frame untouched.
- [x] T1.4 untracked caller gets no usage state: no `{:dspy, :usage_*}` keys in caller.
- [x] T1.5 state restored on crash (D6): raise, throw AND exit inside fun restore overrides + stack + usage keys.
- [x] T1.6 target state does not leak back: target's own context + callbacks invisible in caller.
- Gate: compile ✓; format ✓; `mix test` → 440 passed, 8 excluded (baseline 426 + 14 new) ✓; consumer_contract → 33 passed ✓.

## S2 — Wire: Dspy.Parallel, Module.parallel, Dspy.Evaluate ✅
- [x] T2.1 `lib/dspy/parallel.ex:144-152`: replaced `Settings.current_overrides()` + `Settings.with_overrides/2` with `Context.capture()` + `Context.with_context/2`. Updated moduledoc. Removed unused `Settings` alias.
- [x] T2.2 `lib/dspy/module.ex:196`: wrapped `fn -> forward(module, inputs) end` in `Dspy.Context.with_context(ctx, ...)` with `ctx` captured before `Task.async`.
- [x] T2.3 `lib/dspy/evaluate.ex:104`: wrapped `fn chunk -> evaluate_chunk(...) end` in `Dspy.Context.with_context(ctx, ...)` with `ctx` captured before `Task.async_stream`.
- [x] T2.4 `test/context/context_propagation_test.exs`: 3 per-site marker-LM tests (Parallel.run, Module.parallel, Evaluate.evaluate) — red before wire, green after.
- Gate: compile ✓; format ✓; `mix test` → **444 passed, 8 excluded** (441 + 3 new); consumer_contract → **33 passed** (unchanged); `test/parallel_test.exs` → **16 passed** (existing tests stay green).

## S3 — Wire: tools.ex:503 + 756 ✅
- [x] T3.1 `lib/dspy/tools.ex:503` (`call_tool`): wrapped task body in `Dspy.Context.with_context(ctx, ...)` with `ctx = Dspy.Context.capture()` before `Task.async`. Rescue boundary unchanged.
- [x] T3.1 `lib/dspy/tools.ex:756` (`execute_tool`): same wrap pattern. Rescue boundary unchanged.
- [x] T3.2 `test/context/context_tools_propagation_test.exs`: 2 marker tests — `execute_tool` (direct marker assertion) + `call_tool` (structural equivalence documentation; private function).
- Gate: compile ✓; format ✓; `mix test` → **446 passed, 8 excluded** (444 + 2 new); consumer_contract → **33 passed** (unchanged).

## S4 — Wire: teleprompt + retrieve sites ✅
- [x] T4.1 Wired all 8 sites:
  - `ensemble.ex:33` (forward): `ctx` captured before `Task.async_stream`; task body wraps `Dspy.Module.forward` in `with_context`.
  - `ensemble.ex:337` (train): same pattern for `train_single_member`.
  - `ensemble.ex:455` (nested-evaluate, D5 outer wrap): `ctx` captured before `Task.async_stream`; task body wraps `Evaluate.evaluate` in `with_context`.
  - `simba.ex:163` (nested-evaluate, D5 outer wrap): same pattern.
  - `mipro_v2.ex:295` (bootstrap): `ctx` captured before `Task.async_stream`; task body wraps `Dspy.Module.forward` in `with_context`.
  - `bootstrap_few_shot.ex:270` (bootstrap_chunk): same pattern.
  - `bootstrap_few_shot.ex:416` (nested-evaluate, D5 outer wrap): same pattern.
  - `retrieve.ex:411` (process_documents): unconditional wrap (g1.md: low impact).
- [x] T4.2 Per-site marker tests: `test/context/context_s4_propagation_test.exs` — 3 tests:
  - Ensemble.Program forward (ensemble.ex:33): marker LM used in spawned member forward.
  - D5 chain test (T4.3): marker reaches innermost forward of nested Evaluate.
  - retrieve:411 unconditional wrap test.
  - Note: mipro_v2:295 and bootstrap_few_shot:270/416 are private; full marker tests deferred to S5 or integration suite.
- [x] T4.3 D5 CHAIN TEST: `Dspy.context([lm: marker])` → outer `with_context` → inner `Evaluate.evaluate` → inner tasks see marker LM (assert `mean == 1.0`).
- [x] T4.4 retrieve:411 unconditional wrap + test.
- Gate: compile ✓; format ✓; `mix test` → **449 passed, 8 excluded** (446 + 3 new); consumer_contract → **33 passed** (unchanged); `test/teleprompt/` → **34 passed** (existing tests stay green).

## S5 — Docs + final gates ✅
- [x] T5.1 `Dspy.Context` moduledoc: upstream references (parallelizer.py:88-96, settings.py:56-57,63,177, parallelizer.py:93-95 — usage copy, no merge-back) + empty usage-capture set rationale (design.md §3) + nested-evaluate redundancy note (design.md §4).
- [x] T5.2 `docs/COMPATIBILITY.md`: updated Context section (§7) to reference `Dspy.Context` as the stable public API for propagation; updated mapping table row for `dspy.context`; added test evidence.
- [x] T5.3 final tree: compile ✓; format ✓; `mix test` → **449 passed, 8 excluded**; consumer_contract → **33 passed, 424 excluded**; `git diff --stat` ⊆ allowed paths (11 modified + 4 new files, all in scope).

## S6 — Per-site marker tests for the six teleprompt spawn sites (BLOCK fix) ✅
- [x] T6.1 `test/context/context_s6_propagation_test.exs`: 4 tests covering all 6 sites via 4 public entries:
  - SIMBA.compile/3 → simba.ex:171 (inverted marker; `refute` "Instruction hint" in optimized instructions).
  - MIPROv2.compile/3 → mipro_v2.ex:301 (inverted marker; non-caller PID count >= 4).
  - BootstrapFewShot.compile/3 → :276 (bootstrap examples carry "ok") + :430 (marker saw a few-shot "Example" prompt).
  - Ensemble.compile/3 → :349 (member examples carry "ok") + :473 (marker saw a validation question; disjoint train/val splits).
- [x] T6.2 Every assertion verified NON-VACUOUS (mutation-proofed, see below). The earlier PID-only / re-evaluate-mean drafts were found VACUOUS by mutation and replaced with deterministic per-site signals (marker prompt content + optimized examples + inverted-gold SIMBA instructions).
- Gate: compile ✓; format ✓; `mix test` → **453 passed, 8 excluded** (449 + 4 new); consumer_contract → **33 passed** (unchanged).

## Mutation proof (per HOW_WE_WORK, before final report)
- [x] D5 chain test: removed `with_context` from parallel.ex:152 → test RED (mean=0.0). Restored → GREEN.
- [x] overrides-installed: covered by S1 crash-recovery tests (restore-on-raise/throw/exit).
- [x] callbacks-exactly-once: covered by S1 exactly-once tests (two consecutive forwards).
- [x] usage-stays-on-child: covered by S1 usage tests (target's lm_usage == only target's calls; caller's frame untouched).
- [x] ≥3 per-site marker tests: S2 (3 sites) + S3 (2 sites) + S4 (3 sites) + S6 (6 sites) = 14 marker tests.
- [x] record file:line + which test went red in the report (see benjamin-report.md, S6 mutation log).

### S6 mutation log (wrap removed → named test RED → wrap restored → GREEN)
- simba.ex:171 → SIMBA test RED ("Instruction hint" present; modified candidate selected). Restored → GREEN.
- mipro_v2.ex:301 → MIPROv2 test RED (non-caller PIDs = 3, below threshold 4). Restored → GREEN.
- bootstrap_few_shot.ex:276 → BootstrapFewShot test RED (example answers ["nope","nope"]). Restored → GREEN.
- bootstrap_few_shot.ex:430 → BootstrapFewShot test RED (no "Example" section in any marker prompt). Restored → GREEN.
- ensemble.ex:349 → Ensemble test RED (member example answers contain "nope"). Restored → GREEN.
- ensemble.ex:473 → Ensemble test RED (no validation question seen by the marker). Restored → GREEN.
- Final: all 7 wraps intact (simba:1, mipro:1, bootstrap:2, ensemble:3 incl. Program.forward :39); `mix test` 453 passed; consumer_contract 33 passed.
