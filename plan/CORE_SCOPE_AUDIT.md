# CORE_SCOPE_AUDIT.md — Keep core `:dspy` adoptable

## Summary

For open-source adoption, **clarity is a feature**.

Today, `lib/dspy/` contains a large number of modules that are **not part of the proven DSPy port surface** (and are not referenced by `docs/OVERVIEW.md` evidence anchors). Even if these modules compile, they create onboarding noise and make it harder for users/contributors to know what is stable.

This doc proposes a step-by-step way to:
- keep the **core** library (`:dspy`) focused on the North Star workflows
- quarantine/relocate unproven/experimental modules
- preserve git history (move, don’t delete)

## Diagram

![Core scope triage flow](./diagrams/core_scope_triage.svg)

## Evidence (why this matters)

North Star (`plan/NORTH_STAR.md`) prioritizes:
- adoption + reliability
- interface familiarity (DSPy users feel at home)
- stable slices backed by deterministic tests
- keeping core small; moving optional concerns out of core

A cluttered `lib/dspy/` works against these goals.

## Proposed classification

### A) Core / proven (stays in `lib/dspy/`)

Modules and directories that are part of the proven workflows (backed by acceptance tests and/or explicitly referenced in `docs/OVERVIEW.md`):
- Signatures + parsing: `signature.ex`, `signature/`
- Programs: `predict.ex`, `chain_of_thought.ex`, `refine.ex`
- Evaluation: `evaluate.ex`, `metrics.ex`, `trainset.ex`
- Provider wiring: `lm.ex`, `lm/req_llm.ex` (and optional `lm/bumblebee.ex`)
- Parameter persistence: `parameter.ex`, `module.ex`
- Tools: `tools.ex`, `tools/`
- Retrieval: `retrieve.ex`, `retrieve/`
- Teleprompters: `teleprompt.ex`, `teleprompt/` (only those proven should be presented as stable)
- Small utilities used by the above: `attachments.ex`, `example.ex`, `prediction.ex`, `adapters.ex`, `settings.ex`, `application.ex`

### B) Experimental / unproven (quarantine)

Any module that is not:
- referenced by the proven workflows/tests,
- referenced by docs as stable,
- or required transitively by the above.

These should be moved out of the core compilation path.

## Step-by-step plan (low-risk migration)

1. **Inventory**
   - Generate a list of `.ex` files under `lib/dspy/`.
   - Cross-check against:
     - evidence list in `plan/STATUS.md`
     - stable claims in `docs/OVERVIEW.md`
     - usage in tests (`test/`)

2. **Classify** each file as either:
   - **core/proven** (keep), or
   - **experimental** (quarantine)

3. **Quarantine via `git mv` (no deletion)**
   - Move experimental files to a non-compiled location, e.g.:
     - `extras/dspy_extras/unsafe/quarantine/<original_path>.ex`
   - Rationale: keep history, reduce noise, and avoid accidental inclusion in the core library.

4. **Verification gate (after each batch)**
   - `mix format`
   - `mix compile --warnings-as-errors`
   - `mix test`
   - `scripts/verify_all.sh`

5. **Docs + roadmap update**
   - Update `docs/OVERVIEW.md` / `plan/STATUS.md` to clarify what is in core.
   - Optionally add a short note in `extras/dspy_extras/unsafe/README.md` describing the quarantine purpose.

## Risks / mitigations

- **Risk:** core modules may depend on an “experimental” module.
  - *Mitigation:* move files in small batches; run compile/test gates after each.

- **Risk:** users depended on undocumented modules.
  - *Mitigation:* quarantine (don’t delete) so we can restore/migrate intentionally if needed.

## Success criteria

- `lib/dspy/` is mostly the proven DSPy port surface.
- `mix test` remains green.
- `docs/OVERVIEW.md` remains “truth by evidence”.
- Experimental/unproven code is clearly out of core.
