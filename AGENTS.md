# AGENTS.md — How this repo is organized (for continuity)

This repository is being developed as an **Elixir-native port** of the upstream **Python DSPy** library (`../dspy`), designed to be reliable and welcoming for open-source adoption in the BEAM/Elixir ecosystem.

## Start here (reading order)
1. `plan/NORTH_STAR.md` — the purpose, constraints, and priorities (why/what matters).
2. `plan/RELEASE_MILESTONES.md` — the step-by-step milestone roadmap (what we ship first).
3. `plan/INTERFACE_COMPATIBILITY.md` — explicit mapping to Python DSPy and DSPex-snakepit.
4. `plan/REFERENCE_DSPY_INTRO.md` — reference Python example suite → acceptance test candidates.
5. `plan/STATUS.md` — the current heartbeat (health, decisions, next tasks, verification).
6. `plan/QUALITY_BAR.md` — quality bar + testing principles (tests as specification).
7. `plan/PORTING_CHARTER.md` — scope + operating agreement for how we work.
8. `agent/MEMORY.md` — compact context window (decisions + “how to resume quickly”).
9. `agent/SOUL.md` — the assistant’s stable operating principles and learned habits.

## Directory intent
- `docs/`
  - “Classic docs”: technical references, user-facing docs, integration notes.
  - Should be reasonably stable and suitable for external readers.

- `plan/`
  - “Agile planning artifacts”: north star, roadmap, milestones, status, decisions, diagrams.
  - Meant to make it easy to resume work after a break without re-deriving context.

- `agent/`
  - Assistant self-organization: compact memory/context and long-lived operating principles.
  - The goal is to reduce context loss between sessions.

## Working mode (Clarity First)
- Planning phase: investigate + propose + update planning artifacts.
- Execution phase: implement only after explicit user approval ("Approved" / "Go").

(See `plan/WORKFLOW.md` for details.)
