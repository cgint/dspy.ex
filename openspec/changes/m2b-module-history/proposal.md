# M2-b — Module history (`Module.inspect_history`)

Status: **DRAFT (Greta 2026-09-29)** — an options paper plus a contract for the recommended option. **Touches process context (the H0 invariant): needs my co-sign, which I give only to option C as specified in A3.** Needs Horst's rulings on H1–H3.
Base: `main` at `8390cfb`. Findings: `plan/research/m2/2026-09-29-m2-findings.md` F-6.
Queue: `PARITY_QUEUE.md` §M2 — S054 facet f7 (`Module.inspect_history`, old P5).

Reference, anchored to DSPy **3.4.0**:
- `primitives/module.py`: `self.history = []` on every module `:78`; `Module.__call__` appends `self` to `settings.caller_modules` and runs `forward` inside `settings.context(caller_modules=…)` `:94-111`; `inspect_history(n=1, file=None)` → `pretty_print_history(self.history, n)` `:254-268`; history excluded from pickling `:81-91`.
- `clients/base_lm.py`: `record_history` `:20-33` — returns early if `settings.disable_history`; appends to `GLOBAL_HISTORY`; returns if `settings.max_history_size == 0`; otherwise appends the **same entry** to the LM client's history **and to every module in `caller_modules`**, each capped at `max_history_size`. Defaults: `disable_history=False`, `max_history_size=10000` (`dsp/utils/settings.py:24,35`).
- Because `caller_modules` is a settings override, `Parallel`'s per-thread override copy carries it into worker threads, so calls made in parallel are attributed to the calling module.
- **Oracle:** `tests/primitives/test_base_module.py` — `test_module_history` `:391` (entry in every ancestor; accumulates across calls; `disable_history`; re-enable), `test_module_history_with_concurrency` `:441` (Parallel over the same program → 2 entries), `test_module_history_async` `:472`; `tests/predict/test_predict.py` — `test_per_module_history_size_limit` `:1047`, `test_per_module_history_disabled` `:1056`; `tests/clients/test_typesafe.py:128` (`max_history_size: 0` keeps global history).

Facts about our side (read at `8390cfb`):
- Global history exists: `Dspy.LM.History` (a named GenServer, cap `history_max_entries`, default 200), fed from **one** call site, `lm.ex:601`; `Dspy.inspect_history/1` prints it (`dspy.ex:170`).
- **Our history entries hold no prompt and no answer**: `request: summarize_request(request)` is `%{message_count: n}` (`lm.ex:644-652`); no outputs are recorded at all. So today's `Dspy.inspect_history` is **not** upstream's (which prints messages and the response). The inventory marks it *done*; it is *partial*. → H3.
- `Dspy.Module.forward/2` (`module.ex:50`) is the single wrapper around every module call; it already opens a **per-call, process-local frame** for usage (`Dspy.LM.UsageAcc`) and attaches the total to the outermost `%Prediction{}` as `:lm_usage`. That is our precedent for per-call attribution.
- H0's `Dspy.Context.capture/0` + `with_context/2` carries **Settings overrides** (and the callback stack) into all 13 library spawn sites. H0 decided usage frames are *not* carried (upstream deep-copies its usage tracker per thread, no merge-back).

## Why
`inspect_history` is how users see what their program actually sent to the LM. The M2 exit example requires that a program's history shows *only that program's* calls.

## The design problem, stated plainly
Upstream appends to a mutable list **stored on the module object**, and finds "the calling modules" by object reference. Our modules are immutable structs: there is no object to append to and no identity to find it by. Any port has to answer two questions: *where do the entries live*, and *which module does a call belong to*.

## Options

| | A. Upstream shape: identity + store | B. Tag the global history, filter by identity | **C. BEAM-native: history travels with the call (recommended)** |
|---|---|---|---|
| API | `Dspy.Module.inspect_history(module, n)` | same | `Dspy.Module.inspect_history(result, n)`; `Dspy.with_history(fun) :: {value, entries}` |
| Where entries live | a global store keyed by module id | the existing global history, each entry tagged with the caller stack | a **per-call frame** that dies with the call; entries attached to the result |
| Module identity | **every module struct needs an id** (Predict, CoT, every user module) | same | **none needed** |
| Copy semantics | a struct copy shares its id, so an optimised copy **shares** history; upstream's `deepcopy` copies and then diverges | same | n/a — each call has its own history |
| Memory | **grows forever**: module values are never "dropped", so every `Predict.new` leaves up to `max_history_size` entries behind. Our consumers create a `Predict` **per request** — a production leak | bounded by the global cap, but a busy app evicts a module's history within 200 calls | bounded per call; nothing global |
| Async tests | a new global store (M1-a flakiness lessons) | global history shared by all tests | nothing global; a frame belongs to one call |
| Upstream parity | closest API; semantics differ on copies | weaker | different **API shape**; same attribution rules (every ancestor gets the entry; parallel calls attributed; `disable_history`; per-frame cap) |
| Cost | high (identity in every struct, supervised store, cleanup policy) | medium | medium (one Settings key, one hook in `Module.forward`, one in the LM record path) |

