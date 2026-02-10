---
name: pi-handoff
description: Delegate repo investigation/mechanical tasks to a sub-agent via scripts/pi_handoff.sh and get a compressed handback (keeps the driver agent’s context small).
---

# pi-handoff

Use this when you want to keep the **driver** agent focused on North Star + decisions, while delegating heavy lifting (searches, inventories, multi-file scanning, repetitive edits) to a sub-agent.

## What you get

- A **gitignored** handoff directory under `plan/research/pi_handoffs/…`
- A compact summary in `handback.md` (safe to paste into the driver context)
- A local `sessions/` directory (for deeper inspection in pi if needed)

## Usage (recommended)

Run an ad-hoc handoff via the repo script:

```bash
scripts/pi_handoff.sh --models gpt-5.2 --goal "Inventory signature parsing + where atoms are created" \
  --context lib/dspy/signature.ex \
  --context test/signature_test.exs
```

This prints a single path like:

```text
plan/research/pi_handoffs/20260210_235959_inventory-signature-parsing/handback.md
```

Open that file and use it as the “handoff result”.

## Tooling defaults (safety)

- By default, `scripts/pi_handoff.sh` uses `--tools read,bash` (investigation-only).
- If you explicitly want the sub-agent to write notes/artifacts, override tools:

```bash
scripts/pi_handoff.sh --models gpt-5.2 --tools read,bash,write --goal "Draft a patch plan" --context plan/STATUS.md
```

## Output contract

The handback must be short and follow this shape:

- Goal
- Findings
- Proposed changes
- Risks/unknowns
- Verification

If it can’t fit, split the task.
