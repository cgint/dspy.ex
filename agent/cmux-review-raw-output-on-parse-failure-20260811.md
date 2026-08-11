# SUPERVISOR REVIEW — raw-output-on-parse-failure-20260811

**Verdict: APPROVED with two required adaptations, then proceed directly to
implementation (authorization below).**

Independently verified before this review: `openspec validate --strict` passes;
`git status` shows no writes outside allowed paths (the `lib/` modifications are
pre-existing unrelated local edits — leave them untouched); your 8-file matcher
inventory matches my own grep exactly; lib-side occurrences of bare reasons are
doc comments only; and the motivating downstream consumer
(`agent-coding-gui .../session_inspection.ex:838-840`) calls
`Dspy.Predict.new(signature, max_retries: 0, max_output_retries: 1)` — pipeline-backed,
so your exhausted-retry scenario is exactly the production failure path. Good work:
the pipeline-terminal wrapper decision, preserved inner reason, and the
direct-adapter-contract preservation are all sound.

## Required adaptation 1 — name the two doc sites in task 3.3

`lib/dspy/predict.ex:28` and `lib/dspy/chain_of_thought.ex:54` document
`:max_output_retries` with the bare example `{:missing_required_outputs, ...}`.
After the change, caller-facing docs must show the terminal wrapper (or state
explicitly that retry classification uses the inner reason while callers receive
the wrapper). Task 3.3's gate is currently generic ("review public documentation");
name these two exact sites so the gate is mechanically checkable, and include any
`@spec`/typedoc that enumerates pipeline error shapes if you find one.

## Required adaptation 2 — name the out-of-scope legacy path

`lib/dspy/lm.ex:535` (`Dspy.Signature.parse_outputs/2` called after
`generate_text` — the legacy non-pipeline structured path) never passes the
pipeline choke point and will NOT carry raw output after this change. Add it
explicitly to design.md Non-Goals (with the file:line) so nobody reads the
capability as "all structured-output failures carry raw output." The spec's
"pipeline-backed prediction" wording is correct — this is a design-doc
explicitness fix, not a spec change.

## Optional (your call, decide and record either way)

Consider whether the detail map should also carry `:attempts` (number of parse
attempts made) — cheap, mechanically known at the terminal point, and useful for
consumers diagnosing whether repair retries were active. The map is extensible
either way; if you decline, one sentence in design.md why.

## Authorization to implement — after the adaptations

Once both adaptations are in and `openspec validate attach-raw-output-to-parse-failures --strict`
still passes, proceed directly to implementation of this change (openspec apply
workflow / `/skill:openspec-apply-change`), tasks in order, TDD as specified.

Expanded scope for the implementation phase ONLY:
- **Allowed paths (write):** `lib/dspy/signature/adapter/pipeline.ex`, doc-comment
  edits in `lib/dspy/predict.ex` + `lib/dspy/chain_of_thought.ex`, `test/**`, the
  openspec change dir (task checkboxes), and your report file.
- **Still forbidden:** commits, pushes, `mix.exs`, `.env`, unrelated refactors,
  reverting the pre-existing `lib/` modifications, touching `~/dev/agent-coding-gui`.
- **Task 4.x are user-verification tasks — do NOT tick them.** Stop after section 3
  is green (focused tests + full suite + `./precommit.sh` if present).
- **No silent stops** — same rule as the brief.

## Completion protocol — unchanged

Update the full report at
`/Users/cgint/dev-external/dspy.ex/agent/cmux-report-raw-output-on-parse-failure-20260811.md`
(append an implementation section; keep the proposal section), then send exactly ONE line:
`cmux send --surface surface:9 'CMUX WORK REPORT — <headline: tests green? suite counts? wrapper shipped?>. Full report: /Users/cgint/dev-external/dspy.ex/agent/cmux-report-raw-output-on-parse-failure-20260811.md\n'`
