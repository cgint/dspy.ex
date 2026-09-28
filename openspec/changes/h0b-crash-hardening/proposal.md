# H0b — crash/timeout hardening at every spawn site

Status: **DRAFT (Greta 2026-09-26)**. Clarity Gate: Horst ✓ 2026-09-26 / Greta ✓ 2026-09-26. **No controller launch before both ticks.**
Groundwork: `plan/research/pi_handoffs/h0b/PACKAGE.md` (+ g2.md, g3.md). Reference: Python DSPy **3.4.0** (`../dspy-3.4.0`); line refs below are re-verified at 3.4.0.
Slices: **H0b-1** runtime sites (Module.parallel, tools ×2, ensemble ×3, simba, mipro, bootstrap ×2) · **H0b-2** Evaluate (+ `max_errors` setting). H0b-1 can ship alone; H0b-2 is the M1 prerequisite.

## Why
Today a raise/throw/exit or timeout inside a spawned task at 11 sites kills the caller (linked tasks, default `on_timeout: :exit`), or silently drops work (Evaluate chunks). The Ensemble forward also misaligns weights with members after any member failure (a bug). Upstream isolates each item (`dspy/utils/parallelizer.py:63-67`), keeps results index-aligned, and never lets one item take down the run.

## (a) Contract

### A1. Upstream target semantics (reference)
- **U1 per-item isolation:** the worker catches `Exception` and records the failure for that item; results stay index-aligned (`parallelizer.py:63-67`; `evaluate/evaluate.py:179-181`).
- **U2 error budget:** `settings.max_errors = 10` (`dsp/utils/settings.py:32`). Parallelizer/Evaluate take `max_errors=None → settings` (`parallelizer.py:37`, `evaluate.py:168`). When the budget is reached: cancel pending work, then raise "Execution cancelled due to errors or interruption." (`parallelizer.py:66, 103-104`).
- **U3 timeout (soft):** stragglers (≤3) are resubmitted after 120s; nothing is killed (`parallelizer.py:29-30, 207-215`).
- **U4 Evaluate:** a failed example scores `failure_score` (default `0.0`, `evaluate.py:81`), which is **included in the mean**; `assert len(devset) == len(results)` (`:179-181`).

### A2. Decisions — **user approved D-U1, D-U2, E6 = upstream on 2026-09-28** (commit 0d8afdb). **H0b-2 is UNBLOCKED** (it starts after H0b-1 is released).
- **D-U1 = upstream U4** *(user approved 2026-09-28)*: Evaluate failures count as `failure_score` in the mean. **Reported scores can drop.**
- **D-U2 = upstream U2** *(user approved 2026-09-28)*: new `Dspy.Settings` key `max_errors`, default `10`; `Dspy.Evaluate.evaluate/4` options `:max_errors` (nil → setting) and `:failure_score` (default `0.0`).
- **E1 hard deadline instead of U3:** `on_timeout: :kill_task`; a timed-out item becomes a per-item error value. Reason: BEAM kills a task safely; upstream resubmits only because Python threads cannot be killed.
- **E2** `Dspy.Parallel` keeps its existing `{:error, {:max_errors_exceeded, …}}` return (Elixir idiom, existing public shape). This slice does not change it.
- **E3 sites with no upstream equivalent** (Module.parallel, tools ×2, ensemble compile ×2): U1 + E1; the caller never dies.
- **E4 Ensemble forward:** upstream is serial and propagates exceptions (`teleprompt/ensemble.py:31-33`). Ours is parallel (existing) → U1 + E1; **member↔weight alignment is kept** (bug fix); `:all_ensemble_members_failed` is unchanged.
- **E5 (Horst ✓ 2026-09-26 — upstream cancels + raises, parallelizer.py:102-104): Evaluate when the budget is exceeded** raises `Dspy.Evaluate.MaxErrorsExceeded` (message and fields: `:errors`, `:max_errors`, `:completed`) after killing the pending tasks. Reason: upstream raises; `evaluate/4` returns a plain result, not a tuple, so raising keeps its return shape. Alternative considered: a `{:error, …}` tuple, rejected because it changes the success return shape.
- **E6 (user approved 2026-09-28):** teleprompter-internal evaluation (simba/mipro/bootstrap/ensemble compile) inherits `max_errors` from Settings as upstream does. A compile with ≥10 failing candidate runs therefore stops with the raise. This is upstream behaviour and is listed in the user note together with D-U1/D-U2.

