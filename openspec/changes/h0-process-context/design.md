# Design — h0-process-context (`Dspy.Context`)

Worker: Benjamin (h0-B). Revised for Greta SIGN-WITH-EDITS (2026-09-26): D1-revised (API
`capture/0` + `with_context/2`, no spawning), D2 (+ save/restore, + `Dspy.context(callbacks:)`
coverage), D5 (nested-site wrap REQUIRED), D6 (crash asserts in unit tests only). 2026-09-26.

Upstream reference: `../dspy` @661a612c —
`dspy/utils/parallelizer.py:88-96` (copy parent thread-local overrides into each worker),
`dspy/dsp/utils/settings.py:56-57,63,177` (thread-local context/overrides; callbacks live inside
settings and travel with them), `dspy/utils/parallelizer.py:93-95` (each worker gets a deep copy
of `usage_tracker` — "each thread tracks its own usage" — and **nothing is merged back**).

## 1. Public API (D1-revised)

```elixir
defmodule Dspy.Context do
  # Capture the caller's process-local DSPy state NOW (cheap, pure Process.get).
  @spec capture() :: t()
  # In the CURRENT process: install captured context, run fun, restore previous values in after.
  # NO spawning, no Task, no link, no await. Returns fun's value only.
  @spec with_context(t(), (-> any())) :: any()
end
```

- **No `run/2`.** The previous draft's `run/2` (nested `Task.async`/`Task.await` inside the
  existing task body) is DROPPED: it would add a hidden 5s `Task.await` timeout and a nested
  link under each site's own timeout, changing crash/timeout behavior — forbidden (Greta edit 1).
- Every spawn site calls `with_context/2` **inside its existing task body** (§4): capture in the
  caller BEFORE the `Task.async_stream`/`Task.async` call; install in the child process via
  `with_context` at the top of the task body. The task body's process is a fresh Task process
  (nothing installed yet), so save/restore is symmetric and the child dies with the task.
- Returns the fn's value only. NO usage returned to the caller; no merge-back plumbing (D1/D3;
  upstream `parallelizer.py:93-95`: nothing merged back).
- No new public settings keys; no new process-dict keys. Only the two state families that
  already exist in `lib/` (verified complete in g1.md):
  - `{Dspy.Settings, :process_overrides}` (`lib/dspy/settings.ex:63`) — overrides, INCLUDING
    `track_usage` and `callbacks` keys when the caller set them via `Dspy.context/2`;
  - `{Dspy.Signature.Adapter.Callbacks, :stack}` (`lib/dspy/signature/adapter/callbacks.ex:11`)
    — raw per-call callback stack.
  Usage keys `{:dspy, :usage_*}` (`lib/dspy/lm/usage_acc.ex:13-15`) are deliberately NOT part of
  the capture set — see §3.

### `Dspy.Context.t()` shape (internal)

```elixir
%{
  overrides: map(),        # Dspy.Settings.current_overrides()
  callback_stack: [list()] # RAW {Callbacks, :stack} value (list of frames, caller order), or nil
}
```

### Capture semantics

`capture/0` reads (in the caller):

1. `Dspy.Settings.current_overrides()` → `map()` (settings.ex:136).
2. `Process.get({Dspy.Signature.Adapter.Callbacks, :stack})` → the **RAW stack** (list of
   callback-list frames, innermost first), or `nil` if unset.

Nothing else is read. Nothing is mutated at capture time.

### Install semantics (`with_context/2`, current process)

```elixir
def with_context(ctx, fun) do
  prev_stack = Process.get({Dspy.Signature.Adapter.Callbacks, :stack})
  install? = ctx.callback_stack != nil

  if install? do
    Process.put({Dspy.Signature.Adapter.Callbacks, :stack}, ctx.callback_stack)
  end

  # Usage: NOTHING installed (D3) — see §3.

  try do
    # Overrides: delegate to the existing save/restore helper (settings.ex:156),
    # which saves the previous frame and restores it in after.
    Dspy.Settings.with_overrides(ctx.overrides, fn -> fun.() end)
  after
    if install? do
      if prev_stack === nil do
        Process.delete({Dspy.Signature.Adapter.Callbacks, :stack})
      else
        Process.put({Dspy.Signature.Adapter.Callbacks, :stack}, prev_stack)
      end
    end
  end
end
```

