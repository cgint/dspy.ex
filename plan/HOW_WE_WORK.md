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

**A test that accepts either outcome asserts nothing** (2026-09-28). Observed, verbatim, in a
shipped-candidate test: *"one wins, which is undefined by the spec … both are acceptable"*. Such
a test cannot fail, cannot catch a regression, and actively certifies undefined behaviour as
intended — it is **worse than no test**, because it looks like coverage. Writing "both are
acceptable" in an assertion means the **spec is ambiguous**, and that is a ruling for the lead,
not something a test may paper over. Escalate instead. Corollary: when two writers/readers must
agree, they call **one shared function**, and the mutation that proves it is *removing the check
from one side only* — if both sides stay green, they were agreeing by coincidence, not by design.

**Rule from what the code and upstream DO, not from what the language makes available**
(2026-09-29). The lead ruled that `1` and `1.0` must be *different* votes — reasoning from Elixir
having strict equality — and required it declared as a deviation. The code already used `==`, so
they counted as **one** vote, exactly as Python does: the ruling would have moved us *away* from
parity for no reason. Check the implementation and run upstream **before** ruling on behaviour; a
ruling is a claim like any other. (The real deviation was hiding underneath: Python counts `True`
and `1` as the same vote, we don't.)

**Extracting a shared function needs TWO mutation directions** (2026-09-29, Greta). Breaking the
shared module and watching every path go red proves only that **the shared module is tested** —
if the tests all exercise one caller, the other callers could be bypassing it entirely and
nothing would go green. You must **also revert each call site individually**, and each revert
must fail *that path's* tests specifically. Both directions, or the extraction is unproven. (The
lead's original requirement asked only for the first direction.)

**A verification tool that lives in scratch space is not a standard** (2026-09-29). Commit the
mutation harness next to the generator it verifies. One slice left its harness in a gitignored
handoff directory, so the "standard" could not be re-run by anyone else.

**A mutation must fail the test it targets, and fail it for the reason it claims** (2026-09-29).
A RED sweep line is not proof by itself. Observed: a revert-mutation reddened most of the suite
by breaking an unrelated guard, while leaving the clause it claimed to revert in place — so it
**would still have gone red with its target test deleted**. A mutation that fails for the wrong
reason proves nothing while looking exactly like proof. When a sweep goes red, check *which*
tests failed and whether they are the ones that row exists to pin. A broad mutation that reddens
half the suite tells you nothing about any particular row.

**Fix every shape the code path accepts, not the one in the bug report** (2026-09-29). Five fix
rounds in a row each introduced a defect of their own, and the diagnosis was the same every time:
the fix handled only the shape the finding happened to show. A fix for absent-vs-nil was reported
with atom keys, so it used `Map.has_key?` and broke string-keyed input — while the rest of the
codebase falls back atom-to-string. Before calling a fix done, ask: **what other shapes does this
path accept** — string keys, atom keys, `nil`, absent, struct vs map — and does the fix handle all
of them? Put that question in the worker brief.

**Check every COMPATIBILITY claim against the golden fixture, not memory** (2026-09-29). Where a
slice has a generated oracle, each sentence asserting "we accept X" or "upstream rejects Y" is a
claim the fixture can settle — so settle it. Observed: one section contained **three** false
statements, including one where the *code was right and the text was wrong* (the worse direction,
since a reader trusts the doc), and one that generalised an upstream behaviour from a single
unrepresentative sample. Three wrong claims in one section is not three slips; it is a section
written from recollection.

**Never state a fact about upstream you have not read** (2026-09-29). A shipping
`COMPATIBILITY.md` entry claimed upstream accepted unpacked positional args; its actual signature
takes one argument. A document whose entire purpose is describing how we differ from upstream
must not invent upstream. Cite the file and line.

**An unpinned behaviour is a coin flip** (2026-09-29). Two findings in one review: one where the
code was **right** and no test said so, one where it was **wrong** and no test said so. Both
looked identical from the outside — a green suite. You discover which one you had when someone
refactors. This is what the mutation sweep is for: the question is never "do the tests pass" but
"which of my claimed behaviours would survive being broken".

**The acceptance gate must be the command CI actually runs** (2026-09-29). Plain `mix test`,
default timeout — because `scripts/ci_docker.sh` and `.github/workflows/ci.yml` run exactly that.
A gate with different flags certifies something CI never executes, so a green gate stops
predicting a green CI; that is how this project shipped a red CI for six releases. `--timeout` is
a **diagnostic** for hunting a suspected hang, never a gate setting (`--trace` is banned outright
— it disables timeouts). Observed: a controller gated at `--timeout 3000` and reported 571/573 as
flakiness; the same sha ran 573/573 repeatedly at the default. It had induced the failures it
reported. Corollary: **take the baseline with the same command as the gate** — a baseline taken
with different flags is worse than none, because every later "pre-existing" claim is measured
against it.

**Never `--wait` on the lead's pane** (2026-09-29). It blocks until the lead's state changes,
and the lead is often blocked awaiting *you* — a deadlock in which neither side's tokens move.
Report, then stop or continue with work that does not depend on the answer; the lead comes to
you. Use `herdr_prompt_agent.sh`, which preflights instead of trapping.

**Before trusting a verification tool, break something on purpose and confirm it complains**
(2026-09-29, Greta). This is the *only* test that proves a harness works, and reasoning is no
substitute. Observed: a harness wrote backup files only if none existed and never deleted them,
so **from the second run on it restored the first run's sources** — testing stale code and
**silently reverting the developer's edits**, while printing `ALL CLEAR 18/18`. Greta found it by
editing an anchor and checking whether the tool noticed; it didn't.

**A verification tool must not keep state on disk** (2026-09-29). Hold originals in memory and
restore in `try/finally`. A tool that writes files to protect source files is one interrupted run
away from being the thing that corrupts them.

**Every layer of verification is itself code that can be wrong** (2026-09-29). The chain this
slice: a false zero in the tests → build a harness → the harness skipped a test file → fix it →
the harness's *backup mechanism* was still wrong underneath. "The tool said ALL CLEAR" is a claim
like any other, and each new layer of checking needs its own check.

**The harness must FAIL on a vanished mutation, not just report it** (2026-09-29, Britta). A
standard that depends on someone carefully comparing two numbers is weaker than one that cannot
produce a false pass: make `NOT-APPLICABLE > 0` a **hard failure, exit 1**. Stronger than the
"report both numbers" rule below, and it supersedes it in practice.

**Audit the harness itself — a false zero can hide inside the tool built to find false zeros**
(2026-09-29). Observed, self-found: the runner passed only 2 of 3 test files, silently skipping
the one covering two call sites — **which is why their per-caller reverts looked green** — and it
misparsed ExUnit's `N/M passed` line, counting crashed runs as green. A reviewer can catch a
report that says "10 of 12"; only someone *reading the harness* can catch a runner that omits a
test file. Read it.

**Re-stamp the stability gate on the FINAL tree** (2026-09-29). A 20× run taken before a fix
round proves nothing about the code after it. Confidence that the root cause is closed is
reasoning, and reasoning about flakes is exactly what fails.

**Report TWO numbers from a mutation sweep: applied and defined** (2026-09-29). A harness that
silently returns `None` for a pattern prints `NOT-APPLICABLE` and that mutation **vanishes** — it
is neither RED nor a survivor, and the count still looks perfect. Observed: a report claimed
"10/10 killed" for a list of **twelve**. Always reconcile the count in the log against the number
of patterns *defined in the script*; a zero-survivor sweep means nothing until those two agree.

**Mutation-test with a SCRIPT, not by hand** (2026-09-29). Hand-mutating one row at a time asks
"did this test go red?"; a script asks the question that matters — **"which of my claimed
behaviours does NO test catch?"** Write a small script that applies N deliberate code changes and
reports the survivors. **Target: zero survivors.** Evidence: a full day of careful hand-mutation
found two unpinned rows; one automated sweep of 14 mutations found **five**, including an
entire tokenizer that could be replaced by `String.split/1` with nothing failing. Correct code
that no test protects becomes incorrect the first time someone refactors it.

**When a fix round rewrites the mutation patterns, add a mutation that REVERTS THE FIX**
(2026-09-29, Greta). "The old mutations still fail" only shows the *patterns* were updated to
match the moved code. Only a mutation that undoes the fix itself shows the **fix is pinned**.
Observed: after a fix round, none of the 14 mutations undid any of the new fixes, so the Greek
lowercase, combining-mark and control-character corrections could all have regressed with
nothing going red — a **false zero**, which is the one failure a zero-survivor sweep cannot
detect about itself. One revert-mutation per fix closed it: 17 mutations, 0 survivors.
Corollary: a worker may update a mutation's *search text*, never its *intent*, and the author of
the mutations is the one who confirms that.

**A generated fixture can silently record an error as an expected value** (2026-09-29). When the
oracle comes from a generator rather than hand-written cases, the generator is load-bearing: one
fixture row had captured a **Python error message** as its expected value because the generator
called the wrong upstream function, and the test quietly skipped it. Re-run the generator and
diff it against the committed fixture as part of review; assert that every expected value is of
the type the row claims.

**A "green" claim must be re-verified after a handoff, not trusted** (2026-09-29). A worker
reported "format check passes"; the controller's own gate run found the file unformatted (one
line-wrap) and the metrics tests red-by-format. Every acceptance gate — suite, format, compile,
consumer contract, mutation harness — is run BY THE CONTROLLER at close-out, with logs, and the
worker's PASS lines in the report are input to that run, not its substitute.