**Recommendation: C.** A and B both need an identity that Elixir values do not have, and A leaks memory in exactly the way our consumers use the library. C gives users what `inspect_history` is for — "what did *this* program send and receive" — without any global state, and keeps upstream's attribution rules. The one thing C cannot do is "history accumulates on the module object across calls"; `Dspy.with_history/1` covers that need explicitly (like `ExUnit.CaptureLog`). Declared in COMPATIBILITY.

## (a) Contract (option C)

### A1. API
```elixir
Dspy.Module.inspect_history(result, n \\ 1) :: :ok
#   result: {:ok, %Dspy.Prediction{}} | %Dspy.Prediction{}; prints the last n entries (same format as Dspy.inspect_history/1)
Dspy.Module.history(result) :: [entry]        # the entries attached to that result, oldest first
Dspy.with_history(fun) :: {fun_result, [entry]} # every LM call made while fun runs, in this process and its spawned tasks
```
Entries are attached to a successful `%Dspy.Prediction{}` as `metadata[:lm_history]`. An `{:error, _}` result carries none (there is nowhere to put them); `with_history/1` captures them regardless.

### A2. Entry content (H3)
Each entry gains upstream's two useful keys: `messages` (the request messages as sent) and `outputs` (the LM's text outputs), alongside today's `at`, `model`, `cache_hit?`, `duration_ms`, `usage`. The same entry map goes to the global history and to every open frame (upstream shares one entry object across owners). `Dspy.inspect_history/1` then prints messages and outputs, as upstream's `pretty_print_history` does.

### A3. Mechanism — process-scoped, reuses H0 (my co-sign condition)
- **A frame** is an unnamed `:ets` table (`:public`, `:ordered_set`), created by the process that calls `Dspy.Module.forward/2` or `Dspy.with_history/1`, keyed by `:erlang.unique_integer([:monotonic, :positive])` so order is arrival order.
- **The frame stack** is a new Settings key, `:history_frames` (list, innermost first), installed with `Dspy.Settings.with_overrides/2` for the duration of the call. Because it is a Settings override, **H0's `Dspy.Context.capture/0` already carries it into all 13 spawn sites** — `Parallel`, `Evaluate`, the optimizers. `Dspy.Context` itself is **not changed**.
- **Recording:** at the single record site (`lm.ex:601`), after the global record, the entry is inserted into **every** table in `:history_frames` (upstream: every module in `caller_modules`). An insert into a table that no longer exists (its owner finished, timed out or crashed) is caught and dropped: **history must never make an LM call fail.**
- **Nesting:** each `Module.forward/2` pushes its own frame; an inner module's result gets the inner calls, the outer result gets all of them (upstream `test_module_history`: 1 / 2 / 2).
- **Closing:** after `forward` returns, the frame's entries are read in key order, the table is deleted (in an `after`, so a raise or throw cannot leak it), and the entries are attached to the result.
- **Settings:** `disable_history: false` (upstream name; `true` → no global and no frame recording) and `max_history_size: 10000` (upstream name and default; per-frame cap keeping the newest; `0` → frames off, global history kept). The existing `history_max_entries` stays the global cap.
- **Why not reuse `UsageAcc`:** usage frames are deliberately *not* carried into child tasks (H0 D3, upstream parity for usage), while history *must* be (upstream attributes parallel calls). Different upstream semantics, different carrier.

### A4. Invariants
1. No module struct gains a field; no global store beyond the existing `Dspy.LM.History`.
2. A frame never outlives its call: the table is deleted in `after`, on success, raise, throw and exit.
3. Recording can never fail an LM call (dead-table inserts are caught).
4. H0: `Dspy.Context` unchanged; the 13 spawn sites unchanged; the new key travels as an ordinary Settings override.
5. `:lm_usage` semantics unchanged; `test/consumer_contract/**` unchanged.
6. No `:rand`, no named tables, no registered processes (async-safe by construction).

### A5. Forbidden
A global per-module store; an id field in module structs; `Process.put` for the frame stack (it would not reach spawned tasks); named ETS tables; letting a history error propagate into the LM call; changing `Dspy.Context`.

### A6. Non-goals
`module.history` accumulating across calls on the same value (declared; use `with_history/1`); LM-client history (`lm.history`, `lm.inspect_history`); `Module.inspect_history` for `{:error, _}` results; async (Python `acall`) history.

## (c) Acceptance map
Tiers: **[T]** ported upstream test (reshaped to C where marked) · **[–]** contract behaviour. **Shapes** = which call shapes the row covers.

