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

## Usage (recommended: simplest)

If you want the simplest working sub-agent call (no model/tool flags), use the minimal profile in print mode:

```bash
pi-profile minimal -p \
  @plan/research/adapter_parity/CONTEXT.md \
  @lib/dspy/signature.ex \
  "Goal: inventory signature parsing + where atoms are created. Return paths + line ranges and a short plan."
```

This prints the sub-agent’s response directly.

## Usage (structured: repo handoff directory)

If you want a **gitignored handoff directory** + `handback.md`, use the repo helper script:

```bash
scripts/pi_handoff.sh --models <model-id> --goal "Inventory signature parsing + where atoms are created" \
  --context lib/dspy/signature.ex \
  --context test/signature_test.exs
```

It prints the path to the generated:

```text
plan/research/pi_handoffs/<timestamp>_<slug>/handback.md
```

Notes:
- The repo helper is stricter (it currently requires `--models` and may trigger provider credential requirements).
- If you want read-only runs, set `PI_TOOLS=read,bash` in the environment; otherwise rely on defaults.

## Output contract

The handback must be short and follow this shape:

- Goal
- Findings
- Proposed changes
- Risks/unknowns
- Verification

If it can’t fit, split the task.