**A tool that fails twice with the same error is broken tooling, not bad luck** (2026-09-29).
A *schema* rejection is the same category as a dead launcher: the arguments are wrong and will be
wrong on every retry, so an identical retry can never succeed. Second identical failure → change
the approach or escalate. **Never a third.** Observed: a controller retried one rejected `read`
call in a loop, sending **69M → 107M tokens** between two checks and compacting its own context
mid-loop, with nothing progressing. Looping silently is the expensive failure; stopping early and
asking is the cheap one.

**Take every date in a durable document from `date` or `git log` — never from memory**
(2026-09-29). Multiple agents independently wrote **2026-10-01**, a date that had not happened,
into release notes, compatibility docs, queue rows and signed contracts — 19 occurrences, two of
them in files that were about to ship inside a tag. Nobody had a source; everybody guessed the
same wrong way. Treat it as a shared failure mode, not one agent's slip: an agent has no
reliable clock, so a date written from memory is fabricated evidence, and it is the kind that
looks authoritative forever afterwards. This rule binds the lead equally.

**Test the ORDINARY case first, then the edges** (2026-09-29). A regression walked through a
green suite because every JSON test used rows of one shape or an exotic duplicate-key case, and
**none covered the normal shape of a run containing a failure** — upstream's everyday output.
Four exotic tests, zero ordinary ones, is backwards. Before adding edge-case rows to an
acceptance map, check that the plain path is pinned at all.