- `after` restores BOTH the callback stack and (inside `with_overrides/2`) the overrides frame on
  every exit path (return, raise, throw, exit) — D6: the crash-scenario unit tests assert
  exactly this for raise, throw AND exit in the SAME process.
- `with_overrides/2` (settings.ex:156) already save/restores its own frame; reusing it keeps
  `Dspy.Settings` behavior identical (spec R3).
- No new Task, no `Task.await`, no new link/monitor: crash/timeout behavior at every site is
  structurally unchanged (§5).
- **No callback-state write-back.** Install is raw-stack save/restore ONLY. Rationale:
  the adapter pipeline re-reads `current_call_callbacks/0` at every pipeline start
  (`pipeline.ex:38`), discarding `emit/4` return values (`pipeline.ex:89,136`). A stack written
  back at the end of `fun` would never be re-read before the next forward in the same process,
  and it would flatten nested frames and re-install overrides-carried callbacks into the call
  slot — changing `merge(global, program, call)` order and double-firing the same callback on a
  second forward within the same `with_context`.

### Why the raw stack, not the flattened list (D2)

The pipeline resolves callbacks as `merge(global, program, call)` where `call =
Callbacks.current_call_callbacks()` (flattened process-local stack) —
`lib/dspy/signature/adapter/pipeline.ex:31-39`. Global callbacks come from the
`Dspy.Settings` GenServer (`:callbacks` key) and program callbacks from `opts`; both are
re-resolved in the install-target process. If we captured the *flattened* list and reinstalled
it as one per-call frame, global/program callbacks already present in the caller's flattened
list would fire **twice** in the target (once via `merge`'s global/program slots, once via the
reinstalled call frame). Reinstalling the RAW caller frames reproduces exactly the caller's own
per-call nesting in the target, so:

- global (settings) callback fires EXACTLY once per event (test a);
- caller's per-call callback (via `Callbacks.with_callbacks`) fires EXACTLY once (test b);
- callbacks set via `Dspy.context(callbacks: [cb])` travel inside the overrides map and are read
  through `Settings.get(:callbacks)` in the pipeline (pipeline.ex:31-38 → `:callbacks` key);
  they fire EXACTLY once (test c, Greta edit 5) — they never enter the captured raw stack, so
  no double-fire path exists.

## 2. Overrides capture

- Capture: `Dspy.Settings.current_overrides()` (caller).
- Install: `Dspy.Settings.with_overrides(overrides, fn -> fun.() end)` in the install-target
  process (inside `with_context/2`).
- `track_usage: true` reaches the target via this map (D3 prerequisite: `maybe_track_usage`
  checks `Dspy.Settings.get(:track_usage)` in the process that made the LM call —
  `lib/dspy/lm.ex:580`).
- `Dspy.Settings.current_overrides/0` + `with_overrides/2` keep v0.3.40 behavior unchanged
  (spec R3); `Dspy.Context` reuses them directly.

## 3. Usage — capture set is EMPTY (D3, stated explicitly)

**The usage-capture set in `Dspy.Context` is intentionally empty: no usage frame is captured from
the caller and none is installed in the target. Usage accumulators are NOT captured (spec.md).**
Rationale:

- Our usage frame is per-process (`UsageAcc.enter/exit`, `lib/dspy/lm/usage_acc.ex:17-48`) and is
  opened/closed by `Dspy.Module.forward` (`lib/dspy/module.ex:51-62`) in whatever process runs
  the forward. Seeding the target from the caller's sum would double-count the caller's
  pre-existing LM calls in the target's prediction (`metadata[:lm_usage]`).
