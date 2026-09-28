# How we work — dspy.ex parity team (2026-09-26, DRAFT for Horst/Greta co-sign)

Adapted from `~/dev/agent-coding-gui/docs/how-to-work/`. Point every brief here; don't restate rules.
Slice mechanics/gates: `plan/SLICE_LOOP.md`. Backlog: `plan/current/PARITY_QUEUE.md`.

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

**Horst and Greta coordinate, decide, review and accept — they do not do the legwork** (user, 2026-09-28). Investigations, log digging, reproductions, docker runs, CI/tooling fixes, audits and mechanical edits go to a sub-agent with a brief; the lead reads the report and verifies selectively.
**Test-evidence rule:** a test counts only if it goes through the library's public entry point; mirror tests (re-implementing the logic in the test) or source greps are not evidence (lesson H0b-1, 2026-09-28: 6 of 10 sites 'proven' by mirror tests; Greta's BLOCK).
**Push rule:** push to main only after Greta's PASS on the exact sha being pushed, or on a content-identical ancestor with only release metadata (VERSION, RELEASES row) after it (lesson 2026-09-28, EXT-HTTP pushed before re-verdict).
**Evidence rule:** every sub-agent claim ships with the raw command + a saved log path; no log = unverified (lesson 2026-09-28: a scout reported non-matching CVE ids and called a logged-in-chat result 'not reproducible'). Leads save their own logs too.
**Wait with the helper, never with sleeps** (2026-09-28, user). `herdr_await_agent.sh` is
event-based and blocking: call it **once, in the foreground, with a long `--timeout-ms`**, and
let it return lifecycle state plus a bounded terminal snapshot. If it times out, call it again.
Do **not** wrap it in `sleep`, do not background it and poll `herdr agent get` around it, and
never infer state from a terminal spinner. Prompting goes through `herdr_prompt_agent.sh`, never
`pane send-text`/`send-keys` (except a deliberate `esc` interrupt by the owner). Observed
2026-09-28 at both levels: the lead polled `sleep 240` loops and the architect buddy ran
`sleep 150`/`240`/`280` around a backgrounded await. It burns tokens, adds uncontrolled latency,
and yields strictly less information than one blocking call. Applies to Horst and Greta equally.

**A mutation is not done until it is restored.** No verdict may be produced over a tree that
still carries a mutation: the worker restores the file, re-runs green, and `git status
--porcelain` is **empty**, proven by the actual command output, not by the worker's word.

**Every sub-agent runs in its own herdr pane** via the `sub-agent-herdr-supervisor` scripts (`herdr-start-subagent.sh --mode readonly|editable`, await, report file, close). No `nohup`/background `pi -p` runs: they can't be watched, prompted or closed, and fail silently (observed 2026-09-26: 6 phase-B scouts produced empty output). Read-only scouts use `--mode readonly`, never `--tools bash`.
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

## Clarity Gate (Horst + Greta, BEFORE any controller launches) — co-signed 2026-09-26
Lesson (H0): an unpinned API shape ("run in a child") let a nested-spawn design reach review. Clarity is our job, not the worker's.
- **(a) Contract** pins: API signatures; which process each function runs in (never write "in a child"/"wraps" without naming the process); ownership of every spawn/link/timeout/`after` cleanup; invariants + must-not-change behaviours; **forbidden mechanisms** (e.g. no new spawn/link/await, no `trap_exit`, no new process-dict keys); decisions made vs deferred to the user; non-goals.
- **(b) Team card**: roles, names, pane owners, who talks to whom, sub-steps, where each gate's evidence lands, which decisions return to Horst/Greta vs stay with the controller.
- **(c) Acceptance map**: scenario → named test → mutation target naming the *wrong implementation it catches* ("double spawn passes, missing restore fails"), plus the outside-verdict owner.
- **(d) Pre-mortem**: top ways a cheap worker could pass tests yet miss intent, each with a guard.
- **(e) Controller echo-back** restates API signatures verbatim + one own-words sentence per invariant; any diff vs contract = gap → back to Horst/Greta, never resolved by the worker.
- **(f) Evidence**: `proposal.md` records `Clarity Gate: Horst ✓ <date> / Greta ✓ <date>`. No controller launch without both.
Groundwork for (a)/(d) is done by Greta's readonly scouts; Horst drafts contract + team card from her verified findings package.