**Reusing a function is not free: name which of its rules the new caller wants** (2026-09-29).
A shared check was introduced by reusing a whole validator where only *part* of it applied:
`validate_rows!` enforces **two** rules — per-row key uniqueness **and** CSV's "every row's keys
⊆ the header". The JSON writer wanted only the first, silently inherited the second, and began
rejecting rows of differing shapes — output upstream writes happily. "It already does the check" is not a reason — it may do **more** than
the check. State the wanted rules explicitly at each call site, and split the function when they
differ.

**Weight review toward the NEW code after a fix round** (2026-09-28). Twice in a row a fix round
introduced a defect the previous round did not have (the B-round fixes introduced BB1, silent
null data). A fix round is not inherently safer than the original work — it is *less* reviewed.
Re-reviewing what already passed twice is the cheap habit; attacking what just changed is where
the bugs are.

**Urgent findings go to a FILE, not only to a pane** (2026-09-28). `herdr_prompt_agent.sh`
refuses a `working` target, so an urgent finding can fail to deliver repeatedly while the lead
is mid-round — and silently. Observed: a reviewer found a silent data-loss bug during a fix
round, tried to send it several times, never got through, and the fix round shipped without it.
**Rule:** anyone holding an urgent finding writes it to
`plan/research/pi_handoffs/URGENT.md` (append, dated, with sender and sha) *and* attempts the
send. The lead **reads that file at every round boundary** — before accepting a report, before
committing, and before asking for a verdict. A second failed send is itself a signal: stop and
write it down rather than retrying into a busy pane.