- The target's own `Module.forward` opens its frame via `UsageAcc.enter/0` and attaches its own
  sum to its own prediction (`module.ex:89-92`) — so child usage *does* surface, on the child
  prediction, with no extra plumbing.
- No merge-back exists and is not added (D1), matching upstream `parallelizer.py:93-95`
  ("each thread tracks its own usage"; nothing merged back).
- Consequence (documented in moduledoc): an outer caller-side `track_usage` frame does NOT
  accumulate child LM usage — same as today's behavior at every spawn site (g1.md finding 2);
  it is not a regression, and fixing it is the pending user decision (proposal §Decisions),
  not H0.

Required unit tests (S1):
(a) with `track_usage: true` in the caller context, the target's (child task's) prediction's
`metadata[:lm_usage]` equals ONLY the target's LM calls;
(b) the caller's open usage frame (sum/depth/any keys) is untouched after the run;
(c) untracked caller (no open frame) gets NO `{:dspy, :usage_*}` keys in the caller afterwards.

## 4. Per-site wiring table

Pattern at ALL sites: `ctx = Dspy.Context.capture()` in the caller immediately before the
`Task.async_stream`/`Task.async` call; task body becomes
`fn item -> Dspy.Context.with_context(ctx, fn -> <existing body> end) end`.
The wrap is strictly inside the task body: timeout/`on_timeout`/linking options and
rescue/catch boundaries stay exactly where g1.md documents them (§5).

Per-site usage double-count check (does the site already aggregate usage by other means?):
NONE — verified per site below; the only double-count risk is seeding a usage frame, which
`with_context/2` never does (§3).

| file:line | What to wrap | Overrides today? | Usage aggregation in target by other means? |
|---|---|---|---|
| `lib/dspy/parallel.ex:149` (capture at :144, install :150-152) | task body of `Task.async_stream` — replace the current `Settings.with_overrides` call with `Dspy.Context.with_context(ctx, ...)` | **YES** (v0.3.42 — only site) | No — `run_pair`'s rescue/catch (parallel.ex:225-226) only; each target `Module.forward` opens its own UsageAcc frame |
| `lib/dspy/module.ex:196` | `fn -> forward(module, inputs) end` per task | No | No — target forward opens its own frame (module.ex:52) |
| `lib/dspy/evaluate.ex:104` | `fn chunk -> evaluate_chunk(...) end` | No | No — per-example rescue/catch (evaluate.ex:310+) inside the target |
| `lib/dspy/tools.ex:503` (`call_tool`) | `fn -> try do tool.function.(args) ... end end` | No | No — tool fns don't call `UsageAcc` |
| `lib/dspy/tools.ex:756` (`execute_tool`) | same shape | No | No — same as above |
| `lib/dspy/teleprompt/ensemble.ex:33` (forward) | `fn member -> Dspy.Module.forward(member, inputs) end` | No | No — `_ -> []` swallow (ensemble.ex:36-38) |
| `lib/dspy/teleprompt/ensemble.ex:337` (train) | `fn {config, idx} -> train_single_member(...) end` | No | No — `train_single_member` rescue (ensemble.ex:418) |
| `lib/dspy/teleprompt/ensemble.ex:455` | `fn member -> Evaluate.evaluate(member, ...) end` (nested) | No | No — **outer wrap REQUIRED (D5)** |
| `lib/dspy/teleprompt/simba.ex:163` | `fn cand -> Evaluate.evaluate(cand, ...) end` (nested) | No | No — **outer wrap REQUIRED (D5)** |
| `lib/dspy/teleprompt/mipro_v2.ex:295` | `fn gold -> Module.forward + run_metric end` | No | No |
| `lib/dspy/teleprompt/bootstrap_few_shot.ex:270` | `fn chunk -> bootstrap_chunk(...) end` | No | No — per-example rescue (bootstrap_few_shot.ex:323) inside target |
| `lib/dspy/teleprompt/bootstrap_few_shot.ex:416` | `fn candidate -> Evaluate.evaluate(candidate, ...) end` (nested) | No | No — **outer wrap REQUIRED (D5)** |
| `lib/dspy/retrieve.ex:411` | `fn doc -> safe_process_single_document(...) end` | No (g1.md: no settings read in child — low impact; wrap for uniformity) | No — safe_call rescue/catch (retrieve.ex:511, 516) inside target |