| # | Tier | Scenario | Shapes | Mutation that must turn it RED |
|---|---|---|---|---|
| 1 | T* | `test_module_history` reshaped: a program whose `forward` calls a CoT → program result has 1 entry, the CoT result (called directly) has 1, and a second top-level call's result has 1 (not 2 — per call) | nested module; direct sub-module call | inserting only into the innermost frame (outer result → 0) |
| 2 | T* | same entry in outer and inner result: `outputs` equal to the scripted LM output | nested | entries attached without `outputs` |
| 3 | T* | `test_module_history_with_concurrency` reshaped: `Parallel` over the program twice **inside** `with_history/1` → 2 entries; each `Parallel` result has 1 | `Parallel` (spawned tasks) | frame stack kept in `Process.put` (children record nothing → 0) |
| 4 | – | `Evaluate` inside `with_history/1` over 3 examples → 3 entries | `Evaluate` (per-item tasks) | same as row 3 |
| 5 | T | `disable_history: true` → no global entry and no frame entries (`test_per_module_history_disabled`). Asserts on the VM-global history, so the test file is **`async: false`** (M1-a flakiness lesson) | global + frame | flag checked for frames only |
| 6 | T | `max_history_size: 5` over 10 calls inside one `with_history/1` → the newest 5 (`test_per_module_history_size_limit`). The scripted LM answers `"1"`…`"10"` so the kept entries are distinguishable — with identical answers "oldest 5" and "newest 5" look the same | cap | keeping the oldest 5 |
| 7 | T | `max_history_size: 0` → frames empty, global history still recorded (`test_zero_local_history_limit_preserves_global_history`); **`async: false`**, as row 5 | cap 0 | 0 disabling global too |
| 8 | – | **Isolation:** two programs called concurrently in two unrelated processes → each result contains only its own call's entries | concurrent, unrelated | recording into a global/shared frame |
| 9 | – | **Frame cleanup:** after a forward that returns, raises, throws, and exits, no frame table remains (`:ets.info/1` on the captured tid → `:undefined`) | 4 exit kinds | deleting the table outside `after` |
| 10 | – | **Late recorder:** a process started by user code with `Dspy.Context.capture/0` + `with_context/2` (so it carries the frame stack) calls the LM **after** the frame's call has returned; its LM call still returns `{:ok, _}` and nothing crashes. (A timeout-killed task cannot be the late recorder — it is killed with its parent's stream.) | dead table | uncaught `ArgumentError` from `:ets.insert` |
| 11 | – | `{:error, _}` result carries no history; the same failing call inside `with_history/1` still yields its entry | error result | `with_history/1` implemented by collecting only the entries attached to successful results (→ 0 entries) |
| 12 | – | `Dspy.inspect_history/1` and `Module.inspect_history/2` print the messages and the output text (captured IO contains the scripted answer) | global + module | printing without outputs |
| 13 | – | `:lm_usage` still attached exactly as before when `track_usage: true`, alongside `:lm_history` | usage + history | history overwriting metadata |
| 14 | – | H0 context tests, H0b-2, M1 suites, consumer canary: green, unchanged | – | – |

## (d) Pre-mortem
1. **Frame stack in the process dictionary** (like `UsageAcc`). Every single-process test passes; every call made through `Parallel`/`Evaluate` silently goes missing. → Rows 3, 4.
2. **A global `%{module_id => entries}` map** "because upstream has `module.history`". Passes all per-call tests; leaks under per-request `Predict.new`. → A4.1/A5; row 8.
3. **Records into the innermost frame only.** The inner result looks right; the outer is empty. → Row 1.
4. **Forgets that a spawned child can outlive the frame.** A timeout-killed parent leaves a child whose next record raises inside the LM call. → Row 10.
5. **Keeps the `%{message_count: n}` summary.** Every count-based test passes; `inspect_history` still cannot show a prompt. → Rows 2, 12.
6. **Deletes the table only on the success path.** → Row 9 exercises all four exit kinds.

## (e) Echo-back
The A1 API; why option C and not A (identity, leak); the A3 carrier (Settings override, not the process dictionary, and why `UsageAcc` is not reused); one sentence per A4 invariant.

## Decisions for Horst
- **H1 — Option C** (recommended) over A or B. If A is preferred, it needs an id field in every module struct, a supervised store, and a cleanup policy against the per-request leak — a larger slice, and I would want to see the cleanup policy before co-signing.
- **H2 — Declare the API-shape deviation**: history lives on the *result* (and in `with_history/1`), not on the module value; "accumulates on the module across calls" is not ported.
- **H3 — Entry content**: add `messages` and `outputs` to history entries. That also fixes today's global `Dspy.inspect_history`, which prints neither — **the inventory's "done" status for `dspy.inspect_history` is wrong and should read *partial*** until this lands. Memory note: full messages in the global history (cap 200) and per call; acceptable, but it is more data held than today.

## (b) Team card — Horst.

## (f) Clarity Gate
- Greta ✓ **for option C as specified in A3 only** (co-sign on the process-context invariant): the carrier is a Settings override, `Dspy.Context` is unchanged, frames are deleted in `after`, and dead-table inserts are caught. Any change to those four points comes back to me.
- Horst ☐
