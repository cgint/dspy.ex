# SLICE_LOOP.md — autonomous parity slices without breaking consumers

Created 2026-09-26. Mandate: `agent/USER.md` (2026-09-26 entry).
Work queue: `plan/PARITY_QUEUE.md`.

## Roles

- **Lead (planner model):** picks the next slice, writes the handoff, reviews diffs, runs gates, commits, tags, updates docs. Only the lead accepts.
- **Workers (home-LLM via Herdr, `PI_WORKER_DEFAULT_MODEL`):** implement one bounded slice with tests; separate read-only reviewer worker for non-trivial slices.
- The user is not asked between slices. Escalate only for: breaking-change decisions, dependency changes, or a failed gate that has no clean root-cause fix.

## Consumers (read-only for us)

`~/dev/{agent-coding-gui,elix-live-chat,third-eye-liveview,finance-partner,my-speech-google}` depend on `{:dspy, git: "https://github.com/cgint/dspy.ex.git"}` (tracking `main`). Their lockfiles pin commits, so a push to `main` reaches them only when they run `mix deps.update dspy`. Treat every push to `main` as a release anyway.

The frozen surface is `test/consumer_contract/` (tag `:consumer_contract`). Source inventory: 2026-09-26 scout (14 items: Signature DSL incl. `type: :json, schema:`, `LM.new/2` opts, `configure/1` keys, JSONAdapter + `output_contract/1`/`format_instructions/1`, `Signature.parse_outputs/2`, `Predict.new/1,2`, `Module.forward/2` → `%Prediction{attrs:}`, `Prediction.new/1`, `Settings.get/0,1`, `Attachments.new/1`, `:dspy` app env attachment keys, error tuples incl. `{:output_parse_failed, reason, %{raw_output:}}`).

## Rules for every slice

1. **Additive only.** New modules/functions/options with defaults preserving current behavior. No renames/removals, no changed return shapes or error tuples, no new required options.
2. **Never edit `test/consumer_contract/`** in a feature slice. Changing it = breaking change = escalate to user.
3. **No new deps** without escalation (`mix.exs`/`mix.lock` untouched).
4. Upstream reference is `../dspy` (Python). Port user-facing behavior, BEAM-idiomatic internals (see `plan/PORTING_CHARTER.md`).
5. Deterministic tests only (mock LMs); network tests tagged `:network`.

## Acceptance gates (lead runs them, never trusts worker claims)

1. Diff touches only allowed paths (`git status`, `git diff --stat`).
2. `mix compile --warnings-as-errors`
3. `mix format --check-formatted`
4. `mix test` (full) — green; `mix test --only consumer_contract` green.
5. Consumer canary `scripts/consumer_canary.sh` (~4 min): every consumer `PASS` or `WARN-BASELINE` (consumer-owned warnings identical to its own pin). `FAIL(...)` blocks. Proven 2026-09-26 by mutation (renaming `Attachments.new` -> third-eye FAIL(dspy-caused)).
6. Lead reads the new code for hacks/overreach; reviewer worker for M/L slices.

## Closing a slice

- Commit (small, conventional message), bump `VERSION`, tag `v<VERSION>`, add a row to `docs/RELEASES.md` with tag-pinned evidence links, list the feature in `docs/COMPATIBILITY.md` if stable.
- Mark the queue row done with date + tag; append a line to `plan/STATUS.md`.
- Push `main` + tag after all gates pass.
- A failed gate: fix root cause in a follow-up handoff; if it's not clean, revert the slice and record why in the queue.

## Operational learnings

- 2026-09-26: workers share one working tree. Never run lead-side mutation checks or a second lib-editing worker while a lib-editing worker is active; run parallel workers only on disjoint paths.
- 2026-09-26: home-LLM workers tend to miss existing test patterns and write tautological tests; always read new tests, and run a mutation check for contract-level claims.