## Commit + CI hygiene (lesson 2026-09-28)
- **Never `git commit -a` / `-am`.** Always `git add <named paths>` then `git commit`; check `git show --stat HEAD` before push. (2026-09-28: two plan-only commits swept a team's unreviewed lib WIP into main; reverted in 4c66d54.)
- While a team is editing, the lead commits plan/doc paths only.
- **CI is a release gate:** after every push, `gh run watch` / `gh run list -L 1`; a release is not done until CI is green. Red CI blocks the next release.
- **Toolchain gap:** CI runs OTP 28.0 / Elixir 1.19.5; local is OTP 29 / Elixir 1.20. Release step: commit locally by path → `scripts/ci_docker.sh HEAD` (exact CI job in docker, committed state only) must print `ALL STEPS GREEN` → push → `gh run watch` green. No `.tool-versions` pin: no version manager on this machine, so the docker script is the real gate.
- Supported floor is tested (2026-09-28): CI matrix Elixir 1.18.4/OTP 27.3 (compile+test) + 1.19.5/OTP 28.0 (also format). Measured first via `CI_DOCKER_IMAGE=hexpm/elixir:1.18.4-erlang-27.3.4.16-ubuntu-noble-20260810 scripts/ci_docker.sh` (format step differs by formatter version; compile+tests green).

## Dependencies, security, toolchain (user policy 2026-09-28; Horst decides)
- **Security gate:** `mix hex.audit` (Hex ≥2.x reports CVE advisories from the EEF/OSV database, plus retired packages) must be clean on every release. An advisory → security slice **next in queue** (a running lib-editing slice finishes first; security slices run in a separate git worktree so they don't collide).
- **Consumer effect is honest:** our `mix.lock` does not reach consumers. A fix protects them only if we raise the minimum requirement in `mix.exs` so the vulnerable range can't resolve; transitive deps otherwise need `mix deps.update <pkgs>` on the consumer side → say so in `docs/RELEASES.md` and run it in the canary.
- **Smallest safe bump first:** pick the lowest version that fixes the advisory; read the changelog (0.x minor bumps may break); newer-than-needed bumps are a separate "keep current" slice.
- Keep deps current: `mix hex.outdated` reviewed at each milestone start.
- **Toolchain matrix (pinned, explicit version pairs in ci.yml; no floating tags):** floor Elixir 1.18.4/OTP 27.3 (compile+test) · primary 1.19.5/OTP 28.0 (compile+test+format — the formatter check runs on this one only, as output differs by version) · newest stable, pinned (bumped at milestone start). Raise the floor only for a real maintenance cost, recorded here with the reason.

## Versioning (user decision 2026-09-28)
- One **minor** version per milestone: M1 → v0.4.x, M2 → v0.5.x, M3 → v0.6.x, M4 → v0.7.x, M5 → v0.8.x, M6 → v0.9.x.
- Each slice within a milestone = a **patch** release (v0.4.1, v0.4.2, …). The first slice of a milestone opens the minor (v0.4.0).
- Milestone done = its end-to-end example runs + last slice released; noted in RELEASES.md as "M<n> complete" and in 00_NOW/PLAN.
- Work before M1 (H0b) stays on v0.3.x.

## Keeping plan/current/ up to date (Horst owns; Greta checks)
Update **`00_NOW.md` (user) and `PLAN.md` (team)** at each of these moments, in the same commit as the event:
1. a release (Done table, In-progress table);
2. a phase/milestone starts or ends, or numbers change (e.g. inventory result → section 2 counts);
3. something starts waiting for the user, or the user decides something;
4. the plan changes (Greta reviews PLAN.md changes; 00_NOW is updated in plain words).
Greta: when you review or report, flag it if 00_NOW or PLAN.md disagree with what you know.

## Review checklist
- **No Python runtime** (Pythonx, snakepit/DSPex, erlport, `System.cmd("python"...)`) added anywhere without explicit user approval — BLOCK (user decision 2026-09-26). (controller + outside reviewer)
- Each key test proven able to fail (break one impl line → red). Mutations are reverted; `git diff`/shasum after the proof shows no residue; report lists each mutation (file:line) and which test went red.
- No vacuous asserts (`{:ok, _}`, `is_map`, "no crash") as the only check.
- No unapproved KNOWN LIMITATION/skip/pending; a test describing wrong behavior is a finding.
- Claims cite upstream `../dspy` file:line; divergences listed.
- Gates rerun by the reviewer: exit codes + counts.
- `git diff --stat` ⊆ allowed paths; no `test/consumer_contract/**`, `mix.exs`, `mix.lock` unless contracted; new options off by default.
- Any new Task/spawn: tests prove all process state crosses the boundary — settings overrides, usage behaviour as contracted (H0: no merge-back, upstream parity), adapter callbacks — and crash/timeout semantics are explicit (no linked crash reaching the caller; `on_timeout` stated).
- A controller never approves a documented limitation on its own: KNOWN LIMITATION = BLOCK unless Horst approves (with Greta's co-sign if an invariant is touched).

## Communication
- Messages: `<Sender> → <Recipient>: …`, one topic, state what you need back (`herdr_prompt_agent.sh`).
- Pings **upward** (controller → Horst, anyone → a busy lead) use non-blocking `herdr agent prompt <pane> "…"` WITHOUT `--wait`; a blocking wait on a working lead deadlocks both (observed 2026-09-26).
- Brief contains: identity chain + owner, timebox + overrun rule (stop, partial report), model per role, contract path, phase + stop point, allowed/forbidden paths, tools, supporting agent, report path + terminal marker, escalation rules.
- Report **file** under `plan/research/pi_handoffs/<slice>/` before the terminal marker (`WORK REPORT` / `CONTROL REPORT`): echo-back · done · evidence per scenario · tool log · findings · deviations · open questions.
- Labels: Fact · Deduction · Hypothesis/Unverified · Proposal · Unknown.
- Escalate (stop, don't work around): scope question, contradicting evidence, contract looks wrong, strange/too hard, irreversible action, unresolved controller–worker disagreement.

## Toolbox
colgrep / `rg` (repo search) · `cg-task.sh investigate|diff-review|architecture-review|discrepancy-check -d lib/dspy/...` · `asks.sh liveview-elixir-phoenix-beam` · Elixir expert agent (cwd `~/dev/concepts/advisor-agent-elixir/`) · upstream `../dspy` · `openspec` · Herdr supervisor scripts. Tool output is a lead, not proof. No Dialyzer in this repo (not a gate).

## 00_NOW writing rule (user feedback 2026-09-26)
`plan/current/00_NOW.md` is for the user, not the team: plain language, no internal codes (H0b, phase B, canary, facets), no contradictions with other files. Answer: what are we building, how far along (numbers), how we get there (milestones), what's happening now and why, what's done, what waits for the user. Team detail goes in `PLAN.md`.