### Nested-evaluate sites — outer wrap REQUIRED, NOT redundant (D5)

ensemble.ex:455, simba.ex:163, bootstrap_few_shot.ex:416 run `Dspy.Evaluate` inside a task.
`Dspy.Evaluate` captures context INSIDE its own task processes. Chain: outer caller
(`Dspy.context(lm: marker)`) → outer task (holds the captured ctx only via the outer wrap) →
inner `Evaluate` captures in the outer task process → inner tasks install it. **Without the
outer wrap the outer task process holds nothing, and the inner evaluate's tasks see only global
settings** — the marker LM is lost. Hence:

- the outer wrap at these 3 sites is REQUIRED;
- required **chain test** (S4): `Dspy.context(lm: marker)` around an Ensemble/SIMBA evaluation —
  the marker LM is used in the INNERMOST forward (inside the inner evaluate's tasks), not just
  in the outer task.

## 5. Crash/timeout invariants (g1.md crash table — must NOT change; D6)

- `Dspy.Context` introduces NO new Task, link, or monitor: `with_context/2` runs in the current
  process and restores in `after`. The existing task bodies are unchanged except for the wrap.
- `timeout:` / `on_timeout: :kill_task` options and their handlers stay where g1.md lists them
  (parallel.ex:170; retrieve.ex:511/516; evaluate.ex:310+; etc.).
- The existing per-site rescue/catch boundaries are unchanged (tools.ex:506-514 / 758-764
  rescue-only — linked-exit-kill-caller behavior is UNCHANGED and is H0b's job, not H0's).
- Crash-scenario asserts live in the `with_context` UNIT tests only (D6): raise, throw AND exit
  inside `fun` restore the previous overrides frame and callback stack in the SAME process.
  Per-site crash behavior is stated unchanged and left for H0b.

## 6. Backward compatibility

- `Dspy.Settings.current_overrides/0`, `Dspy.Settings.with_overrides/2`, `Dspy.Settings.context/2`
  unchanged in behavior (spec R3; `test/settings_context_test.exs` + 33 consumer_contract
  tests pass without modification).
- `Dspy.Parallel.run/3` keeps its public behavior (returns, error tuples, `:max_errors`);
  internally its overrides-only capture is replaced by `Dspy.Context` (adds callback-stack
  propagation — additive; `test/parallel_test.exs` must stay green).
- New module `Dspy.Context`; no new options anywhere; no new settings keys; no new deps.

## 7. Upstream divergence notes

- Upstream carries callbacks *inside* the thread-local overrides (settings key); we ALSO capture
  the raw process-local per-call stack separately, because our pipeline re-resolves
  global/program callbacks in the install-target (pipeline.ex:31-39) and a flattened-list copy
  would double-fire. Overrides-carried callbacks (`Dspy.context(callbacks:)`) travel with the
  overrides map and are covered by the exactly-once tests (D2 c).
- **No callback-state write-back** (diverges from the S1 draft): `with_context/2` install is
  raw-stack save/restore only. The adapter pipeline re-reads `current_call_callbacks/0` at every
  pipeline start (`pipeline.ex:38`), discarding `emit/4` return values (`pipeline.ex:89,136`).
  A write-back at the end of `fun` would (a) never be re-read before the next forward in the
  same process (dead code for consumers), and (b) flatten nested frames and re-install
  overrides-carried callbacks into the call slot — changing `merge(global, program, call)` order
  and double-firing the same callback on a second forward within the same `with_context`.
  Guarded by the "two consecutive forwards" unit test (S1-fix).
- Upstream deep-copies `usage_tracker` into workers; we install nothing (D3) — observable
  behavior parity (target tracks its own usage; nothing merged back), mechanism simpler.