### A3. Per-site target — the process each piece runs in
Two existing shapes (verified at HEAD `65b196c`, `rg Task\. lib`); **no new process is created in either**:
- **Stream sites** (evaluate:108, ensemble:37/347/473, simba:169, mipro:299, bootstrap:274/428; parallel:150 and retrieve:415 are the references): the body runs in a `Task.async_stream` child, started by the caller and linked to it. Inside the child: `Dspy.Context.with_context(ctx, fn -> … end)` (H0, unchanged) wrapped in a **catch-all in the child** (`rescue e` + `catch kind, reason`) that returns an item-error value. The **caller** consumes the stream with `on_timeout: :kill_task` and matches `{:ok, _}` / `{:exit, :timeout}` / `{:exit, reason}` exhaustively.
- **`Task.async` sites** (tools:507, tools:766, module:200): the body runs in a `Task.async` child, linked to the caller. The same child-side catch-all is used. The caller waits with `Task.yield` / `Task.yield_many` + `Task.shutdown(task, :brutal_kill)` (tools already do yield+shutdown; **Module.parallel replaces `Task.await_many`**, whose default 5 s timeout exits the caller, with `yield_many(tasks, timeout)` + shutdown of the non-returned tasks; `:timeout` is a new option, default `:infinity`, so today's no-timeout behaviour stays but the caller no longer exits). The caller matches `{:ok, _}` / `{:exit, _}` / `nil`, so tools no longer hit a `CaseClauseError` when `shutdown` returns `{:exit, _}`.
- `lib/dspy/settings.ex:152` and `lib/dspy/context.ex:63/96` are **doc examples**, not sites.

| Site | Target | Today → change (observable) |
|---|---|---|
| `lib/dspy/parallel.ex:150` | unchanged (reference implementation) | – |
| `lib/dspy/retrieve.ex:415` | unchanged (reference implementation) | – |
| `Dspy.Module.parallel` | U1+E1. The first error in module order is returned as `{:error, reason}` (as today). A crash becomes `{:error, {:raised \| :thrown \| :exit, …}}` and a timeout becomes `{:error, :timeout}` | caller death → error tuple (bug fix) |
| `lib/dspy/evaluate.ex:108` (H0b-2) | per-item U1+E1; `items`/`scores` aligned 1:1 with the testset (length assert); failure → `failure_score` counted in the mean (D-U1); budget → E5 | chunks silently dropped / failures excluded → counted |
| `lib/dspy/tools.ex:507`, `:766` | also catch throw/exit → the **existing** shapes `"Tool execution failed: …"` / `{:error, msg}` | throw/exit killed the caller (bug fix) |
| ensemble forward `:37` | U1+E1, alignment kept (E4) | timeout killed the caller; weights shifted |
| ensemble compile `:347`, `:473`; `simba:169`; `mipro_v2:299`; `bootstrap_few_shot:274`, `:428` | U1+E1; a failed item counts as a failed candidate/score, the same as Evaluate semantics | compile died (bug fix) |

### A4. Invariants
1. The caller process never dies because a child raises, throws, exits or times out at any listed site.
2. A timed-out child is **dead** when the call returns (`on_timeout: :kill_task` or `Task.shutdown`); no orphaned tasks.
3. Result order and length equal the input order and length at every site.
4. H0 propagation: `with_context` stays inside every task body; `test/context/**` stays green unchanged.
5. Success-path return shapes are unchanged. Error shapes are unchanged except where the table says "→".

### A5. Forbidden mechanisms
- `Process.flag(:trap_exit, true)`; `Task.Supervisor.start_link` per call; any new spawn, link or monitor beyond the existing `async_stream`.
- `try/rescue/catch` **around the stream in the caller** as the fix. The catch lives in the child body.
- Mocking `Task`/`Task.Supervisor`; `Process.sleep`-only timeout tests without kill evidence.
- Editing asserted shapes in existing tests; any diff under `test/consumer_contract/**`, `mix.exs`, `mix.lock`.
- A new process-dictionary key, a global `Dspy.Application` supervisor child (not needed; body-catch + `kill_task` chosen).

### A6. Non-goals
- Merging usage back into the caller (closed in H0: Option A, matching upstream). *Note: the checklist line in HOW_WE_WORK "usage merge-back into the caller" contradicts this; Horst to fix.*
- Straggler resubmission (U3); a supervisor tree; changes to `Dspy.Parallel`'s budget shape; the EvaluationResult struct and the other Evaluate options (M1).

## (b) Team card (Horst, 2026-09-26)
- **Order:** H0b-1 first (runtime sites, needs no user answer). H0b-2 (Evaluate) only after the user has answered D-U1/D-U2 and it has been released; a separate launch reuses this card.
- **Roles:** Horst (lead, `w1:p4`) launches **Katrin** (controller, editable herdr pane). Katrin launches **Lukas** (worker, editable, the only lib editor) and **Mara** (reviewer, readonly). Greta (`w1:p1`) gives the outside verdict at the end. Katrin talks only to Horst, and Lukas/Mara only to Katrin.
- **Models:** launcher default (home-llm) for all three.
- **Sub-steps (H0b-1):** S0 echo-back (e) → Horst "go" · S1 `Task.async` sites (tools ×2, Module.parallel incl. yield_many + `:timeout`) · S2 stream sites (ensemble ×3, simba, mipro, bootstrap ×2) · S3 docs (COMPATIBILITY). Each step gets tests first, then the mutation proof, then a Mara review (≤3 rounds).
- **Gates (Katrin runs on the final tree, pastes output):** compile --warnings-as-errors · format --check-formatted · `mix test` · `--only consumer_contract` (33) · the H0 propagation tests green · `scripts/consumer_canary.sh` · `git diff --stat` within the allowed paths · no `*.bak`/scratch files.
- **Decisions returning to Horst:** anything not covered by (a), any wish to change a public shape, any "cannot test" claim (with evidence), timebox overrun. Katrin decides everything else.
- **Evidence:** `plan/research/pi_handoffs/h0b/` (controller-report.md, member reports, mutation log with shasums).
- **Timebox:** S0 20 min · S1 90 min · S2 120 min · S3 20 min. On overrun, stop and send a partial report.
- **Allowed writes:** the site files in A3, `lib/dspy/settings.ex` (H0b-2 only), new tests under `test/`, this change folder, `docs/COMPATIBILITY.md`, `plan/research/pi_handoffs/h0b/**`, `tmp/**`. Forbidden: see A5, plus `test/consumer_contract/**`, mix.exs/lock, VERSION, RELEASES, git add/commit/push.

## (c) Acceptance map (every test through the public entry point; each mutation must turn it red, then be reverted with shasum proof)
| # | Scenario | Test (new, `test/h0b/…`) | Mutation → the wrong implementation it catches |
|---|---|---|---|
| 1 | child **raise** at each of the 11 sites → caller alive, per-site failure shape asserted with its reason contents | `site_raise_test.exs` (one `describe` per site) | remove the child catch-all → caller exits (test process dies / `assert_receive` fails) |
| 2 | child **throw** and **exit** at tools ×2 + Module.parallel | `site_throw_exit_test.exs` | `rescue` only (no `catch`) → red |
| 3 | child **timeout** → error value; the timed-out pid is dead afterwards and its post-sleep side effect (message to the test pid) never arrives | `site_timeout_test.exs` | `on_timeout: :exit` (default) → caller exits; without `:kill_task` the side effect arrives → red |
| 4 | Ensemble forward: member 2 of 3 fails → weights stay aligned to members 1 and 3 (distinct weights, weighted-vote outcome differs if shifted) | `ensemble_alignment_test.exs` | positional zip after `flat_map` drop → wrong winner |
| 5 | Evaluate: 1 of 4 examples raises → `length(items)==4`, failed score `== failure_score`, mean includes it (e.g. (1+1+1+0)/4) | `evaluate_failure_score_test.exs` | exclude failures from the mean → 1.0 ≠ 0.75 |
| 6 | Evaluate `max_errors: 2`, 3 failures → raises `MaxErrorsExceeded`; pending tasks are killed (no side effects after the raise) | `evaluate_max_errors_test.exs` | never stopping / not killing → red |
| 7 | `max_errors` setting default 10 and override via `Dspy.context` | `settings_max_errors_test.exs` | default nil → red |
| 8 | ordering/length preserved under mixed success/failure at every site | in #1 per site | returning only successes → length assert red |
| 9 | H0 regression | existing `test/context/**` unchanged | – |
| 10 | teleprompter compile survives failing candidates (simba/mipro/bootstrap/ensemble) and still returns a program | `teleprompt_survival_test.exs` | remove the catch in one site → compile raises |

Outside verdict: **Greta** (independent: reads the diff, reruns the gates and 3 mutations of her choice).

## (d) Pre-mortem → guards
1. A rescue-all fabricates success (`{:ok, nil}`) → #1 asserts reason contents; mutation: drop the reason.
2. `trap_exit` or orphaned tasks → grep of the forbidden list in review; #3 kill evidence.
3. Shape drift plus edited tests → `git diff test/` shows only additions; zero diff under `consumer_contract`.
4. Timeout tests that check only the tuple → #3 requires pid-dead plus no side effect.
5. The concurrency path is dead in tests (for example `max_concurrency: 1` hides ordering bugs) → every arm is hit by a real slow or crashing process, `max_concurrency ≥ 2`.
6. (from H0) Tests that go around the public entry point → every test goes through the public API of its site.

## (e) Controller echo-back — required before the first edit
Restate verbatim: A3's process sentence, the E5 exception name and fields, the new option names and defaults. Give one own-words sentence per invariant A4.1–5. Any difference = a gap → back to Horst/Greta.

## (f) Evidence
`Clarity Gate: Horst ✓ 2026-09-26 <date> / Greta ✓ 2026-09-26` (team card present, E5 ✓, E6 → user note, `openspec validate` green).
