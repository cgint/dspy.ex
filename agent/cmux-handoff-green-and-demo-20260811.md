# HANDOFF BRIEF — follow-up in the same outcome thread

- **Handoff ID:** green-and-demo-20260811
- **Role:** Mechanic (bounded write)
- **Goal:** Make the wrapper's value *demonstrable* and the repo *committable*:
  a runnable example that prints the new error tuple, plus a green
  `./precommit.sh` (currently blocked by 1 failing test + warnings-as-errors).

## Why (supervisor context)

The wrapper shipped and is accepted, but the outcome is not: there is no
one-command demonstration a human can run, and the repo cannot be committed
cleanly because precommit is red. Both must be fixed before the change is
pushed and consumed downstream.

## Tasks, in order

1. **Runnable demo:** create `examples/raw_output_on_parse_failure.exs`,
   runnable as `mix run examples/raw_output_on_parse_failure.exs` (MIX_ENV as
   needed). Self-contained: an in-file signature + mock LM (implementing the
   `Dspy.LM` behaviour) returning valid JSON that omits the required output
   key; call through public `Dspy.Predict` / `Dspy.Module.forward`; print the
   returned tuple clearly showing `{:output_parse_failed, {:missing_required_outputs, [...]}, %{raw_output: ...}}`.
   Look at existing `examples/` files for conventions. Your earlier inline
   `mix run -e` attempts failed on module-definition mechanics — a real file
   avoids that class entirely. **Gate: paste the actual command + output in
   the report.**
2. **Fix the schema-hint leak:** `test/signature_typed_schema_integration_test.exs:66`
   fails because generated schema JSON now contains `x-jsv-cast` (the bumped
   jsv dependency renamed its internal cast key; `refute "jsv-cast"` catches
   it as a substring). The test's intent is that schema hints do not leak
   internal jsv metadata — so fix the **production site** that generates the
   schema JSON to strip internal jsv keys (both old and new spellings), and
   extend the test to cover the new spelling explicitly. Weakening or deleting
   the assertion is not acceptable. **Gate: that test file passes.**
3. **Fix the warnings blocking precommit's warnings-as-errors gate** —
   at minimum: `lib/dspy/typed_outputs.ex:58` (unreachable `other ->` clause),
   `lib/dspy/parameter.ex:376` (`import_metadata(nil)` clause never used),
   `lib/dspy/adapters.ex:152` (always-true `is_atom` in cond) — plus any
   remaining project-source warnings precommit reports. Fix each with the
   minimal behavior-preserving change; if a clause is provably dead, remove it
   and say why in the report; if it guards a real case, make it reachable.
   Do not suppress warnings globally. **Gate: the compile phase of
   `./precommit.sh` passes.**
4. **Run `./precommit.sh` to the end.** If something beyond your allowed scope
   blocks it (e.g. the reported unused-lockfile-deps check depends on
   `mix.lock`, which you must NOT touch), report it precisely with the exact
   failing check output — do not improvise around it. **Gate: green, or one
   precisely-named out-of-scope blocker.**

## Scope

- **Repo:** `/Users/cgint/dev-external/dspy.ex`
- **Allowed (write):** `examples/raw_output_on_parse_failure.exs`,
  `lib/dspy/typed_outputs.ex`, `lib/dspy/parameter.ex`, `lib/dspy/adapters.ex`,
  the schema-generation site you identify for task 2 (name it in the report),
  `test/**`, and the report file.
- **Forbidden:** commits/pushes; `mix.exs`, `mix.lock`, `.env`;
  `lib/dspy/signature/adapter/pipeline.ex` (accepted, do not touch);
  reverting or "cleaning up" the pre-existing uncommitted edits
  (`.gitignore`, `lib/dspy/lm/bumblebee.ex`, `lib/dspy/lm/history.ex`,
  the non-doc edits in `predict.ex`/`chain_of_thought.ex`, `trivy.yaml`);
  anything in `~/dev/agent-coding-gui`.
- Full test suite must stay at 326/326 (the jsv fix closes the one red test;
  do not break others).

## No silent stops — as before. Completion protocol — CMUX-only, as before:

Full report → `/Users/cgint/dev-external/dspy.ex/agent/cmux-report-green-and-demo-20260811.md`,
then exactly one line:
`cmux send --surface surface:9 'CMUX WORK REPORT — <headline: demo output shown? precommit green? suite count?>. Full report: /Users/cgint/dev-external/dspy.ex/agent/cmux-report-green-and-demo-20260811.md\n'`
