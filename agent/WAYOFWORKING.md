# WAYOFWORKING.md — How we keep context small and ship reliably

## TL;DR

- **SOUL** (`agent/SOUL.md`) = stable principles (how I behave).
- **WAY OF WORKING** (this file) = the operational playbook (how we run the loop, delegate, and manage context).
- **MEMORY** (`agent/MEMORY.md`) = compact “resume quickly” pointers (what exists + where to look).
- **PLAN** (`plan/*`) = roadmap + decisions + status + verification logs.

## Diagram

![Delegation + context loop](./diagrams/way_of_working_delegation.svg)

## Driver vs delegated work

I (the SOUL/MEMORY agent) am the **driver** for this repo:
- keep North Star alignment
- keep scope small and user-valuable
- enforce determinism/quality gates
- keep public docs “truth by evidence”

Delegation (automation/sub-agents) is allowed **only** when it reduces total context + risk.

### What to delegate

Delegate only **narrow, mechanical** tasks, e.g.:
- repo searches / inventories
- drafting a small doc section
- generating a patch list
- repetitive edits with explicit targets

Do **not** delegate:
- architecture decisions
- API design tradeoffs
- anything that can silently change scope

## Context window hygiene

### What goes in chat

- the decision + rationale
- file paths touched
- verification commands + results

### What does *not* go in chat

- long logs
- large search dumps
- multi-page draft text

Persist those as repo artifacts (usually under `plan/`) and link to them.

## Delegation handback format (required)

Any delegated task must hand back a **compressed summary**:

- **Goal:** (1 line)
- **Findings:** (≤5 bullets, each with file path + symbol or line refs)
- **Proposed changes:** (files + what to change)
- **Risks/unknowns:** (what might break / what’s unclear)
- **Verification:** (exact commands)

If the handback can’t fit that format, it’s too big and should be split.

## Where to store delegated outputs

- Prefer `plan/research/` for captured stdout/stderr and longer notes.
- Prefer small, reviewable diffs over giant patches.

`plan/WORKFLOW.md` contains the repo-specific command patterns for delegation (e.g. how we invoke `pi` and where to store logs).

## Ad-hoc handoffs (dynamic `pi` sub-agent)

When an investigation would bloat the driver context (big searches, inventories, multi-file scanning), spawn a sub-agent run and capture a **compressed handback**:

```bash
scripts/pi_handoff.sh --models gpt-5.2 --goal "<task>" --context <path>
```

- Output is stored under `plan/research/pi_handoffs/...` (gitignored).
- The script prints a single path to `handback.md` (safe to paste into the driver context).
- Defaults to `--tools read,bash` (investigation-only). Override `--tools` explicitly if needed.

Interactive convenience: project skill `pi-handoff` lives at `.pi/skills/pi-handoff/SKILL.md`.

## Release prep (delegate the bookkeeping)

When cutting a tag, delegate the mechanical bookkeeping to a sub-agent, then keep a thin driver gate for correctness:

1. Driver: finish the code slice and commit it.
2. Delegate: bump `VERSION`, prepend a row in `docs/RELEASES.md` (tag-pinned links), add a log entry in `plan/STATUS.md`.
3. Driver: review diff, run `scripts/release_lint.sh`, commit the release commit, tag, push.

Example handoff (enable edit/write tools):

```bash
scripts/pi_handoff.sh --models gpt-5.2 --thinking medium --tools read,bash,edit,write \
  --goal "Release prep for vX.Y.Z: update VERSION, docs/RELEASES.md, plan/STATUS.md (no commits/tags)" \
  --context VERSION \
  --context docs/RELEASES.md \
  --context plan/STATUS.md
```

Tip: also pass the changed files (tests + code) as `--context ...` so the sub-agent can add the right tag-pinned evidence links.

## Sharpening cadence (avoid drift)

- Do a sharpening pass **once per 5 tags** (or once per 2 weeks, whichever comes later).
- Timebox: **10–15 minutes**.
- Record the outcome in: `agent/SHARPENING_LOG.md`.

## Reflex: protect context + reduce repetition

Use handoffs/automation when the work gets “wide” or repetitive.

- If you expect repo-wide discovery/inventory, more than ~2 search passes, or many-file touch points: run `scripts/pi_handoff.sh` first.
- If you’re about to paste long outputs: persist them under `plan/research/...` and link instead.
- **Rule of 2:** when a mechanical step repeats (multi-file edits, evidence inventories, release bookkeeping), prefer a small wrapper script or a single source of truth — but avoid optimizing after only one occurrence.

## Review gate (non-negotiable)

Delegated output is **draft input**.

Before merging anything back:
- I re-check the evidence (tests/code pointers)
- I run the verification gate (`mix test`, `./precommit.sh` as appropriate)
- I record any durable learnings/decisions in `plan/STATUS.md` or `agent/MEMORY.md`
