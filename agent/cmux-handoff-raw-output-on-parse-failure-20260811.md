# HANDOFF BRIEF

- **Handoff ID:** raw-output-on-parse-failure-20260811
- **Role:** Mechanic (bounded write — openspec change proposal only, no source code)
- **Goal (1 sentence):** Create an openspec change proposal in this repo — using the
  openspec propose skill / this repo's openspec conventions — for attaching the raw
  LM response to adapter output-parse/validation failures, so consumers can see what
  the model actually returned instead of only the parse-error reason.

## Success criteria

- A new change directory under `openspec/changes/<change-id>/` with `proposal.md`,
  `tasks.md`, spec delta(s), and `design.md` if the error-shape decision warrants it.
- `openspec validate <change-id> --strict` passes (use the repo's `openspec` CLI;
  config at `openspec/config.yaml`).
- `tasks.md` steps are small, independently evaluatable, TDD-shaped (failing test
  first), each with an explicit gate that can fail.
- **No file under `lib/` or `test/` is modified.** This is a proposal, not an
  implementation.
- The proposal explicitly addresses the four design questions below (decide or
  present options with a recommendation — do not silently ignore any of them).

## Situation summary (context you cannot infer)

- This repo (`dspy.ex`) is the user's Elixir port of DSPy, consumed via git dep by
  `~/dev/agent-coding-gui` (do NOT touch that repo).
- Motivating failure, observed today in production use: agent-coding-gui's session
  inspector gets `%{reason: {:missing_required_outputs, [:result]}, kind: :dspy_call_failed}`
  from a `google:gemini-3.5-flash` call and has **no way to see the raw model
  response** — diagnosis is a guessing game. Notably the JSON *decoded successfully*
  but lacked the required `result` key, so the raw text would immediately reveal what
  the model returned instead.
- The raw text is in scope at the failure site and is currently dropped — this is a
  plumbing gap, not missing data.

## Verified evidence (all checked at source today — re-verify, do not trust blindly)

- Adapter contract: `lib/dspy/signature/adapter.ex:32` —
  `@callback parse_outputs(Dspy.Signature.t(), String.t(), keyword())` — adapters
  receive the raw response text.
- Single choke point where raw text and parse result meet:
  `lib/dspy/signature/adapter/pipeline.ex:156` —
  `result = adapter.parse_outputs(parse_signature, response_text, choice: choice)`.
  The `max_output_retries` retry loop lives in this pipeline (see `lib/dspy/predict.ex:28,37`
  — option exists, defaults to 0).
- Error construction sites (reasons that currently drop raw text):
  `lib/dspy/signature/adapters/json.ex:79` and `:284`
  (`{:missing_required_outputs, missing}`), plus `{:invalid_outputs, other}` and
  `{:invalid_output_value, field, reason}` in the same file;
  `lib/dspy/signature.ex:773`; `lib/dspy/signature/adapters/default.ex:50`.
- Error passthrough to callers: `lib/dspy/predict.ex` `forward/2` —
  `{:error, reason} -> {:error, reason}`.

## Four design questions the proposal must handle

1. **Error shape & compatibility.** Existing matchers (this repo's tests, downstream
   consumers) match `{:missing_required_outputs, missing}` as a 2-tuple. Options:
   extend the reason tuples; wrap all output-parse failures in one structured error
   (e.g. `{:output_parse_failed, reason, detail_map}`); or attach detail via an
   opts-gated mechanism. Present the tradeoff, recommend one, and name every matcher
   in this repo that must change (grep for `missing_required_outputs`,
   `invalid_outputs`, `invalid_output_value`).
2. **Coverage.** Which failures carry raw output — all output-parse/validation
   failures, or only some? What about when `max_output_retries` > 0 and all attempts
   fail: final attempt's raw only, or all attempts?
3. **Size policy.** Raw responses can be large. Recommend: hand the full raw to the
   caller (caller decides persistence/truncation) vs. cap in the library — and if
   capped, record the true byte size alongside.
4. **Where implemented.** Prefer the pipeline choke point (one place, all adapters
   covered) over editing every adapter — confirm or refute this from the code.

## Scope

- **Repo / working dir:** `/Users/cgint/dev-external/dspy.ex`
- **Allowed paths (write):** `openspec/changes/**` and the report file named below.
- **Allowed actions:** read anywhere in this repo; run `openspec` CLI, `grep`,
  `git status`/`log` (read-only git); write only in allowed paths.
- **Non-goals (forbidden):** no changes to `lib/`, `test/`, `mix.exs`, config; no
  commits; no pushes; no edits outside allowed paths; no `.env`; no `rm -rf`;
  do not touch `~/dev/agent-coding-gui`.

## Starting points

- Read this repo's `AGENTS.md` (working mode) and `openspec/config.yaml` first.
- `openspec --help` / the openspec propose skill for the change-creation workflow.
- The evidence file:line refs above.

## Timebox

~30–45 min. If the openspec CLI or skill behaves unexpectedly, stop and report
rather than improvising a hand-rolled directory structure that fails validation.

## No silent stops — REQUIRED

Work through the task continuously. Do not stop at a milestone, uncertainty, or
question without reporting. You may pause only after (1) verified completion,
(2) a concrete blocker needing a supervisor decision — and before any pause you
MUST write/update the full report file with current state, evidence, and the exact
next decision, then send the one-line notification.

## Completion protocol — CMUX-only

- Write the full WORK REPORT (template below) to:
  `/Users/cgint/dev-external/dspy.ex/agent/cmux-report-raw-output-on-parse-failure-20260811.md`
- Then send exactly ONE physical line to the supervisor surface `surface:9`:

  `cmux send --surface surface:9 'CMUX WORK REPORT — <one-sentence headline>. Full report: /Users/cgint/dev-external/dspy.ex/agent/cmux-report-raw-output-on-parse-failure-20260811.md\n'`

- Never send multi-line content, tables, or evidence rows via cmux send.
- The headline must carry the substantive result (e.g. which error-shape option you
  recommended and whether validation passes) — "completed successfully" is a failed
  report.

## WORK REPORT template (required sections)

- Handoff ID
- What I did (high level)
- Findings / results — incl. the decision/recommendation per design question 1–4
- Evidence — file paths + line ranges, commands run with outcomes
- What worked / what didn't
- Risks / uncertainties / assumptions
- Next step suggestions
- Files changed + diff summary (`git status --short` output)
