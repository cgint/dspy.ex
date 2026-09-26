# How we work — dspy.ex parity team (2026-09-26, DRAFT for Horst/Greta co-sign)

Adapted from `~/dev/agent-coding-gui/docs/how-to-work/`. Point every brief here; don't restate rules.
Slice mechanics/gates: `plan/SLICE_LOOP.md`. Backlog: `plan/PARITY_QUEUE.md`.

## Principles
1. **Clarity before code** — each slice has a written contract (what, why, non-goals, WHEN/THEN scenarios, upstream file refs) before implementation.
2. **Nobody works alone** — every worker has a controller; acceptance needs one verdict from outside the sub-team.
3. **Evidence, not assertion** — claims are re-derived from source/tests/runs. Worker "checks passed" is not evidence.
4. **No shortcuts** — no edited-to-pass tests, no skip/exclude, no "KNOWN LIMITATION" that hides an unmet requirement. Strange/hard → stop and escalate.
5. **Stack best practice** — OTP/Elixir idioms checked (`asks.sh liveview-elixir-phoenix-beam`, Elixir expert agent), not guessed.
6. **Consumer safety** — additive by default; `test/consumer_contract/` is frozen; canary must stay green.

## Roles
| Role | Who | Does | Never |
|---|---|---|---|
| Lead / firstmate | Horst | contracts (draft), slice order, briefs to controllers, acceptance via targeted spot check, commit/tag/push, sole user interface | coding, long test/canary runs (delegated) |
| Architect buddy | Greta (pane `w1:p1`, Opus; Horst is `w1:p4` — verified via `herdr pane list` 2026-09-26) | co-signs contracts + designs touching invariants (process context, cache keys, LM request path, public API); risk/queue review; final release review; runs her OWN readonly sub-agents (parity audits, adversarial review, consumer scouting) | talking to workers; editable sub-agents without pinging Horst (shared tree) |
| Sub-team controller | e.g. Judith, launched by Horst | designs team (default worker + reviewer), aligns echo-backs, review-and-iterate per sub-step (≤3 rounds), runs gates herself, verdict **PASS / PASS-WITH-FIXES / BLOCK** with file:line/command evidence | writing code, co-authoring, relaying verdicts via the worker |
| Worker | e.g. Benjamin, launched by controller | echo-back first, TDD, implements within allowed paths | scope decisions, editing existing tests, commits, launching agents |
| Outside reviewer | fresh readonly agent by Horst, or Greta | ONE independent verdict on the final diff | being briefed by the sub-team |

Depth max: Horst → controller → members. Launcher owns and closes panes. One lib-editing sub-team at a time (shared working tree + `_build`).

## Slice lifecycle
| Step | Artifact | Who | Gate |
|---|---|---|---|
| 1 Contract | `openspec/changes/<slice>/proposal.md` + `specs/.../spec.md` (WHEN/THEN, upstream file:line, non-goals) | Horst drafts | Greta sign-off; `openspec validate` |
| 2 Baseline | test counts (full, consumer_contract), canary summary — on the exact HEAD the worker starts from | worker | recorded before code |
| 3 Echo-back + team design | controller's own words + roster/models/timebox | controller | Horst explicit "go" |
| 4 Design | `design.md` + `tasks.md` (gate task per scenario) | worker | controller PASS (+ Greta if invariant) |
| 5 Implement | tests first per sub-step | worker | reviewer PASS per sub-step; **mutation proof** for each key test |
| 6 Verify | evidence per scenario; `mix compile --warnings-as-errors`; `mix format --check-formatted`; `mix test`; `mix test --only consumer_contract`; `scripts/consumer_canary.sh` | controller runs | controller final PASS |
| 7 Outside review | one verdict (`cg-task.sh diff-review` as input, not conclusion) | Horst-launched reviewer / Greta | PASS |
| 8 Accept | read report file + cited evidence; rerun ≤1 named command | Horst | report file exists |
| 9 Release | VERSION, `docs/RELEASES.md`, `docs/COMPATIBILITY.md`, queue/STATUS, archive change, commit (slice files only), tag, push | Horst | push only if the report's canary summary was produced on the exact tree being tagged; any fix-up after verification → rerun canary |

Small slices (≤1 module, no invariant touched) may merge steps 1–3 into one contract note in the brief, but never skip controller review, mutation proof, or outside verdict.

## Review checklist (controller + outside reviewer)
- Each key test proven able to fail (break one impl line → red). Mutations are reverted; `git diff`/shasum after the proof shows no residue; report lists each mutation (file:line) and which test went red.
- No vacuous asserts (`{:ok, _}`, `is_map`, "no crash") as the only check.
- No unapproved KNOWN LIMITATION/skip/pending; a test describing wrong behavior is a finding.
- Claims cite upstream `../dspy` file:line; divergences listed.
- Gates rerun by the reviewer: exit codes + counts.
- `git diff --stat` ⊆ allowed paths; no `test/consumer_contract/**`, `mix.exs`, `mix.lock` unless contracted; new options off by default.
- Any new Task/spawn: tests prove all process state crosses the boundary — settings overrides, usage merge-back into the caller, adapter callbacks — and crash/timeout semantics are explicit (no linked crash reaching the caller; `on_timeout` stated).
- A controller never approves a documented limitation on its own: KNOWN LIMITATION = BLOCK unless Horst approves (with Greta's co-sign if an invariant is touched).

## Communication
- Messages: `<Sender> → <Recipient>: …`, one topic, state what you need back (`herdr_prompt_agent.sh`).
- Brief contains: identity chain + owner, timebox + overrun rule (stop, partial report), model per role, contract path, phase + stop point, allowed/forbidden paths, tools, supporting agent, report path + terminal marker, escalation rules.
- Report **file** under `plan/research/pi_handoffs/<slice>/` before the terminal marker (`WORK REPORT` / `CONTROL REPORT`): echo-back · done · evidence per scenario · tool log · findings · deviations · open questions.
- Labels: Fact · Deduction · Hypothesis/Unverified · Proposal · Unknown.
- Escalate (stop, don't work around): scope question, contradicting evidence, contract looks wrong, strange/too hard, irreversible action, unresolved controller–worker disagreement.

## Toolbox
colgrep / `rg` (repo search) · `cg-task.sh investigate|diff-review|architecture-review|discrepancy-check -d lib/dspy/...` · `asks.sh liveview-elixir-phoenix-beam` · Elixir expert agent (cwd `~/dev/concepts/advisor-agent-elixir/`) · upstream `../dspy` · `openspec` · Herdr supervisor scripts. Tool output is a lead, not proof. No Dialyzer in this repo (not a gate).