**Parity, except where upstream silently corrupts or loses data** (2026-09-28). Where upstream's
behaviour is a design choice we match it, even when ours would be friendlier — that is the P-OUT
and B1 rule. But where upstream silently *corrupts* (pandas type-guessing turning an integer
column into floats; a row with an extra field scrambled into a different shape; a duplicate
column quietly renamed `a.1`), we **raise and declare it**. Raising is *stricter* than upstream,
not friendlier, so it does not weaken the parity rule — it protects the user's data.

**A test that calls global `Dspy.configure/1` MUST be `async: false`** (2026-09-28). `configure/1`
mutates global settings, so an `async: true` test using it races every other async test and makes
the whole suite non-deterministic. Prefer process-scoped `Dspy.context/2` (which propagates into
spawned work since v0.3.44) and keep `async: true`; where global configuration is genuinely
needed, mark the file `async: false`. Observed: three new `async: true` files calling `configure/1`
turned the suite flaky at **1, 85, 0 and 3 failures across four runs of an unchanged tree**;
after the fix, 10 consecutive clean runs.

**Flaky is worse than failing**, and a flake is never "pre-existing and unrelated" until proven:
a green run proves nothing on its own. When a failure count cannot be reproduced, **repeat the
suite** (10+ runs, and under CPU load for timing-sensitive work) before believing either result.

**Never ask a `readonly` worker for a report file** (2026-09-28). Read-only mode blocks writes,
so a brief demanding "write the report to `<path>` AND to the terminal" is only half-satisfiable
and the worker has to report the contradiction instead of doing the work. A read-only reviewer's
evidence channel is the **terminal**, and the supervisor captures it with `herdr agent read`
**before** closing the pane — terminal output is not retained afterwards. Observed: a reviewer
produced a full verdict that would have been lost on pane close.

**"Pre-existing" is a claim that must be proven, never an assumption** (2026-09-28). A failure is
*yours* until you show otherwise, and the only proof is a diff against the baseline recorded in
the slice's Phase A report, or stashing the change and re-running. Observed: a worker saw 84
full-suite failures, labelled them "pre-existing and unrelated", and carried on — while the
recorded baseline was 0 failures and an independent run of the same tree showed 533 passed / 0
failures. The tree was fine; the reasoning was not, and that reasoning at a final gate ships a
false claim. Corollaries: a full-suite run taken **while a mutation is applied is meaningless** —
restore first, then measure; every reported test count must state which state the tree was in;
and an unexplained failure count is a **stop-and-report**, never a footnote.

**Never use `mix run --no-halt` for a script** (2026-09-29). `--no-halt` keeps the VM alive after
the script finishes, so the command never returns and any pipeline after it (`| grep`, `| tee`)
never completes. Use plain `mix run <file>.exs`. Observed: a worker hung **24 minutes** on
`mix run --no-halt` for a three-line probe. Same family as the `ExUnit.run()` hang below — the
process is perfectly healthy, it is simply never going to exit, which is why no error ever
appears and nobody notices.

**Never call `ExUnit.run()` inside a file you launch with `mix test`** (2026-09-28). `mix test`
already starts and runs ExUnit; the explicit second run blocks forever, and `--timeout` does not
help because the hang is outside any test case. Either put the module in a real file under
`test/` with no `ExUnit.run()` line, or keep it self-contained and run it with `mix run`. Cost
when missed: 23 minutes of a worker spinning on a scratch debug file.

**Never run a mutation with `mix test --trace`** (2026-09-28). `--trace` disables ExUnit's
per-test timeouts, so a mutation whose failure mode is a *hang* runs forever instead of going
red — a worker burned 40 minutes on exactly this. Use `--timeout <ms>`. Note also that a
mutation detected only by timeout is weaker evidence than one detected by an assertion: it is
acceptable when the hang is deterministic (e.g. removing a `receive` clause), but say so
explicitly in the verdict rather than reporting a bare "RED".

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
