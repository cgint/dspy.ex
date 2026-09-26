# h0-process-context — carry per-process DSPy state across spawned work

Status: DRAFT (Horst) — awaiting Greta sign-off. 2026-09-26.

## Why
DSPy state that users set per call lives in the process dictionary and is lost whenever dspy.ex spawns work:
- settings overrides (`Dspy.context/2`, `lib/dspy/settings.ex:162`);
- usage accumulation (`Dspy.LM.UsageAcc`, `lib/dspy/lm/usage_acc.ex:9-11`) — outer `track_usage` silently misses child LM usage;
- adapter callback stack (`lib/dspy/signature/adapter/callbacks.ex:31`) — callbacks registered by the caller don't fire in children.

Only `Dspy.Parallel` carries overrides (v0.3.42); nothing carries usage or callbacks. Upstream (../dspy @661a612c) merges a copy of parent overrides into each worker (`dspy/utils/parallelizer.py:88-96`), only via DSPy primitives (`dspy/dsp/utils/settings.py:56-57,63,177`); callbacks live in settings and travel with overrides; each worker gets a deep copy of `usage_tracker` (`parallelizer.py:93-95`) and **nothing is merged back**. Evidence: Greta/Ida audit `plan/research/pi_handoffs/_runs/g1.md`.

## What
1. One public helper module `Dspy.Context` that captures the caller's process-local DSPy state and runs a function in a child with it installed, returning the function's value unchanged (no usage merge-back — see Decisions).
2. Use it at every spawn site that runs user programs/LM calls:
   `lib/dspy/parallel.ex` (replace current overrides-only code), `lib/dspy/module.ex:196` (`Module.parallel`), `lib/dspy/evaluate.ex:104`, `lib/dspy/tools.ex:503,756`, `lib/dspy/teleprompt/ensemble.ex:33,337,455`, `simba.ex:163`, `bootstrap_few_shot.ex:270,416`, `mipro_v2.ex:295`, `lib/dspy/retrieve.ex:411`.
3. Keep `Dspy.Settings.current_overrides/0` / `with_overrides/2` working (consumer-visible since v0.3.40); they may delegate.

## Decisions (answers to Greta's contract questions)
- **Usage merge:** H0 follows upstream (option b): **no merge-back** of child usage into the caller (`parallelizer.py:93-95`); child usage stays on the child prediction as today. **User decision 2026-09-26: follow Python DSPy (the reference) — no merge-back.** Option (a) is closed.
- **Callback ordering:** no ordering guarantee *between* concurrent children; within one child, start-before-end ordering holds as today. Callbacks run in the child process.
- **`Module.parallel`:** in scope.

## Non-goals
- No implicit propagation via `$callers`/`$ancestors`; code that spawns its own processes uses explicit capture/run.
- Crash/timeout hardening (linked crashes, missing `on_timeout: :kill_task` at ensemble.ex:33, mipro_v2.ex:295) → separate slice **H0b**. H0 must not change crash/timeout behavior at the listed sites except where `Dspy.Parallel` already defines it.
- No change to cache keys, LM request maps, or `test/consumer_contract/**`.
- No new settings keys.

## Risks
Invariant-touching (process context) → Greta co-signs design.md. Usage double-counting if a site already aggregates usage by other means — design must check each site.
